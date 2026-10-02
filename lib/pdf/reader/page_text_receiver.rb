# coding: utf-8
# typed: true
# frozen_string_literal: true

require 'forwardable'
require 'pdf/reader/page_layout'

module PDF
  class Reader

    # Builds a UTF-8 string of all the text on a single page by processing all
    # the operaters in a content stream.
    #
    class PageTextReceiver
      extend Forwardable

      SPACE = " " #: String

      #: untyped
      attr_reader :state

      #: untyped
      attr_reader :options

      ########## BEGIN FORWARDERS ##########
      # Graphics State Operators
      def_delegators :@state, :save_graphics_state, :restore_graphics_state

      # Matrix Operators
      def_delegators :@state, :concatenate_matrix

      # Text Object Operators
      def_delegators :@state, :begin_text_object, :end_text_object

      # Text State Operators
      def_delegators :@state, :set_character_spacing, :set_horizontal_text_scaling
      def_delegators :@state, :set_text_font_and_size, :font_size
      def_delegators :@state, :set_text_leading, :set_text_rendering_mode
      def_delegators :@state, :set_text_rise, :set_word_spacing

      # Text Positioning Operators
      def_delegators :@state, :move_text_position, :move_text_position_and_set_leading
      def_delegators :@state, :set_text_matrix_and_text_line_matrix, :move_to_start_of_next_line
      ##########  END FORWARDERS  ##########

      # starting a new page
      def page=(page)
        @state = PageState.new(page)
        @page = page
        @content = []
        @characters = []
        @pre_adjust_position = nil
        @actual_text = nil
        @actual_text_consumed = false
      end

      def runs(opts = {})
        runs = @characters

        if rect = opts.fetch(:rect, @page.rectangles[:CropBox])
          runs = BoundingRectangleRunsFilter.runs_within_rect(runs, rect)
        end

        if opts.fetch(:skip_zero_width, true)
          runs = ZeroWidthRunsFilter.exclude_zero_width_runs(runs)
        end

        if opts.fetch(:skip_overlapping, true)
          runs = OverlappingRunsFilter.exclude_redundant_runs(runs)
        end

        runs = NoTextFilter.exclude_empty_strings(runs)

        if opts.fetch(:merge, true)
          runs = merge_runs(runs)
        end

        if (only_filter = opts.fetch(:only, nil))
          runs = AdvancedTextRunFilter.only(runs, only_filter)
        end

        if (exclude_filter = opts.fetch(:exclude, nil))
          runs = AdvancedTextRunFilter.exclude(runs, exclude_filter)
        end

        runs
      end

      # deprecated
      #: () -> String
      def content
        mediabox = @page.rectangles[:MediaBox]
        PageLayout.new(runs, mediabox).to_s
      end

      #####################################################
      # Text Showing Operators
      #####################################################
      # record text that is drawn on the page
      def show_text(string) # Tj (AWAY)
        @pre_adjust_position = nil
        internal_show_text(string)
      end

      def show_text_with_positioning(params) # TJ [(A) 120 (WA) 20 (Y)]
        params.each do |arg|
          if arg.is_a?(String)
            internal_show_text(arg)
          elsif arg.is_a?(Numeric)
            vertical = @state.current_font&.vertical? || false
            if vertical
              # attribute the adjustment to the preceding glyph; if there is
              # no preceding glyph yet it's absorbed into the first one
              @pre_adjust_position ||= @state.trm_transform_point(Point::ZERO_ZERO)
            end
            @state.process_glyph_displacement(0, arg, false, vertical)
          else
            # skip it
          end
        end
      end

      def move_to_next_line_and_show_text(str) # '
        @pre_adjust_position = nil
        @state.move_to_start_of_next_line
        show_text(str)
      end

      def set_spacing_next_line_show_text(aw, ac, string) # "
        @state.set_word_spacing(aw)
        @state.set_character_spacing(ac)
        @pre_adjust_position = nil
        move_to_next_line_and_show_text(string)
      end

      #####################################################
      # Marked Content
      #####################################################
      def begin_marked_content_with_pl(tag, properties)
        if properties.is_a?(Hash) && properties[:ActualText]
          @actual_text = properties[:ActualText]
          @actual_text_consumed = false
        end
      end

      def end_marked_content
        @actual_text = nil
        @actual_text_consumed = false
      end

      #####################################################
      # XObjects
      #####################################################
      def invoke_xobject(label)
        @state.invoke_xobject(label) do |xobj|
          case xobj
          when PDF::Reader::FormXObject then
            xobj.walk(self)
          end
        end
      end

      private

      #: (String) -> void
      def internal_show_text(string)
        PDF::Reader::Error.validate_type_as_malformed(string, "string", String)
        if @state.current_font.nil?
          raise PDF::Reader::MalformedPDFError, "current font is invalid"
        end
        glyphs = @state.current_font.unpack(string)
        glyphs.each_with_index do |glyph_code, index|
          utf8_chars = @state.current_font.to_utf8(glyph_code)

          # Use ActualText from marked content if available (PDF 32000-1 §14.9.4).
          # ActualText replaces all text within a BDC/EMC span.
          if @actual_text
            if !@actual_text_consumed
              text = @actual_text
              utf8_chars = PDF::Reader::EncodingUtils.string_to_utf8(text)
              @actual_text_consumed = true
            else
              utf8_chars = ""
            end
          end

          if @state.current_font.vertical?
            show_vertical_glyph(glyph_code, utf8_chars)
          else
            show_horizontal_glyph(glyph_code, utf8_chars)
          end
        end
      end

      #: () -> void
      def show_horizontal_glyph(glyph_code, utf8_chars)
        bl = @state.trm_transform_point(Point::ZERO_ZERO)
        text_origin = apply_rotation(bl)

        glyph_width = @state.current_font.glyph_width_in_text_space(glyph_code)
        scaled_glyph_width = glyph_width * @state.font_size
        unless utf8_chars == SPACE
          @characters << TextRun.new(
            text_origin.x, text_origin.y, scaled_glyph_width, @state.font_size, utf8_chars
          )
        end
        @state.process_glyph_displacement(glyph_width, 0, utf8_chars == SPACE)
      end

      # For vertical writing the glyph's origin is shifted from the current
      # text position by the position vector (w10, 0), and the advance to the
      # next glyph follows the displacement vector (0, w11). See
      # Section 9.4.4/9.7.4.3, PDF 32000-1:2008.
      #
      #: (Integer, String) -> void
      def show_vertical_glyph(glyph_code, utf8_chars)
        if utf8_chars == SPACE
          # spaces are skipped, but still consume the vertical advance
          _, displacement_y, _ = @state.current_font.glyph_vertical_metrics_in_text_space(glyph_code)
          @pre_adjust_position = nil
          @state.process_glyph_displacement(displacement_y, 0, false, true)
          return
        end

        position_x, displacement_y, displacement_x =
          @state.current_font.glyph_vertical_metrics_in_text_space(glyph_code)

        glyph_point = Point.new(position_x, 0)
        bl = @state.trm_transform_point(glyph_point)
        text_origin = apply_rotation(bl)
        text_position_before = @state.trm_transform_point(Point::ZERO_ZERO)

        if @pre_adjust_position && @characters.last
          # A TJ number applied after the preceding glyph moved the text
          # position before this glyph started. Attribute that movement to
          # the preceding glyph's measured advance.
          @characters.last.extend_vertical_advance(
            @pre_adjust_position.y - text_position_before.y
          )
        end

        @pre_adjust_position = nil

        # displacement_x is normally 0 in vertical text
        if displacement_x != 0
          @state.process_horizontal_displacement_only(displacement_x)
        end
        @state.process_glyph_displacement(displacement_y, 0, false, true)

        text_position_after = @state.trm_transform_point(Point::ZERO_ZERO)
        # the glyph's own vertical advance (any TJ number before this glyph
        # is accounted for in the preceding glyph instead)
        advance = (text_position_before.y - text_position_after.y).abs

        # the glyph's horizontal ink width comes from the regular W/DW metrics
        scaled_ink_width = @state.current_font.glyph_width_in_text_space(glyph_code) * @state.font_size

        run = TextRun.new(
          text_origin.x, text_origin.y, scaled_ink_width, @state.font_size, utf8_chars,
          wmode: 1, advance: advance
        )
        rotated_after = apply_rotation(text_position_after)
        run.page_rotate = @page.rotate.to_i
        run.next_nominal_y = rotated_after.y
        run.next_nominal_x = rotated_after.x
        @characters << run
      end

      #: (Point) -> Point
      def apply_rotation(pt)
        if @page.rotate == 90
          Point.new(pt.y, pt.x * -1)
        elsif @page.rotate == 180
          Point.new(pt.x * -1, pt.y * -1)
        elsif @page.rotate == 270
          Point.new(pt.y * -1, pt.x)
        else
          pt
        end
      end

      # take a collection of TextRun objects and merge any that are in close
      # proximity
      #
      #: (Array[PDF::Reader::TextRun]) -> Array[PDF::Reader::TextRun]
      def merge_runs(runs)
        horizontal, vertical = runs.partition { |run| !run.vertical? }

        merged_horizontal = horizontal.group_by { |char|
          char.y.to_i
        }.map { |_y, chars|
          group_chars_into_runs(chars.sort)
        }.flatten

        merged_vertical = sort_vertical(vertical).slice_when { |a, b|
          !a.mergable?(b)
        }.map { |column| group_chars_into_runs(column) }.flatten

        (merged_horizontal + merged_vertical).sort
      end

      # vertical runs are read top to bottom (highest y first, or lowest x
      # first when the page is rotated 90/270)
      #
      #: (Array[PDF::Reader::TextRun]) -> Array[PDF::Reader::TextRun]
      def sort_vertical(chars)
        if @page.rotate == 90
          chars.sort { |a, b| b.x <=> a.x }
        elsif @page.rotate == 180
          chars.sort { |a, b| a.y <=> b.y }
        elsif @page.rotate == 270
          chars.sort { |a, b| a.x <=> b.x }
        else
          chars.sort { |a, b| b.y <=> a.y }
        end
      end


      def group_chars_into_runs(chars)
        chars.each_with_object([]) do |char, runs|
          if runs.empty?
            runs << char
          elsif runs.last.mergable?(char)
            runs[-1] = runs.last + char
          else
            runs << char
          end
        end
      end

    end
  end
end

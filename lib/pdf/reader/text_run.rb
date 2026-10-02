# coding: utf-8
# typed: strict
# frozen_string_literal: true

class PDF::Reader
  # A value object that represents one or more consecutive characters on a page.
  class TextRun
    include Comparable

    #: Numeric
    attr_reader :width

    # 0 for horizontal writing, 1 for vertical writing (CIDFont WMode).
    #
    #: Integer
    attr_reader :wmode

    # The advance along the writing direction after the last glyph. For
    # horizontal runs this is always equal to #width; for vertical runs it's
    # the vertical distance (always stored as a positive number) between the
    # origin of the last glyph and where a following glyph would begin.
    #
    #: Numeric
    attr_reader :advance

    # For vertical runs: the y where the next glyph begins after this run's
    # nominal displacement (excluding standalone TJ adjustments), used to
    # decide if two runs are contiguous. nil for horizontal runs.
    #
    #: Numeric?
    attr_accessor :next_nominal_y

    # For vertical runs on a page rotated 90/270: the x where the next glyph
    # begins after this run's nominal displacement. nil otherwise.
    #
    #: Numeric?
    attr_accessor :next_nominal_x

    # Page rotation in degrees, used to orient vertical merge calculations.
    #
    #: Integer
    attr_accessor :page_rotate

    #: Numeric
    attr_reader :font_size

    #: String
    attr_reader :text

    alias :to_s :text

    #: (Numeric, Numeric, Numeric, Numeric, String, ?wmode: Integer, ?advance: Numeric) -> void
    def initialize(x, y, width, font_size, text, wmode: 0, advance: width)
      @x = x #: Numeric
      @y = y #: Numeric
      @width = width
      @font_size = font_size
      @text = text
      @wmode = wmode
      @advance = advance
      @origin = nil #: PDF::Reader::Point | nil
      @endx = nil #: Numeric | nil
      @endy = nil #: Numeric | nil
      @mergable_range = nil #: Range[Numeric] | nil
    end

    # Lazily constructed to avoid allocating a Point on every TextRun
    #: () -> PDF::Reader::Point
    def origin
      @origin ||= PDF::Reader::Point.new(@x, @y)
    end

    # Allows collections of TextRun objects to be sorted. They will be sorted
    # in order of their position on a cartesian plain - Top Left to Bottom Right
    #: (PDF::Reader::Point) -> Numeric
    def <=>(other)
      if x == other.x && y == other.y
        0
      elsif y < other.y
        1
      elsif y > other.y
        -1
      elsif x < other.x
        -1
      elsif x > other.x
        1
      else
        0 # Unreachable?
      end
    end

    #: () -> Numeric
    def x
      @x
    end

    #: () -> Numeric
    def y
      @y
    end

    #: () -> Numeric
    def endx
      @endx ||= @x + width
    end

    #: () -> Numeric
    def endy
      @endy ||= @y + font_size
    end

    #: () -> Numeric
    def mean_character_width
      @width / character_count
    end

    #: (PDF::Reader::TextRun) -> bool
    def mergable?(other)
      if vertical?
        other.wmode == wmode && font_size == other.font_size &&
          vertical_aligned?(other) &&
          vertical_mergable_range.include?(vertical_other_position(other))
      else
        y.to_i == other.y.to_i && font_size == other.font_size &&
          other.wmode == wmode && mergable_range.include?(other.x)
      end
    end

    #: (PDF::Reader::TextRun) -> PDF::Reader::TextRun
    def +(other)
      raise ArgumentError, "#{other} cannot be merged with this run" unless mergable?(other)

      if vertical?
        merge_vertical(other)
      elsif (other.x - endx) <( font_size * 0.2)
        TextRun.new(x, y, other.endx - x, font_size, text + other.text)
      else
        TextRun.new(x, y, other.endx - x, font_size, "#{text} #{other.text}")
      end
    end

    # Two vertical runs are concatenated in reading order (top to bottom).
    # The receiver may be either the upper or lower run.
    #
    #: (PDF::Reader::TextRun) -> PDF::Reader::TextRun
    def merge_vertical(other)
      upper, lower = vertical_upper_lower(other)
      gap = vertical_gap(upper, lower)
      separator = gap <= font_size * 0.2 ? "" : "\n"
      merged = TextRun.new(
        upper.x, upper.y, upper.width, font_size,
        "#{upper.text}#{separator}#{lower.text}",
        wmode: 1,
        advance: lower.advance
      )
      merged.page_rotate = page_rotate
      merged.next_nominal_y = lower.next_nominal_y
      merged.next_nominal_x = lower.next_nominal_x
      merged
    end

    #: () -> String
    def inspect
      "#{text} w:#{width} f:#{font_size} @#{x},#{y}"
    end

    #: (PDF::Reader::TextRun) -> bool
    def intersect?(other_run)
      x <= other_run.endx && endx >= other_run.x &&
        endy >= other_run.y && y <= other_run.endy
    end

    #: () -> bool
    def vertical?
      @wmode == 1
    end

    # Add a signed delta (in unrotated user space) to this vertical run's
    # advance. A positive +delta+ lengthens the advance (moves the following
    # glyph further down).
    #
    #: (Numeric) -> void
    def extend_vertical_advance(delta)
      @advance = (@advance - delta).abs
      @mergable_range = nil
    end

    # return what percentage of this text run is overlapped by another run
    #: (PDF::Reader::TextRun) -> Numeric
    def intersection_area_percent(other_run)
      return 0 unless intersect?(other_run)

      dx = [endx, other_run.endx].min - [x, other_run.x].max
      dy = [endy, other_run.endy].min - [y, other_run.y].max
      intersection_area = dx*dy

      intersection_area.to_f / area
    end

    private

    #: () -> Numeric
    def area
      (endx - x) * (endy - y)
    end

    #: () -> Range[Numeric]
    def mergable_range
      @mergable_range ||= Range.new(endx - 3, endx + font_size)
    end

    #: () -> Range[Numeric]
    def vertical_mergable_range
      if page_rotate == 90
        target = next_nominal_x || (x - advance)
        Range.new(target - 3, target + 3)
      elsif page_rotate == 270
        target = next_nominal_x || (x + advance)
        Range.new(target - 3, target + 3)
      elsif page_rotate == 180
        target = next_nominal_y || (y + advance)
        Range.new(target - 3, target + 3)
      else
        target = next_nominal_y || (y - advance)
        Range.new(target - 3, target + 3)
      end
    end

    #: (PDF::Reader::TextRun) -> bool
    def vertical_aligned?(other)
      if page_rotate == 90 || page_rotate == 270
        (y - other.y).abs <= 3
      else
        (x - other.x).abs <= 3
      end
    end

    #: (PDF::Reader::TextRun) -> Numeric
    def vertical_other_position(other)
      page_rotate == 90 || page_rotate == 270 ? other.x : other.y
    end

    # Returns [upper (read first), lower (read second)]
    #
    #: (PDF::Reader::TextRun) -> [PDF::Reader::TextRun, PDF::Reader::TextRun]
    def vertical_upper_lower(other)
      case page_rotate
      when 90  then x >= other.x ? [self, other] : [other, self]
      when 270 then x <= other.x ? [self, other] : [other, self]
      when 180 then y <= other.y ? [self, other] : [other, self]
      else          y >= other.y ? [self, other] : [other, self]
      end
    end

    #: (PDF::Reader::TextRun, PDF::Reader::TextRun) -> Numeric
    def vertical_gap(upper, lower)
      case page_rotate
      when 90  then upper.x - lower.x
      when 270 then lower.x - upper.x
      when 180 then lower.y - upper.y
      else          upper.y - lower.y
      end
    end

    # Assume string encoding is marked correctly and we can trust String#size to return a
    # character count
    #: () -> Float
    def character_count
      @text.size.to_f
    end
  end
end

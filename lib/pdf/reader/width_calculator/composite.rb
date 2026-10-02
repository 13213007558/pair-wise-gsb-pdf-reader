# coding: utf-8
# typed: strict
# frozen_string_literal: true

class PDF::Reader
  module WidthCalculator
    # CIDFontType0 or CIDFontType2 use DW (integer) and W (array) to determine
    # codepoint widths, note that CIDFontType2 will contain a true type font
    # program which could be used to calculate width, however, a conforming writer
    # is supposed to convert the widths for the codepoints used into the W array
    # so that it can be used.
    # see Section 9.7.4.1, PDF 32000-1:2008, pp 269-270
    class Composite

      #: (PDF::Reader::Font) -> void
      def initialize(font)
        @font = font
        @widths = PDF::Reader::CidWidths.new(
          @font.cid_default_width, @font.cid_widths
        ) #: PDF::Reader::CidWidths
        @vmetrics = PDF::Reader::CidVMetrics.new(
          @font.cid_default_vmetrics, @font.cid_vmetrics
        ) #: PDF::Reader::CidVMetrics
      end

      #: (Integer?) -> Numeric
      def glyph_width(code_point)
        return 0 if code_point.nil? || code_point < 0

        w = @widths[code_point]
        # 0 is a valid width
        if w
          w.to_f
        else
          0
        end
      end

      # Returns the vertical metrics for a glyph as a [w1y, v1x, v1y]
      # triple in glyph space:
      #
      #   w1y - the vertical component of the displacement vector w1
      #   v1x - the horizontal component of the position vector v, which
      #         defaults to half the glyph width
      #   v1y - the vertical component of the position vector v
      #
      # Only meaningful when the font is used with a vertical (WMode 1) CMap.
      #
      #: (Integer?) -> Array[Numeric]
      def glyph_vertical_metrics(code_point)
        return [0, 0, 0] if code_point.nil? || code_point < 0

        w1y, v1x, v1y = @vmetrics[code_point]
        [w1y.to_f, v1x || glyph_width(code_point) / 2.0, v1y.to_f]
      end

      # the vertical component of the vertical displacement vector (w1y)
      # in glyph space
      #
      #: (Integer?) -> Numeric
      def glyph_vertical_displacement(code_point)
        glyph_vertical_metrics(code_point)[0]
      end
    end
  end
end

# coding: utf-8
# typed: strict
# frozen_string_literal: true

module PDF
  class Reader
    # One drawing of an image XObject on a page. Pixel decoding remains available
    # through #image, while this object describes placement in page user space.
    class ImagePlacement
      #: PDF::Reader::ImageXObject
      attr_reader :image

      #: Symbol
      attr_reader :label

      #: Array[Numeric]
      attr_reader :matrix

      #: (PDF::Reader::ImageXObject, Symbol, Array[Numeric]) -> void
      def initialize(image:, label:, matrix:)
        @image = image
        @label = label
        @matrix = matrix
      end

      #: () -> PDF::Reader::Point
      def bottom_left
        transform(0, 0)
      end

      #: () -> PDF::Reader::Point
      def bottom_right
        transform(1, 0)
      end

      #: () -> PDF::Reader::Point
      def top_left
        transform(0, 1)
      end

      #: () -> PDF::Reader::Point
      def top_right
        transform(1, 1)
      end

      #: () -> Hash[Symbol, untyped]
      def to_h
        {
          :image => image,
          :label => label,
          :matrix => matrix,
          :bottom_left => bottom_left,
          :bottom_right => bottom_right,
          :top_left => top_left,
          :top_right => top_right,
        }
      end

      private

      #: (Numeric, Numeric) -> PDF::Reader::Point
      def transform(x, y)
        a, b, c, d, e, f = matrix
        Point.new((a * x) + (c * y) + e, (b * x) + (d * y) + f)
      end
    end
  end
end

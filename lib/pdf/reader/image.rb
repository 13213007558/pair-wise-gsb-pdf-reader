# coding: utf-8
# typed: strict
# frozen_string_literal: true

module PDF
  class Reader
    # Pixel data decoded from an image XObject. Positional data from the
    # content stream is intentionally not included here.
    class Image
      #: Integer
      attr_reader :width

      #: Integer
      attr_reader :height

      #: Integer
      attr_reader :bits_per_component

      #: Symbol
      attr_reader :color_space

      #: Integer
      attr_reader :components

      #: Integer?
      attr_reader :base_components

      #: Array[Numeric]
      attr_reader :decode

      #: Array[Integer]?
      attr_reader :palette

      #: String
      attr_reader :rgba

      #: (Integer, Integer, Integer, Symbol, Integer, Array[Numeric], String,
      #   Array[Integer]?) -> void
      def initialize(width:, height:, bits_per_component:, color_space:, components:,
                     decode:, rgba:, palette: nil, base_components: nil)
        @width = width
        @height = height
        @bits_per_component = bits_per_component
        @color_space = color_space
        @components = components
        @decode = decode
        @palette = palette
        @rgba = rgba
        @base_components = base_components
      end

      # Return one [red, green, blue, alpha] pixel. Co-ordinates are zero based,
      # with row zero at the top of the image.
      #: (Integer, Integer) -> Array[Integer]
      def pixel(x, y)
        index = ((y * width) + x) * 4
        rgba.byteslice(index, 4).bytes
      end

      #: () -> Hash[Symbol, untyped]
      def to_h
        {
          :width => width,
          :height => height,
          :bits_per_component => bits_per_component,
          :color_space => color_space,
          :components => components,
          :decode => decode,
          :palette => palette,
          :rgba => rgba,
          :base_components => base_components,
        }
      end
    end
  end
end

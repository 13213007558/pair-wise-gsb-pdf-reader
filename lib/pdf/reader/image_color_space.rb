# coding: utf-8
# typed: strict
# frozen_string_literal: true

module PDF
  class Reader
    # Resolves the limited set of raster image color spaces accepted by
    # ImageXObject.
    class ImageColorSpace
      #: (untyped, Hash[Symbol, untyped], PDF::Reader::ObjectHash?) -> void
      def initialize(value, resources, objects)
        @value = value
        @resources = resources
        @objects = objects
      end

      #: () -> [Symbol, Integer, Integer, Array[Integer]?]
      def to_a
        value = deref(@value)
        if value.is_a?(Symbol) && @resources.key?(value)
          value = deref(@resources[value])
        end

        case value
        when :DeviceGray then [:DeviceGray, 1, 1, nil]
        when :DeviceRGB then [:DeviceRGB, 3, 3, nil]
        when :DeviceCMYK then [:DeviceCMYK, 4, 4, nil]
        when Array then indexed(value)
        else
          raise UnsupportedFeatureError, "unsupported image color space: #{value.inspect}"
        end
      end

      private

      #: (Array[untyped]) -> [Symbol, Integer, Integer, Array[Integer]]
      def indexed(array)
        unless array[0] == :Indexed || array[0] == :I
          raise UnsupportedFeatureError, "unsupported image color space: #{array[0].inspect}"
        end

        base, components, _ = base_color_space(deref(array[1]))
        hival = array[2]
        lookup = lookup_data(deref(array[3]))
        unless hival.is_a?(Integer) && hival >= 0
          raise MalformedPDFError, "Indexed color space hival must be a non-negative integer"
        end
        unless lookup.is_a?(String)
          raise MalformedPDFError, "Indexed color space lookup must be a string or stream"
        end

        expected = (hival + 1) * components
        unless lookup.bytesize == expected
          raise MalformedPDFError, "Indexed lookup table length must be #{expected} bytes"
        end
        [base, 1, components, lookup.bytes]
      end

      #: (untyped) -> [Symbol, Integer, NilClass]
      def base_color_space(value)
        if value.is_a?(Symbol) && @resources.key?(value)
          value = deref(@resources[value])
        end
        case value
        when :DeviceGray then [:DeviceGray, 1, nil]
        when :DeviceRGB then [:DeviceRGB, 3, nil]
        when :DeviceCMYK then [:DeviceCMYK, 4, nil]
        when Array
          if value[0] == :ICCBased
            raise UnsupportedFeatureError, "ICCBased image color spaces are not supported"
          end
          raise UnsupportedFeatureError, "nested Indexed color spaces are not supported" if
            value[0] == :Indexed || value[0] == :I
          raise UnsupportedFeatureError, "unsupported image color space: #{value[0].inspect}"
        else
          raise UnsupportedFeatureError, "unsupported image color space: #{value.inspect}"
        end
      end

      #: (untyped) -> untyped
      def lookup_data(value)
        value.is_a?(PDF::Reader::Stream) ? value.unfiltered_data : value
      end

      #: (untyped) -> untyped
      def deref(value)
        @objects ? @objects.deref!(value) : value
      end
    end
  end
end

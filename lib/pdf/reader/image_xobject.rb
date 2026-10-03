# coding: utf-8
# typed: strict
# frozen_string_literal: true

module PDF
  class Reader
    # Decode a raster image XObject into device-independent RGBA samples.
    class ImageXObject
      SUPPORTED_FILTERS = [:FlateDecode, :Fl, :LZWDecode, :LZW, :RunLengthDecode, :RL,
                           :ASCII85Decode, :A85, :ASCIIHexDecode, :AHx] #: Array[Symbol]

      #: PDF::Reader::Stream
      attr_reader :stream

      #: (PDF::Reader::Stream, ?Hash[Symbol, untyped], ?PDF::Reader::ObjectHash?) -> void
      def initialize(stream, color_spaces: {}, objects: nil)
        @stream = stream
        @color_spaces = color_spaces
        @objects = objects
      end

      #: () -> PDF::Reader::Image
      def decode
        validate!
        width = integer!(:Width)
        height = integer!(:Height)
        bpc = integer!(:BitsPerComponent)
        color_space, source_components, base_components, palette = color_space_info.to_a
        indexed_hival = palette ? ((palette.size / base_components) - 1) : 0
        decode = decode_array(source_components, !palette.nil?, indexed_hival)
        raw = unpack(width, height, bpc, source_components, stream.unfiltered_data)
        decoded_samples = apply_decode(raw, decode, bpc)
        alpha = ImageMask.new(
          stream, width, height, raw, bpc, source_components, base_components, palette, @objects
        ).alpha
        image_colors = palette ? indexed_colors(
          decoded_samples, palette, base_components
        ) : decoded_samples
        rgb = to_rgb(image_colors, color_space, width * height, base_components, bpc)
        build_image(width, height, bpc, color_space, source_components, base_components,
                    palette, decode, combine(rgb, alpha))
      end
      alias to_image decode

      private

      #: () -> void
      def validate!
        raise UnsupportedFeatureError, "stencil image masks require a painting color" if stencil?
        raise MalformedPDFError, "expected an image XObject" unless stream.hash[:Subtype] == :Image
        if [1, 2].include?(stream.hash[:SMaskInData])
          raise UnsupportedFeatureError, "in-image soft masks are not supported"
        end
        raise UnsupportedFeatureError, "soft mask Matte data is not supported" if
          stream.hash[:SMask] && stream.hash.key?(:Matte)
        width = integer!(:Width)
        height = integer!(:Height)
        bpc = integer!(:BitsPerComponent)
        raise MalformedPDFError, "image width must be positive" unless width.positive?
        raise MalformedPDFError, "image height must be positive" unless height.positive?
        unless [1, 2, 4, 8, 16].include?(bpc)
          raise UnsupportedFeatureError, "unsupported BitsPerComponent: #{bpc}"
        end
        palette = color_space_info.to_a[3]
        raise UnsupportedFeatureError, "Indexed images require 1, 2, 4 or 8 bit samples" if
          palette && bpc == 16
        Array(stream.hash[:Filter]).each do |filter|
          unless SUPPORTED_FILTERS.include?(filter)
            raise UnsupportedFeatureError, "unsupported image filter: #{filter.inspect}"
          end
        end
      end

      #: (Integer, Integer, Integer, Symbol, Integer, Integer, Array[Integer]?,
      #   Array[Numeric], String) -> PDF::Reader::Image
      def build_image(width, height, bpc, color_space, source_components, base_components,
                      palette, decode, rgba)
        image_color_space = palette ? :Indexed : color_space
        components = palette ? 1 : source_components
        Image.new(
          :width => width,
          :height => height,
          :bits_per_component => bpc,
          :color_space => image_color_space,
          :components => components,
          :decode => decode,
          :rgba => rgba,
          :palette => palette,
          :base_components => palette ? base_components : nil,
        )
      end

      #: () -> bool
      def stencil?
        stream.hash[:ImageMask] == true
      end

      #: (Symbol) -> Integer
      def integer!(key)
        value = stream.hash[key]
        unless value.is_a?(Integer)
          raise MalformedPDFError, "image #{key} must be an integer (got #{value.class})"
        end
        value
      end

      #: () -> PDF::Reader::ImageColorSpace
      def color_space_info
        ImageColorSpace.new(stream.hash[:ColorSpace], @color_spaces, @objects)
      end

      #: (untyped) -> untyped
      def deref(value)
        @objects ? @objects.deref!(value) : value
      end

      #: (Integer, bool, Integer) -> Array[Numeric]
      def decode_array(components, indexed, indexed_hival)
        value = deref(stream.hash[:Decode])
        return [0.0, indexed_hival.to_f] if value.nil? && indexed
        return Array.new(components) { [0, 1] }.flatten if value.nil?

        expected_size = indexed ? 2 : components * 2
        unless value.is_a?(Array) && value.size == expected_size &&
               value.all? { |item| item.is_a?(Numeric) }
          raise MalformedPDFError, "image Decode array is malformed"
        end
        value.map(&:to_f)
      end

      #: (Integer, Integer, Integer, Integer, String) -> Array[Integer]
      def unpack(width, height, bpc, components, data)
        data = data.b
        row_bits = width * bpc * components
        row_bytes = (row_bits + 7) / 8
        expected = row_bytes * height
        if data.bytesize != expected
          raise MalformedPDFError,
                "image data length mismatch: expected #{expected} bytes, got #{data.bytesize}"
        end

        values = []
        mask = (1 << bpc) - 1
        height.times do |row|
          offset = row * row_bytes * 8
          (width * components).times do |sample|
            position = offset + (sample * bpc)
            byte_index = position / 8
            if bpc == 16
              values << ((data.getbyte(byte_index) << 8) | data.getbyte(byte_index + 1))
              next
            end
            shift = 8 - bpc - (position % 8)
            values << ((data.getbyte(byte_index) >> shift) & mask)
          end
        end
        values
      end

      #: (Array[Integer], Array[Numeric], Integer) -> Array[Numeric]
      def apply_decode(values, decode, bpc)
        maximum = (2 ** bpc) - 1
        values.each_with_index.map { |value, index|
          low = decode[(index % decode.size.div(2)) * 2]
          high = decode[((index % decode.size).div(2)) * 2 + 1]
          if low.integer? && high.integer?
            Rational(value, maximum) * Rational(high - low) + low
          else
            low + ((value.to_f / maximum) * (high - low))
          end
        }
      end

      #: (Array[Numeric], Symbol, Integer, Integer, Integer) -> Array[Integer]
      def to_rgb(values, color_space, pixel_count, components, bpc)
        colors = convert(values, color_space, components)
        colors.each_slice(3).flat_map { |red, green, blue|
          [scale(red, bpc), scale(green, bpc), scale(blue, bpc)]
        }.tap { |result|
          raise MalformedPDFError, "decoded image has the wrong pixel count" unless
            result.size == pixel_count * 3
        }
      end

      #: (Array[Numeric], Symbol, Integer) -> Array[Numeric]
      def convert(values, color_space, components)
        case color_space
        when :DeviceGray
          values.flat_map { |value| [value, value, value] }
        when :DeviceRGB
          values
        when :DeviceCMYK
          values.each_slice(components).flat_map { |cyan, magenta, yellow, black|
            [
              scale_component(1 - cyan - black),
              scale_component(1 - magenta - black),
              scale_component(1 - yellow - black),
            ]
          }
        else
          raise UnsupportedFeatureError, "unsupported image color space: #{color_space}"
        end
      end

      #: (Array[Numeric], Array[Integer], Integer) -> Array[Numeric]
      def indexed_colors(values, palette, components)
        hival = (palette.size / components) - 1
        values.flat_map { |value|
          index = value.round
          unless index >= 0 && index <= hival
            raise MalformedPDFError, "Indexed sample #{index} is outside the lookup table"
          end
          palette[index * components, components].map { |byte| Rational(byte, 255) }
        }
      end

      #: (Numeric) -> Numeric
      def scale_component(value)
        [[value, 0].max, 1].min
      end

      #: (Numeric, Integer) -> Integer
      def scale(value, _bpc)
        ([[value, 0].max, 1].min * 255).round
      end

      #: (Array[Integer], Array[Integer]) -> String
      def combine(rgb, alpha)
        rgb.each_slice(3).with_index.map { |(red, green, blue), index|
          [red, green, blue, alpha[index]].pack("C4")
        }.join
      end
    end
  end
end

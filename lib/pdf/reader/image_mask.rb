# coding: utf-8
# typed: strict
# frozen_string_literal: true

module PDF
  class Reader
    # Computes per-pixel alpha from PDF color-key, explicit mask and SMask data.
    class ImageMask
      #: (PDF::Reader::Stream, Integer, Integer, Array[Integer], Integer, Integer,
      #   Integer, Array[Integer]?, PDF::Reader::ObjectHash?) -> void
      def initialize(stream, width, height, samples, bpc, components, base_components,
                     palette, objects = nil)
        @stream = stream
        @width = width
        @height = height
        @samples = samples
        @bpc = bpc
        @components = components
        @base_components = base_components
        @palette = palette
        @objects = objects
      end

      #: () -> Array[Integer]
      def alpha
        values = Array.new(@width * @height, 255)
        color_key!(values)
        mask = deref(@stream.hash[:Mask])
        multiply!(values, explicit_alpha(mask)) if mask.is_a?(PDF::Reader::Stream)
        soft_mask = deref(@stream.hash[:SMask])
        multiply!(values, soft_alpha(soft_mask)) if soft_mask.is_a?(PDF::Reader::Stream)
        values
      end

      private

      #: (untyped) -> untyped
      def deref(value)
        @objects ? @objects.deref!(value) : value
      end

      #: (Array[Integer]) -> void
      def color_key!(alpha)
        mask = deref(@stream.hash[:Mask])
        return unless mask.is_a?(Array)
        pairs = mask.each_slice(2).to_a
        maximum = @palette ? 255 : ((2 ** @bpc) - 1)
        validate_color_key(mask, pairs, maximum)

        comparisons.each_slice(@base_components).with_index do |pixel, index|
          pixel_pairs = pairs.size == 1 ? Array.new(@base_components, pairs[0]) : pairs
          alpha[index] = 0 if pixel.zip(pixel_pairs).all? { |value, (low, high)|
            value >= low.to_i && value <= high.to_i
          }
        end
      end

      #: (Array[Numeric], Array[Array[Numeric]], Integer) -> void
      def validate_color_key(mask, pairs, maximum)
        valid = !pairs.empty? && mask.all? { |item| item.is_a?(Numeric) } &&
                (pairs.size == 1 || pairs.size == @base_components)
        raise MalformedPDFError, "color key Mask array is malformed" unless valid
        if pairs.any? { |low, high| low > high || low < 0 || high > maximum }
          raise MalformedPDFError, "color key Mask values are outside the sample range"
        end
      end

      #: () -> Array[Integer]
      def comparisons
        return @samples unless @palette
        @samples.flat_map { |index| @palette[index * @base_components, @base_components] }
      end

      #: () -> Array[Integer]
      def explicit_alpha(mask)
        coverage(mask, true).map { |value| (value * 255).round }
      end

      #: () -> Array[Integer]
      def soft_alpha(mask)
        coverage(mask, false).map { |value| (value * 255).round }
      end

      #: (PDF::Reader::Stream, bool) -> Array[Numeric]
      def coverage(mask, explicit)
        width, height, bpc = dimensions(mask, explicit)
        validate(mask, explicit, bpc)
        raw = samples(mask, width, height, bpc)
        decoded = decoded(mask, raw, bpc)
        resample(decoded, width, height).map { |value|
          explicit ? stencil_value(mask, value) : value
        }
      end

      #: (PDF::Reader::Stream, bool) -> [Integer, Integer, Integer]
      def dimensions(mask, explicit)
        width = integer(mask, :Width)
        height = integer(mask, :Height)
        bpc = mask.hash[:BitsPerComponent] || (explicit ? 1 : nil)
        unless bpc.is_a?(Integer)
          raise MalformedPDFError, "mask BitsPerComponent must be an integer"
        end
        if explicit && (width != @width || height != @height || bpc != 1)
          raise MalformedPDFError, "explicit image mask must be a same-sized 1-bit image"
        elsif !explicit && ![1, 2, 4, 8, 16].include?(bpc)
          raise UnsupportedFeatureError, "unsupported soft mask BitsPerComponent: #{bpc}"
        end
        [width, height, bpc]
      end

      #: (PDF::Reader::Stream, bool, Integer) -> void
      def validate(mask, explicit, _bpc)
        Array(mask.hash[:Filter]).each do |filter|
          unless ImageXObject::SUPPORTED_FILTERS.include?(filter)
            raise UnsupportedFeatureError, "unsupported mask filter: #{filter.inspect}"
          end
        end
        if mask.hash[:Mask] || mask.hash[:SMask]
          raise UnsupportedFeatureError, "nested image masks are not supported"
        end
        raise UnsupportedFeatureError, "soft mask Matte data is not supported" if
          !explicit && mask.hash.key?(:Matte)
        color_space = mask.hash[:ColorSpace] || (explicit ? :DeviceGray : nil)
        unless color_space == :DeviceGray
          raise UnsupportedFeatureError, "image masks must use DeviceGray"
        end
      end

      #: (PDF::Reader::Stream, Integer, Integer, Integer) -> Array[Integer]
      def samples(mask, width, height, bpc)
        row_bytes = ((width * bpc) + 7) / 8
        data = mask.unfiltered_data.b
        unless data.bytesize == row_bytes * height
          raise MalformedPDFError, "mask data length mismatch"
        end
        unpack(data, width, height, bpc, row_bytes)
      end

      #: (String, Integer, Integer, Integer, Integer) -> Array[Integer]
      def unpack(data, width, height, bpc, row_bytes)
        mask_value = (1 << bpc) - 1
        height.times.flat_map { |row|
          width.times.map { |column|
            position = (row * row_bytes * 8) + (column * bpc)
            byte_index = position / 8
            if bpc == 16
              (data.getbyte(byte_index) << 8) | data.getbyte(byte_index + 1)
            else
              shift = 8 - bpc - (position % 8)
              (data.getbyte(byte_index) >> shift) & mask_value
            end
          }
        }
      end

      #: (PDF::Reader::Stream, Array[Integer], Integer) -> Array[Numeric]
      def decoded(mask, raw, bpc)
        decode = mask.hash[:Decode] || [0.0, 1.0]
        unless decode.is_a?(Array) && decode.size == 2 &&
               decode.all? { |item| item.is_a?(Numeric) }
          raise MalformedPDFError, "mask Decode array is malformed"
        end
        maximum = (2 ** bpc) - 1
        raw.map { |value|
          result = decode[0] + ((value.to_f / maximum) * (decode[1] - decode[0]))
          result.clamp(0.0, 1.0)
        }
      end

      #: (PDF::Reader::Stream, Numeric) -> Numeric
      def stencil_value(mask, value)
        decode = mask.hash[:Decode] || [0.0, 1.0]
        painted = decode[0] > decode[1] ? value <= 0.5 : value >= 0.5
        painted ? 1.0 : 0.0
      end

      #: (Array[Numeric], Integer, Integer) -> Array[Numeric]
      def resample(values, source_width, source_height)
        return values if source_width == @width && source_height == @height
        @height.times.flat_map { |y|
          source_y = (y * source_height).fdiv(@height).floor
          @width.times.map { |x|
            source_x = (x * source_width).fdiv(@width).floor
            values[(source_y * source_width) + source_x]
          }
        }
      end

      #: (Array[Integer], Array[Integer]) -> void
      def multiply!(alpha, mask_alpha)
        alpha.each_index { |index|
          alpha[index] = (alpha[index] * mask_alpha[index] / 255.0).round
        }
      end

      #: (PDF::Reader::Stream, Symbol) -> Integer
      def integer(mask, key)
        value = mask.hash[key]
        unless value.is_a?(Integer)
          raise MalformedPDFError, "mask #{key} must be an integer"
        end
        value
      end
    end
  end
end

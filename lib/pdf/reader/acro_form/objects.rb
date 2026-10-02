# coding: utf-8
# typed: false
# frozen_string_literal: true

require 'set'

class PDF::Reader
  class AcroForm
    module Objects
      FIELD_CONFIG_KEYS = [:FT, :TU, :TM, :Ff, :V, :DV, :Opt, :DA, :Q].freeze
      INHERITED_FIELD_CONFIG_KEYS = [:FT, :Ff, :V, :DV, :Opt, :DA, :Q].freeze
      ROOT_INHERIT_KEYS = [:DA, :Q, :DR].freeze
      WIDGET_CONFIG_KEYS = [:F, :Rect, :Border, :BS, :MK, :H, :DA, :Q].freeze

      private

      def slice_raw(dict, keys)
        keys.each_with_object({}) { |key, target|
          target[key] = dict[key] if dict.key?(key)
        }
      end

      def select_inherited_field_config(config)
        config.select { |key, _value|
          INHERITED_FIELD_CONFIG_KEYS.include?(key)
        }
      end

      def materialize(value, seen = Set.new)
        case value
        when PDF::Reader::Reference
          return nil if seen.include?(value)

          seen.add(value)
          materialize(@objects.deref(value), seen)
        when ::Hash
          value.each_with_object({}) { |(key, item), target|
            target[key] = materialize(item, seen)
          }
        when ::Array
          value.map { |item| materialize(item, seen) }
        when PDF::Reader::Stream
          value
        when ::String
          PDF::Reader::EncodingUtils.string_to_utf8(value)
        else
          value
        end
      rescue PDF::Reader::MalformedPDFError
        nil
      end

      def safe_hash(value)
        dict = @objects.deref_hash(value)
        dict if dict.is_a?(::Hash)
      rescue PDF::Reader::MalformedPDFError
        nil
      end

      def safe_array(value)
        array = @objects.deref_array(value)
        array if array.is_a?(::Array)
      rescue PDF::Reader::MalformedPDFError
        nil
      end

      def object_key(value)
        if value.is_a?(PDF::Reader::Reference)
          [:reference, value.id, value.gen]
        elsif value.is_a?(::Hash)
          [:object, value.object_id]
        end
      end

      def reference_label(value)
        "#{value.id}:#{value.gen} R" if value.is_a?(PDF::Reader::Reference)
      end
    end
  end
end

# coding: utf-8
# typed: true
# frozen_string_literal: true

class PDF::Reader
  class AcroForm
    # Read-only representation of a single widget annotation. A field may have
    # several widgets, including widgets on different pages.
    class Widget
      #: PDF::Reader::ObjectHash
      attr_reader :objects

      #: PDF::Reader::Reference?
      attr_reader :reference

      #: untyped
      attr_reader :parent_reference

      #: Hash[Symbol, untyped]
      attr_reader :raw_dictionary

      alias_method :dictionary, :raw_dictionary

      #: Hash[Symbol, untyped]
      attr_accessor :attributes

      #: Array[Integer]
      attr_accessor :page_numbers

      #: (PDF::Reader::ObjectHash, untyped, Hash[Symbol, untyped]) -> void
      def initialize(objects, raw, dictionary)
        @objects = objects
        @reference = raw.is_a?(PDF::Reader::Reference) ? raw : nil
        @dictionary = dictionary
        @raw_dictionary = dictionary
        @parent_reference = dictionary[:Parent]
        @attributes = PDF::Reader::EncodingUtils.obj_to_utf8(dereferenced_dictionary)
        @page_numbers = []

        appearance = dereference(@dictionary[:AP])
        @appearance = appearance.is_a?(::Hash) ? appearance : {}
        normal = dereference(@appearance[:N])
        @normal_appearance = normal.is_a?(::Hash) || normal.is_a?(PDF::Reader::Stream)
        @appearance_states = if normal.is_a?(::Hash)
          normal.keys.select { |key| key.is_a?(Symbol) }
        else
          []
        end
      end

      # The widget's appearance state (AS), usually :Off or an export name.
      #
      #: () -> Symbol?
      def appearance_state
        value = dereference(@dictionary[:AS])
        value.is_a?(Symbol) ? value : nil
      end

      alias_method :as, :appearance_state

      #: () -> Array[Symbol]
      def appearance_states
        @appearance_states.dup
      end

      #: () -> bool
      def normal_appearance?
        @normal_appearance
      end

      #: () -> :on | :off | :unknown | :invalid
      def state
        state_name = appearance_state
        return :unknown if state_name.nil?

        normal = dereference(@appearance[:N])
        if normal.is_a?(::Hash) && !normal.empty? && !normal.key?(state_name)
          :invalid
        elsif state_name == :Off
          :off
        else
          :on
        end
      end

      def on?
        state == :on
      end

      def off?
        state == :off
      end

      #: () -> Integer?
      def page_number
        @page_numbers.first
      end

      #: () -> PDF::Reader::Page?
      def page
        pages.first
      end

      #: () -> Array[PDF::Reader::Page]
      def pages
        @page_numbers.map { |number| PDF::Reader::Page.new(@objects, number) }
      end

      #: () -> Array[Numeric]?
      def rect
        @attributes[:Rect].is_a?(Array) ? @attributes[:Rect] : nil
      end

      private

      #: (untyped) -> untyped
      def dereference(value)
        @objects.deref(value)
      rescue MalformedPDFError
        nil
      end

      #: () -> Hash[Symbol, untyped]
      def dereferenced_dictionary
        (@dictionary || {}).each_with_object({}) do |(key, value), result|
          result[key] = dereference(value)
        end
      end
    end
  end
end

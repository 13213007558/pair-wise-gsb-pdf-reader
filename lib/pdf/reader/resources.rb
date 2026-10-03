# coding: utf-8
# typed: strict
# frozen_string_literal: true

module PDF
  class Reader

    # mixin for common methods in Page and FormXobjects
    #
    class Resources

      #: (PDF::Reader::ObjectHash, Hash[untyped, untyped]) -> void
      def initialize(objects, resources)
        @objects = objects
        @resources = resources
      end

      # Returns a Hash of color spaces that are available to this page
      #
      # NOTE: this method de-serialise objects from the underlying PDF
      #       with no caching. You will want to cache the results instead
      #       of calling it over and over.
      #
      #: () -> Hash[Symbol, untyped]
      def color_spaces
        @objects.deref_hash!(@resources[:ColorSpace]) || {}
      end

      # Returns a Hash of fonts that are available to this page
      #
      # NOTE: this method de-serialise objects from the underlying PDF
      #       with no caching. You will want to cache the results instead
      #       of calling it over and over.
      #
      #: () -> Hash[Symbol, untyped]
      def fonts
        @objects.deref_hash!(@resources[:Font]) || {}
      end

      # Returns a Hash of external graphic states that are available to this
      # page
      #
      # NOTE: this method de-serialise objects from the underlying PDF
      #       with no caching. You will want to cache the results instead
      #       of calling it over and over.
      #
      #: () -> Hash[Symbol, untyped]
      def graphic_states
        @objects.deref_hash!(@resources[:ExtGState]) || {}
      end

      # Returns a Hash of patterns that are available to this page
      #
      # NOTE: this method de-serialise objects from the underlying PDF
      #       with no caching. You will want to cache the results instead
      #       of calling it over and over.
      #
      #: () -> Hash[Symbol, untyped]
      def patterns
        @objects.deref_hash!(@resources[:Pattern]) || {}
      end

      # Returns an Array of procedure sets that are available to this page
      #
      # NOTE: this method de-serialise objects from the underlying PDF
      #       with no caching. You will want to cache the results instead
      #       of calling it over and over.
      #
      #: () -> Array[Symbol]
      def procedure_sets
        @objects.deref_array!(@resources[:ProcSet]) || []
      end

      # Returns a Hash of properties sets that are available to this page
      #
      # NOTE: this method de-serialise objects from the underlying PDF
      #       with no caching. You will want to cache the results instead
      #       of calling it over and over.
      #
      #: () -> Hash[Symbol, untyped]
      def properties
        @objects.deref_hash!(@resources[:Properties]) || {}
      end

      # Returns a Hash of shadings that are available to this page
      #
      # NOTE: this method de-serialise objects from the underlying PDF
      #       with no caching. You will want to cache the results instead
      #       of calling it over and over.
      #
      #: () -> Hash[Symbol, untyped]
      def shadings
        @objects.deref_hash!(@resources[:Shading]) || {}
      end

      # Returns a Hash of XObjects that are available to this page
      #
      # NOTE: this method de-serialise objects from the underlying PDF
      #       with no caching. You will want to cache the results instead
      #       of calling it over and over.
      #
      #: () -> Hash[Symbol, PDF::Reader::Stream]
      def xobjects
        dict = @objects.deref_hash!(@resources[:XObject]) || {}
        TypeCheck.cast_to_pdf_dict_with_stream_values!(dict)
      end

      # Returns a Hash of decoded image XObjects that are available to this
      # page or form. Form XObjects are excluded - they are available via
      # #xobjects, but they contain content streams rather than pixels.
      #
      # The keys are the labels used within the content stream (e.g. :Im1),
      # the values are PDF::Reader::ImageXObject instances that can produce
      # raw RGBA samples. This method decodes no pixels itself; call
      # ImageXObject#rgba to decode a particular image.
      #
      #: () -> Hash[Symbol, PDF::Reader::ImageXObject]
      def images
        xobjects.each_with_object({}) { |(label, xobject), collected|
          next unless xobject.hash[:Subtype] == :Image

          collected[label] = ImageXObject.new(
            xobject,
            objects: @objects,
            color_spaces: color_spaces
          )
        }
      end

    end
  end
end

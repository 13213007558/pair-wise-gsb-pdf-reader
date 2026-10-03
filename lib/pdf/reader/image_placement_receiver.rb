# coding: utf-8
# typed: strict
# frozen_string_literal: true

require 'forwardable'

module PDF
  class Reader
    # Records every image XObject painted while a page/form content stream walks.
    class ImagePlacementReceiver
      extend Forwardable

      #: Array[PDF::Reader::ImagePlacement]
      attr_reader :placements
      alias image_positions placements

      def_delegators :@state, :save_graphics_state, :restore_graphics_state,
                     :concatenate_matrix

      #: () -> void
      def initialize
        @placements = [] #: Array[PDF::Reader::ImagePlacement]
      end

      #: (PDF::Reader::Page) -> void
      def page=(page)
        @page = page
        @state = PageState.new(page)
        @placements = []
      end

      #: (Symbol) -> void
      def invoke_xobject(label)
        @state.invoke_xobject(label) do |xobject|
          case xobject
          when PDF::Reader::Stream
            if xobject.hash[:Subtype] == :Image
              image = ImageXObject.new(
                xobject,
                :color_spaces => @state.current_color_spaces,
                :objects => @page.objects,
              )
              placements << ImagePlacement.new(
                :image => image,
                :label => label,
                :matrix => @state.current_transformation_matrix.to_a.values_at(0, 1, 3, 4, 6, 7),
              )
            end
          when PDF::Reader::FormXObject
            xobject.walk(self)
          end
        end
      end
    end
  end
end

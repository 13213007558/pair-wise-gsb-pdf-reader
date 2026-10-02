# coding: utf-8
# typed: false
# frozen_string_literal: true

class PDF::Reader
  class AcroForm
    module PageIndex
      private

      def build_page_index
        @page_numbers = {}
        @page_widgets = {}
        @page_widget_keys = {}

        @objects.page_references.each_with_index do |page_raw, index|
          index_page(page_raw, index + 1)
        end
      rescue PDF::Reader::MalformedPDFError => error
        diagnostic(:page_tree_unavailable, error.message, @root[:Fields])
      end

      def index_page(page_raw, page_number)
        page_key = object_key(page_raw)
        @page_numbers[page_key] = page_number if page_key

        page = safe_hash(page_raw) || {}
        Array(safe_array(page[:Annots])).each do |annot_raw|
          annot = safe_hash(annot_raw)
          next unless annot && (annot[:Subtype] == :Widget || annot.key?(:Parent))

          key = object_key(annot_raw)
          next unless key

          @page_widget_keys[key] = annot_raw
          @page_widgets[key] = page_number
        end
      end

      def page_for_widget(raw, key, dict)
        @page_widgets[key] || @page_numbers[object_key(dict[:P])]
      end
    end
  end
end

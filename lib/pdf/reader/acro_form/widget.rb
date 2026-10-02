# coding: utf-8
# typed: false
# frozen_string_literal: true

class PDF::Reader
  class AcroForm
    class Widget
      attr_reader :type, :config, :state, :appearances, :appearance_states,
                  :page, :rect, :object_reference, :diagnostics

      def initialize(attrs)
        @type = attrs.fetch(:type)
        @config = attrs.fetch(:config)
        @state = attrs[:state]
        @appearances = attrs.fetch(:appearances)
        @appearance_states = attrs.fetch(:appearance_states)
        @page = attrs.fetch(:page)
        @rect = attrs.fetch(:rect)
        @object_reference = attrs.fetch(:object_reference)
        @diagnostics = attrs.fetch(:diagnostics)
      end

      alias page_number page
    end
  end
end

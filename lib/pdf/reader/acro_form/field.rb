# coding: utf-8
# typed: false
# frozen_string_literal: true

class PDF::Reader
  class AcroForm
    class Field
      attr_reader :name, :type, :field_type, :config, :flags, :options,
                  :value, :default_value, :widgets, :conflicts, :diagnostics,
                  :value_sources, :objects
      alias full_name name

      def initialize(attrs)
        @name = attrs.fetch(:name)
        @type = attrs.fetch(:type)
        @field_type = attrs.fetch(:field_type)
        @config = attrs.fetch(:config)
        @flags = attrs.fetch(:flags)
        @options = attrs.fetch(:options)
        @value = attrs.fetch(:value)
        @default_value = attrs.fetch(:default_value)
        @widgets = attrs.fetch(:widgets)
        @conflicts = attrs.fetch(:conflicts)
        @diagnostics = attrs.fetch(:diagnostics)
        @value_sources = attrs.fetch(:value_sources)
        @objects = attrs.fetch(:objects)
      end

      def multiple_selection?
        !!@flags[:multi_select]
      end

      def selected_labels
        selected = Array(@value)
        @options.select { |option|
          selected.include?(option[:value])
        }.map { |option| option[:label] }
      end
    end
  end
end

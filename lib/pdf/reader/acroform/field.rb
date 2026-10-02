# coding: utf-8
# typed: true
# frozen_string_literal: true

class PDF::Reader
  class AcroForm
    # Normalised view of a terminal AcroForm field. The value attribute keeps
    # the field's V entry, each widget's AS/AP information, and any conflicts
    # between those independent sources.
    class Field
      RADIO_FLAG = 1 << 15
      PUSHBUTTON_FLAG = 1 << 16
      MULTISELECT_FLAG = 1 << 20

      #: String
      attr_reader :name

      #: Symbol
      attr_reader :type

      #: Symbol?
      attr_reader :pdf_type

      #: Integer
      attr_reader :flags

      #: Hash[Symbol, untyped]
      attr_reader :config

      alias_method :attributes, :config

      alias_method :full_name, :name

      #: Array[PDF::Reader::AcroForm::Widget]
      attr_accessor :widgets

      #: PDF::Reader::Reference?
      attr_reader :reference

      #: (...) -> void
      def initialize(name, pdf_type, flags, config, widgets, reference, objects)
        @name = name
        @pdf_type = pdf_type
        @flags = flags
        @config = config
        @widgets = widgets
        @reference = reference
        @objects = objects
        @type = detect_type
        @state = nil
      end

      #: () -> untyped
      def value
        state.logical_value
      end

      #: () -> untyped
      def logical_value
        state.logical_value
      end

      #: () -> PDF::Reader::AcroForm::Value
      def state
        @state ||= build_state
      end

      #: () -> Array[Hash[Symbol, untyped]]
      def conflicts
        state.conflicts
      end

      def conflict?
        !conflicts.empty?
      end

      #: () -> untyped
      def raw_value
        state.field_value
      end

      #: () -> Array[Hash[Symbol, untyped]]
      def options
        Array(@config[:Opt]).map do |option|
          if option.is_a?(Array)
            { value: option[0], label: option[1] || option[0] }
          else
            { value: option, label: option }
          end
        end
      end

      def multiple?
        @type == :choice && (@flags & MULTISELECT_FLAG) != 0
      end

      def radio?
        @type == :radio
      end

      def checkbox?
        @type == :checkbox
      end

      def text?
        @type == :text
      end

      def choice?
        @type == :choice
      end

      #: () -> Array[Integer]
      def page_numbers
        @widgets.flat_map(&:page_numbers).uniq.sort
      end

      #: () -> Integer?
      def page_number
        page_numbers.first
      end

      private

      #: () -> Symbol
      def detect_type
        case @pdf_type
        when :Tx then :text
        when :Ch then :choice
        when :Sig then :signature
        when :Btn
          if (@flags & PUSHBUTTON_FLAG) != 0
            :push_button
          elsif (@flags & RADIO_FLAG) != 0
            :radio
          else
            :checkbox
          end
        else
          :unknown
        end
      end

      #: () -> PDF::Reader::AcroForm::Value
      def build_state
        conflicts = []
        widget_states = build_widget_states(conflicts)

        field_value, appearance_value, logical_value = case @type
        when :text then text_value(conflicts)
        when :checkbox then checkbox_value(widget_states, conflicts)
        when :radio then radio_value(widget_states, conflicts)
        when :choice then choice_value(conflicts)
        else [@config[:V], nil, @config[:V]]
        end

        Value.new(field_value, appearance_value, logical_value, widget_states, conflicts)
      end

      #: (Array[Hash[Symbol, untyped]]) -> Array[Hash[Symbol, untyped]]
      def build_widget_states(conflicts)
        @widgets.map do |widget|
          state = widget.state
          if state == :invalid
            state_name = widget.appearance_state.inspect
            message = "widget AS #{state_name} is not in AP/N"
            conflicts << conflict(:invalid_appearance_state, message,
              widget_reference: widget.reference,
              page_numbers: widget.page_numbers)
          end

          {
            reference: widget.reference,
            page_numbers: widget.page_numbers,
            as: widget.appearance_state,
            state: state,
            appearance_states: widget.appearance_states,
            has_appearance: widget.normal_appearance?
          }
        end
      end

      #: (...) -> [untyped, untyped, untyped]
      def text_value(conflicts)
        value = @config[:V]
        unless value.nil? || value.is_a?(String)
          conflicts << conflict(:invalid_value_type, "text V must be a String", value: value)
        end
        [value, nil, value]
      end

      #: (...) -> [untyped, untyped, untyped]
      def checkbox_value(widget_states, conflicts)
        raw_field = @config[:V]
        field = raw_field == :Off ? false : !raw_field.nil?
        appearance = consistent_button_state(widget_states, conflicts)

        if !field.nil? && !appearance.nil? && field != appearance
          add_conflict(conflicts, :value_conflict,
            "field V and widget AS disagree",
            field_value: field, appearance_value: appearance)
        end

        logical = raw_field.nil? ? appearance : field
        [raw_field, appearance, logical]
      end

      #: (...) -> [untyped, untyped, untyped]
      def radio_value(widget_states, conflicts)
        raw_field = @config[:V]
        explicit_off = raw_field == :Off
        field = explicit_off ? nil : raw_field
        if !field.nil? && !field.is_a?(Symbol)
          conflicts << conflict(:invalid_value_type, "radio V must be a Name", value: field)
        end

        selected = widget_states.select { |state| state[:state] == :on }
        if selected.size > 1
          values = selected.map { |state| state[:as] }
          add_conflict(conflicts, :multiple_radio_selections,
            "more than one radio widget is selected", values: values)
        end

        appearance = selected.size == 1 ? selected.first[:as] : nil
        if field && selected.empty?
          add_conflict(conflicts, :value_conflict,
            "field V is set but no widget AS selects it",
            field_value: field)
        elsif field && appearance && field != appearance
          add_conflict(conflicts, :value_conflict,
            "field V and widget AS disagree",
            field_value: field, appearance_value: appearance)
        elsif explicit_off && !selected.empty?
          add_conflict(conflicts, :value_conflict,
            "field V is Off but a widget is selected",
            appearance_value: appearance)
        elsif field.nil? && selected.size > 1
          values = selected.map { |state| state[:as] }
          add_conflict(conflicts, :value_conflict,
            "widget AS entries do not identify one radio value",
            appearance_values: values)
        end

        logical = raw_field.nil? ? appearance : field
        [raw_field, appearance, logical]
      end

      #: (...) -> [untyped, untyped, untyped]
      def choice_value(conflicts)
        raw = @config[:V]
        values = Array(raw)

        if multiple? && !raw.is_a?(Array)
          add_conflict(conflicts, :invalid_value_type,
            "multi-select choice V must be an Array", value: raw)
        elsif !multiple? && raw.is_a?(Array)
          add_conflict(conflicts, :invalid_value_type,
            "single-select choice V must not be an Array", value: raw)
          return [raw, nil, nil]
        end

        if values != values.uniq
          add_conflict(conflicts, :duplicate_choice_selection,
            "multi-select choice V contains duplicate values",
            values: values)
        end

        values.each { |item| validate_choice(item, conflicts) }
        logical = multiple? ? values : values.first
        [raw, nil, logical]
      end

      #: (untyped, Array[Hash[Symbol, untyped]]) -> untyped
      def validate_choice(value, conflicts)
        option = options.find { |candidate| candidate[:value] == value }
        unless option
          add_conflict(conflicts, :unknown_choice_value,
            "choice V is not present in Opt", value: value)
        end
      end

      #: (Array[Hash[Symbol, untyped]], Array[Hash[Symbol, untyped]]) -> untyped
      def consistent_button_state(widget_states, conflicts)
        known = widget_states.select { |state| state[:state] == :on || state[:state] == :off }
        values = known.map { |state| state[:state] == :on }
        if values.uniq.size > 1
          states = widget_states.map { |state| state[:as] }
          add_conflict(conflicts, :value_conflict,
            "widget AS entries disagree", appearance_values: states)
          nil
        else
          values.first
        end
      end

      #: (Symbol, String, Hash[Symbol, untyped]) -> Hash[Symbol, untyped]
      def conflict(code, message, details = {})
        {
          code: code,
          message: message,
          field: @name
        }.merge(details)
      end

      #: (Array[Hash[Symbol, untyped]], Symbol, String, Hash[Symbol, untyped]) -> void
      def add_conflict(conflicts, code, message, details = {})
        conflicts << conflict(code, message, details)
      end
    end

    class Value
      #: untyped
      attr_reader :field_value

      #: untyped
      attr_reader :appearance_value

      #: untyped
      attr_reader :logical_value

      #: Array[Hash[Symbol, untyped]]
      attr_reader :widget_states

      #: Array[Hash[Symbol, untyped]]
      attr_reader :conflicts

      #: (...) -> void
      def initialize(field_value, appearance_value, logical_value, widget_states, conflicts)
        @field_value = field_value
        @appearance_value = appearance_value
        @logical_value = logical_value
        @widget_states = widget_states
        @conflicts = conflicts
      end

      def conflict?
        !@conflicts.empty?
      end
    end
  end
end

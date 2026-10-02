# coding: utf-8
# typed: false
# frozen_string_literal: true

class PDF::Reader
  class AcroForm
    class ValueAnalyzer
      NormalizedValue = Struct.new(:value, :conflicts)
      FieldView = Struct.new(:type, :flags, :config, :widgets, :value_sources)

      def analyze(field)
        type = field.type
        value, conflicts =
          case type
          when :text then scalar_value(:text, field)
          when :choice then choice_value(field)
          when :checkbox then checkbox_value(field)
          when :radio then radio_value(field)
          else [nil, []]
          end

        default = normalize(type, field.flags, field.config[:DV])
        [value, default.value, conflicts]
      end

      private

      def checkbox_value(field)
        values = field_values(field).map { |value| button_state(value) }
        values.concat(widget_states(field).map { |state| state == :Off ? false : state })
        conflicts = button_conflicts(values, field, false)

        selected = values.uniq
        value =
          if conflicts.any?
            nil
          elsif selected.empty?
            nil
          elsif selected.all? { |item| item == false }
            false
          elsif selected.none? { |item| item == false }
            true
          end

        [value, conflicts]
      end

      def radio_value(field)
        values = field_values(field).map { |value|
          state = button_state(value)
          state == false ? :Off : state
        }
        values.concat(widget_states(field))

        conflicts = button_conflicts(values, field, true)
        selected = values.reject { |value| value == :Off }.uniq
        [conflicts.any? ? nil : selected.first, conflicts]
      end

      def button_conflicts(values, field, radio)
        conflicts = []
        field_values = field_values(field)
        widget_states = widget_states(field)
        active_widget_states = widget_states.reject { |state| state == :Off }.uniq

        if field_values.uniq.size > 1
          conflicts << make_conflict(
            :inconsistent_field_value,
            "Field /V has conflicting inherited values",
            field
          )
        end

        add_state_conflicts(
          conflicts,
          field,
          field_values.last,
          active_widget_states,
          widget_states,
          radio
        )
        add_appearance_conflicts(conflicts, field, field_values.last)

        active = widget_states.reject { |state| state == :Off }.uniq
        if radio && active.size > 1
          conflicts << make_conflict(
            :multiple_radio_states,
            "More than one radio button in a group is selected",
            field
          )
        end

        conflicts
      end

      def add_state_conflicts(conflicts, field, field_value, active, widget_states, radio)
        return if field_value.nil?

        field_state = button_state(field_value)
        field_state = :Off if field_state == false

        if radio
          if conflicting_radio_state?(field_state, active, widget_states)
            conflicts << inconsistent_state(field)
          end
        elsif (field_values_with_widget(field) << field_state).uniq.size > 1
          conflicts << inconsistent_state(field)
        end
      end

      def conflicting_radio_state?(field_state, active, widget_states)
        (field_state == :Off && active.any?) ||
          (field_state != :Off && widget_states.any? && active.empty?) ||
          (field_state != :Off && active.any? && active != [field_state])
      end

      def field_values_with_widget(field)
        widget_states(field).map { |state| state == :Off ? false : state }
      end

      def add_appearance_conflicts(conflicts, field, field_value)
        field.widgets.each do |widget|
          unless widget.state.nil? || !widget.appearances || appearance_has?(widget, widget.state)
            conflicts << make_conflict(
              :missing_appearance_state,
              "Widget /AS is not present in /AP /N",
              field,
              :page => widget.page,
              :object => widget.object_reference
            )
          end
        end

        return if field_value.nil?

        state = button_state(field_value)
        state = :Off if state == false
        return if state == :Off
        return unless field.widgets.any?(&:appearances)
        return if field.widgets.any? { |widget| appearance_has?(widget, state) }

        conflicts << make_conflict(
          :missing_appearance_state,
          "Field /V is not present in widget /AP /N",
          field
        )
      end

      def scalar_value(type, field)
        values = field_values(field)
        conflicts = distinct_field_values(values, field)
        normalized = normalize(type, field.flags, values.last)
        conflicts.concat(normalized.conflicts)
        [conflicts.any? ? nil : normalized.value, conflicts]
      end

      def choice_value(field)
        values = field_values(field)
        conflicts = distinct_field_values(values, field)
        normalized = normalize(:choice, field.flags, values.last)
        conflicts.concat(normalized.conflicts)
        [conflicts.any? ? nil : normalized.value, conflicts]
      end

      def distinct_field_values(values, field)
        return [] if values.uniq.size <= 1

        [inconsistent_state(field)]
      end

      def normalize(type, flags, value)
        return NormalizedValue.new(nil, []) if value.nil?

        case type
        when :text
          if value.is_a?(::String)
            NormalizedValue.new(value, [])
          else
            invalid("Text field /V must be a string", value)
          end
        when :choice
          if !flags[:multi_select]
            NormalizedValue.new(value, [])
          elsif value.is_a?(::Array)
            NormalizedValue.new(value, [])
          else
            invalid("Multi-select choice field /V must be an Array", value)
          end
        else
          NormalizedValue.new(nil, [])
        end
      end

      def invalid(message, value)
        NormalizedValue.new(
          nil,
          [make_conflict(:invalid_field_value, message, nil, :value => value)]
        )
      end

      def button_state(value)
        case value
        when Symbol then value == :Off ? false : value
        when String then value.downcase == "off" ? false : value.to_sym
        when true, false then value
        else value
        end
      end

      def field_values(field)
        sources(field).select { |source| source[:source] == :V }.map { |source| source[:value] }
      end

      def widget_states(field)
        field.widgets.map(&:state).compact.map { |state| button_state(state) }.map {
          |state| state == false ? :Off : state
        }
      end

      def sources(field)
        field.value_sources
      end

      def appearance_has?(widget, state)
        normal = widget.appearances.is_a?(::Hash) ? widget.appearances[:N] : nil
        normal.is_a?(::Hash) && normal.key?(state)
      end

      def inconsistent_state(field)
        make_conflict(:inconsistent_field_value, "Field /V and widget /AS do not agree", field)
      end

      def make_conflict(code, message, field, extra = {})
        {
          :code => code,
          :message => message,
          :sources => field ? field.value_sources : [],
        }.merge(extra)
      end
    end
  end
end

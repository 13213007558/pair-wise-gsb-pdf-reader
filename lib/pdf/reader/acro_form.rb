# coding: utf-8
# typed: false
# frozen_string_literal: true

require 'set'
require 'pdf/reader/acro_form/field'
require 'pdf/reader/acro_form/widget'
require 'pdf/reader/acro_form/value_analyzer'
require 'pdf/reader/acro_form/objects'
require 'pdf/reader/acro_form/page_index'
require 'pdf/reader/acro_form/field_tree'

class PDF::Reader
  class AcroForm
    include Objects
    include PageIndex
    include FieldTree

    COMMON_FLAGS = {
      :read_only => 1,
      :required => 2,
      :no_export => 4,
    }.freeze

    TEXT_FLAGS = {
      :multiline => 4096,
      :password => 8192,
      :file_select => 1_048_576,
      :do_not_spell_check => 4_194_304,
      :do_not_scroll => 8_388_608,
      :comb => 16_777_216,
      :rich_text => 33_554_432,
    }.freeze

    BUTTON_FLAGS = {
      :no_toggle_to_off => 16_384,
      :radio => 32_768,
      :push_button => 65_536,
      :radios_in_unison => 33_554_432,
    }.freeze

    CHOICE_FLAGS = {
      :combo => 131_072,
      :edit => 262_144,
      :sort => 524_288,
      :multi_select => 2_097_152,
      :do_not_spell_check => 4_194_304,
      :commit_on_selection_change => 67_108_864,
    }.freeze

    attr_reader :fields, :fields_by_name, :widgets, :diagnostics, :config

    def initialize(objects, root)
      @objects = objects
      @root = safe_hash(root) || {}
      @fields = []
      @fields_by_name = {}
      @widgets = []
      @widgets_by_key = {}
      @diagnostics = []
      @visited = Set.new
      @terminal_fields = Set.new
      @root_inherited_config = slice_raw(@root, Objects::ROOT_INHERIT_KEYS)
      @config = materialize(@root_inherited_config.dup)

      build_page_index
      build_fields
    end

    def field(full_name)
      @fields_by_name[full_name]
    end

    def field_names
      @fields.map(&:name)
    end

    def each_field(&block)
      return enum_for(:each_field) unless block

      @fields.each(&block)
    end

    private

    attr_reader :root_inherited_config

    def build_field(raw, dict, merged_raw_config, name_parts, chain, widget_raws)
      key = object_key(raw)
      if key && @terminal_fields.include?(key)
        diagnostic(:field_repeated, "Terminal field appears more than once", raw)
        return
      end
      @terminal_fields.add(key) if key

      widgets = widget_raws.map { |widget_raw|
        widget_for_field(widget_raw, merged_raw_config)
      }.compact

      if dict[:Subtype] == :Widget &&
         widgets.none? { |widget| widget.object_reference == reference_label(raw) }
        widgets.unshift(widget_for_field(raw, merged_raw_config))
      end

      config = materialize(merged_raw_config.dup)
      field_type = normalized_field_type(config[:FT])
      type = detailed_type(field_type, config[:Ff])
      flags = flags_for(type, config[:Ff])
      options = choice_options(config[:Opt])
      sources = build_value_sources(chain, widgets)
      view = ValueAnalyzer::FieldView.new(type, flags, config, widgets, sources)
      value, default_value, conflicts = ValueAnalyzer.new.analyze(view)
      @diagnostics.concat(conflicts)
      name = name_parts.map(&:to_s).join(".")

      field = Field.new(
        :name => name,
        :type => type,
        :field_type => field_type,
        :config => config,
        :flags => flags,
        :options => options,
        :value => value,
        :default_value => default_value,
        :widgets => widgets,
        :conflicts => conflicts,
        :diagnostics => conflicts.dup,
        :value_sources => sources,
        :objects => chain.map { |item| reference_label(item) }.compact
      )

      widgets.each { |widget| widget.diagnostics.concat(conflicts) }
      register_field(field, raw)
    end

    def register_field(field, raw)
      existing = @fields_by_name[field.name]
      if existing
        duplicate = duplicate_field_diagnostic(field.name, raw)
        existing.diagnostics << duplicate
        field.diagnostics << duplicate
        @diagnostics << duplicate
      else
        @fields_by_name[field.name] = field
      end
      @fields << field
    end

    def duplicate_field_diagnostic(name, raw)
      {
        :code => :duplicate_full_name,
        :message => "Two field trees use the full field name #{name.inspect}",
        :objects => [reference_label(raw)].compact,
      }
    end

    def widget_for_field(raw, field_config)
      key = object_key(raw)
      existing = key && @widgets_by_key[key]
      return existing if existing

      dict = safe_hash(raw)
      unless dict
        diagnostic(:invalid_widget, "Expected a widget dictionary", raw)
        return nil
      end

      widget_config = field_config.merge(slice_raw(dict, Objects::WIDGET_CONFIG_KEYS))
      appearances = materialize(dict[:AP])
      page = page_for_widget(raw, key, dict)
      widget = Widget.new(
        :type => :widget,
        :config => materialize(widget_config),
        :state => materialize(dict[:AS]),
        :appearances => appearances,
        :appearance_states => appearance_states(appearances),
        :page => page,
        :rect => materialize(dict[:Rect]),
        :object_reference => reference_label(raw),
        :diagnostics => []
      )

      if page.nil?
        widget.diagnostics << {
          :code => :widget_without_page,
          :message => "Widget is not linked to a page",
          :objects => [reference_label(raw)].compact,
        }
      end

      @widgets_by_key[key] = widget if key
      @widgets << widget
      widget
    end

    def collect_orphan_widgets
      @page_widgets.each do |key, page_number|
        next if @widgets_by_key.key?(key)

        raw = @page_widget_keys[key]
        dict = safe_hash(raw)
        next unless dict && (dict[:Subtype] == :Widget || dict.key?(:Parent))
        collect_orphan_widget(raw, dict, page_number)
      end
    end

    def collect_orphan_widget(raw, dict, page_number)
      if dict[:Parent]
        diagnostic(
          :field_missing_from_acroform_fields,
          "Widget parent is not listed in AcroForm /Fields",
          raw
        )
        traverse(dict[:Parent], root_inherited_config.dup, [], nil, Set.new, [])
      else
        widget = widget_for_field(raw, {})
        issue = diagnostic(
          :orphan_widget,
          "Widget is not connected to an AcroForm field",
          raw,
          :page => page_number
        )
        widget&.diagnostics << issue
      end
    end

    def build_value_sources(chain, widgets)
      sources = chain.flat_map { |field_raw| field_value_sources(field_raw) }
      widgets.each do |widget|
        sources << widget_state_source(widget) unless widget.state.nil?
        sources << widget_appearance_source(widget) if widget.appearances
      end
      sources
    end

    def field_value_sources(field_raw)
      dict = safe_hash(field_raw) || {}
      sources = []
      [:V, :DV].each do |key|
        next unless dict.key?(key)

        sources << {
          :source => key,
          :object => reference_label(field_raw),
          :value => materialize(dict[key]),
        }
      end
      sources
    end

    def widget_state_source(widget)
      {
        :source => :AS,
        :object => widget.object_reference,
        :page => widget.page,
        :value => widget.state,
      }
    end

    def widget_appearance_source(widget)
      {
        :source => :AP,
        :object => widget.object_reference,
        :page => widget.page,
        :states => widget.appearance_states,
      }
    end

    def normalized_field_type(type)
      case type
      when :Tx then :Tx
      when :Btn then :Btn
      when :Ch then :Ch
      when :Sig then :Sig
      when nil then nil
      else :unknown
      end
    end

    def detailed_type(field_type, flags_integer)
      case field_type
      when :Tx then :text
      when :Ch then :choice
      when :Btn then button_type(flags_integer)
      else field_type
      end
    end

    def button_type(flags_integer)
      if flag_set?(flags_integer, 65_536)
        :push_button
      elsif flag_set?(flags_integer, 32_768)
        :radio
      else
        :checkbox
      end
    end

    def flags_for(type, integer)
      COMMON_FLAGS.merge(flag_mappings(type)).each_with_object({}) { |(name, bit), flags|
        flags[name] = flag_set?(integer, bit)
      }
    end

    def flag_mappings(type)
      case type
      when :text then TEXT_FLAGS
      when :radio, :checkbox, :push_button then BUTTON_FLAGS
      when :choice then CHOICE_FLAGS
      else {}
      end
    end

    def flag_set?(integer, bit)
      integer.is_a?(Integer) && (integer & bit) == bit
    end

    def choice_options(raw_options)
      Array(raw_options).map do |option|
        if option.is_a?(::Array)
          { :value => option[0], :label => option[1] || option[0] }
        else
          { :value => option, :label => option }
        end
      end
    end

    def normalize_partial_name(value, raw)
      return nil if value.nil?
      return value if value.is_a?(::String)

      diagnostic(:invalid_field_name, "Field /T must be a string", raw)
      value.to_s
    end

    def appearance_states(ap)
      return [] unless ap.is_a?(::Hash)

      [:N, :R, :D].flat_map { |key|
        appearance = ap[key]
        appearance.is_a?(::Hash) ? appearance.keys : []
      }.uniq
    end

    def diagnostic(code, message, object = nil, extra = {})
      result = {
        :code => code,
        :message => message,
      }.merge(extra)
      labels = [reference_label(object)].compact
      result[:objects] = labels unless labels.empty?
      @diagnostics << result
      result
    end
  end
end

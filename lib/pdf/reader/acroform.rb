# coding: utf-8
# typed: true
# frozen_string_literal: true

require 'pdf/reader/acroform/widget'
require 'pdf/reader/acroform/field'

class PDF::Reader
  # Read-only access to the values and configuration in an interactive form
  # (AcroForm). This class deliberately never regenerates appearance streams
  # and never executes document JavaScript. Conflicts between a field's V and
  # its widgets' AS/AP entries are preserved rather than choosing one value.
  class AcroForm
    include Enumerable

    FIELD_KEYS = [
      :FT, :T, :TU, :TM, :Ff, :V, :DV, :AA, :Opt, :TI
    ].freeze #: Array[Symbol]

    WIDGET_KEYS = [
      :Subtype, :Rect, :Contents, :P, :NM, :M, :F, :AP, :AS, :Border,
      :C, :StructParent, :OC, :H, :MK, :A, :BS
    ].freeze #: Array[Symbol]

    #: PDF::Reader::ObjectHash
    attr_reader :objects

    # The raw AcroForm dictionary. Values are converted to UTF-8 where useful,
    # while PDF references remain available to callers.
    #
    #: Hash[Symbol, untyped]
    attr_reader :attributes

    #: (PDF::Reader::ObjectHash, ?Hash[Symbol, untyped]) -> void
    def initialize(objects, root = {})
      @objects = objects
      catalog = dereference_hash(@objects.trailer[:Root])
      form = catalog ? dereference_hash(catalog[:AcroForm]) : nil
      @attributes = convert(form || {})
      @diagnostics = []
      @fields = []
      @fields_by_name = {}
      @widgets = {}
      @page_numbers = {}
      @terminal_fields = {}

      parse if form
    end

    def each(&block)
      @fields.each(&block)
    end

    #: () -> Array[PDF::Reader::AcroForm::Field]
    def fields
      @fields.dup
    end

    alias_method :form_fields, :fields

    alias_method :to_a, :fields

    #: (String) -> PDF::Reader::AcroForm::Field?
    def field(name)
      @fields.find { |candidate| candidate.name == name }
    end

    alias_method :[], :field

    #: () -> Array[String]
    def field_names
      @fields.map(&:name)
    end

    #: () -> Hash[String, Array[PDF::Reader::AcroForm::Field]]
    def fields_by_name
      @fields_by_name.dup
    end

    #: () -> Array[PDF::Reader::AcroForm::Widget]
    def widgets
      @widgets.values.dup
    end

    #: () -> Array[Hash[Symbol, untyped]]
    def diagnostics
      @diagnostics.dup
    end

    def need_appearances?
      @attributes[:NeedAppearances] == true
    end

    private

    def parse
      map_widget_pages
      traverse_fields
      collect_orphan_widgets
      build_fields
    end

    def map_widget_pages
      page_objects.each_with_index do |page_ref, index|
        page = dereference_hash(page_ref)
        page_number = index + 1
        Array(dereference(page[:Annots])).each do |annotation_ref|
          annotation = dereference_hash(annotation_ref)
          next unless annotation && annotation[:Subtype] == :Widget

          widget = widget_for(annotation_ref, annotation)
          next unless widget

          widget.page_numbers << page_number unless widget.page_numbers.include?(page_number)
        end
      end
    rescue MalformedPDFError => e
      diagnostic(:malformed_pages, e.message)
    end

    def traverse_fields
      root_field_entries.each do |entry|
        traverse_entry(entry, [], [], identity(entry), Set[identity(entry)])
      end
    end

    def root_field_entries
      Array(dereference(@attributes[:Fields])).dup
    end

    #: (...) -> void
    def traverse_entry(entry, field_chain, name_chain, entry_id, active)
      dict = dereference_hash(entry)
      unless dict
        diagnostic(:invalid_field, "field entry is not a dictionary", reference: entry)
        return
      end

      id = entry.is_a?(PDF::Reader::Reference) ? identity(entry) : entry.object_id
      if field_chain.any? && invalid_parent?(entry, fieldchain_last(field_chain))
        diagnostic(:missing_parent,
          "field Parent does not point to its parent", reference: entry)
      end

      child_entries = Array(dereference(dict[:Kids]))
      widget_entries, field_entries = child_entries.partition { |child| widget_kid?(child, dict) }

      if terminal?(dict, widget_entries, field_entries)
        build_terminal(entry, dict, field_chain, name_chain, widget_entries)
        return
      end

      current = { entry: entry, dict: dict, id: id }
      next_name = name_chain + [field_name(dict)]
      field_entries.each do |child|
        child_id = identity(child)
        if active.include?(child_id)
          diagnostic(:cyclic_kids, "Kids tree contains a cycle", reference: child)
          next
        end
        traverse_entry(child, field_chain + [current], next_name, child_id, active + Set[child_id])
      end
    end

    #: (untyped, Array[Hash[Symbol, untyped]], Array[String], Array[untyped]) -> void
    def build_terminal(entry, dict, field_chain, name_chain, widget_entries)
      chains = field_chain + [{ entry: entry, dict: dict, id: identity(entry) }]
      dicts = chains.map { |item| item[:dict] }
      config = inherited_config(dicts)

      type = nearest(dicts, :FT) || @attributes[:FT]
      flags = nearest(dicts, :Ff) || @attributes[:Ff] || 0
      name_parts = name_chain + [field_name(dict)]
      name = name_parts.compact.join(".")

      terminal_widgets = terminal_widgets(entry, dict, widget_entries, dicts, config)
      terminal = {
        name: name,
        type: type,
        flags: flags.to_i,
        config: config,
        reference: entry.is_a?(PDF::Reader::Reference) ? entry : nil,
        widgets: terminal_widgets
      }

      if @terminal_fields.key?(identity(entry))
        diagnostic(:duplicate_field, "field object appears more than once",
          reference: entry, name: name)
      else
        @terminal_fields[identity(entry)] = terminal
      end
    end

    #: (...) -> Array[PDF::Reader::AcroForm::Widget]
    def terminal_widgets(entry, dict, widget_entries, field_dicts, config)
      if widget_entries.empty?
        widget = widget_for(entry, dict, config)
        return [widget].compact
      end

      widget_entries.map do |widget_entry|
        widget_dict = dereference_hash(widget_entry)
        unless widget_dict
          diagnostic(:invalid_widget, "widget kid is not a dictionary", reference: widget_entry)
          next
        end
        unless valid_parent?(widget_entry, entry)
          diagnostic(:missing_parent,
            "widget Parent does not point to its field",
            reference: widget_entry)
        end
        widget_for(widget_entry, widget_dict, config)
      end.compact
    end

    def collect_orphan_widgets
      assigned = @terminal_fields.values.flat_map { |terminal| terminal[:widgets] }.map do |widget|
        identity(widget.reference || widget.raw_dictionary)
      end

      @widgets.each do |id, widget|
        next if assigned.include?(id)

        if widget.parent_reference.nil?
          diagnostic(:missing_parent, "widget has no Parent", reference: widget.reference)
        else
          parent = dereference_hash(widget.parent_reference)
          if parent.nil?
            diagnostic(:missing_parent,
              "widget Parent does not resolve to a field dictionary",
              reference: widget.reference)
          else
            diagnostic(:missing_parent,
              "widget is not listed in its field Kids",
              reference: widget.reference)
          end
        end
      end
    end

    def build_fields
      @terminal_fields.each_value do |terminal|
        field = Field.new(
          terminal[:name],
          terminal[:type],
          terminal[:flags],
          terminal[:config],
          terminal[:widgets],
          terminal[:reference],
          @objects
        )
        @fields << field
        (@fields_by_name[field.name] ||= []) << field
        @diagnostics.concat(field.state.conflicts)
      end

      @fields_by_name.each do |name, fields|
        next unless fields.size > 1
        diagnostic(:duplicate_field_name,
          "full field name #{name.inspect} is used #{fields.size} times",
          name: name)
      end
    end

    #: (untyped, Hash[Symbol, untyped], ?Hash[Symbol, untyped]) -> PDF::Reader::AcroForm::Widget?
    def widget_for(raw, dictionary, field_config = nil)
      id = identity(raw)
      existing = @widgets[id]
      if existing
        assign_widget_config(existing, field_config) if field_config
        return existing
      end

      widget = Widget.new(@objects, raw, dictionary)
      assign_widget_config(widget, field_config) if field_config
      explicit_page = page_number_for(dictionary[:P])
      if explicit_page && !widget.page_numbers.include?(explicit_page)
        widget.page_numbers << explicit_page
      end
      @widgets[id] = widget
    end

    #: (PDF::Reader::AcroForm::Widget, Hash[Symbol, untyped]) -> void
    def assign_widget_config(widget, field_config)
      widget.attributes = convert(field_config.merge(widget.attributes))
    end

    #: (Array[Hash[Symbol, untyped]]) -> Hash[Symbol, untyped]
    def inherited_config(dicts)
      merged = form_default_config
      dicts.each do |dict|
        dict.each do |key, value|
          next if structural_key?(key) || widget_only_key?(key)
          merged[key] = deep_dereference(value)
        end
      end
      convert(merged)
    end

    #: () -> Hash[Symbol, untyped]
    def form_default_config
      selected = @attributes.select do |key, _|
        ![:Fields, :XFA, :CO, :SigFlags, :NeedAppearances].include?(key)
      end
      selected.each_with_object({}) do |(key, value), result|
        result[key] = deep_dereference(value)
      end
    end

    #: (Hash[Symbol, untyped], Array[untyped], Array[untyped]) -> bool
    def terminal?(dict, widget_entries, field_entries)
      field_entries.empty? || dict.key?(:FT)
    end

    #: (untyped, Hash[Symbol, untyped]) -> bool
    def widget_kid?(entry, parent_dict)
      dict = dereference_hash(entry)
      return false unless dict

      dict[:Subtype] == :Widget && !dict.key?(:FT) ||
        (!dict.key?(:Kids) && dict[:Parent] && !dict.key?(:FT) && parent_dict.key?(:FT))
    rescue MalformedPDFError
      false
    end

    #: (untyped, untyped) -> bool
    def valid_parent?(entry, parent)
      dict = dereference_hash(entry)
      return false unless dict
      return false if !dict.key?(:Parent) || dict[:Parent].nil?
      identity(dict[:Parent]) == identity(parent)
    end

    #: (untyped, Hash[Symbol, untyped]) -> bool
    def invalid_parent?(entry, parent_item)
      dict = dereference_hash(entry)
      return false unless dict
      return false if !dict.key?(:Parent) || dict[:Parent].nil?
      identity(dict[:Parent]) != parent_item[:id]
    end

    #: (untyped) -> Integer?
    def page_number_for(page_ref)
      @page_numbers[identity(page_ref)]
    end

    #: () -> Array[untyped]
    def page_objects
      objects = @objects.page_references
      objects.each_with_index { |ref, index| @page_numbers[identity(ref)] = index + 1 }
      objects
    end

    #: (Hash[Symbol, untyped]) -> String?
    def field_name(dict)
      partial = dereference(dict[:T])
      return nil if partial.nil?
      return PDF::Reader::EncodingUtils.string_to_utf8(partial) if partial.is_a?(String)

      partial.to_s
    end

    #: (Array[Hash[Symbol, untyped]], Symbol) -> untyped
    def nearest(dicts, key)
      dicts.reverse_each do |dict|
        value = dereference(dict[key])
        return value unless value.nil?
      end
      nil
    end

    def structural_key?(key)
      [:Kids, :Parent].include?(key)
    end

    def widget_only_key?(key)
      WIDGET_KEYS.include?(key) && !FIELD_KEYS.include?(key)
    end

    def fieldchain_last(chain)
      chain.last || {}
    end

    #: (untyped) -> Integer
    def identity(value)
      value.is_a?(PDF::Reader::Reference) ? value.hash : value.object_id
    end

    #: (untyped) -> untyped
    def dereference(value)
      @objects.deref(value)
    rescue MalformedPDFError
      nil
    end

    #: (untyped) -> Hash[Symbol, untyped]?
    def dereference_hash(value)
      dict = dereference(value)
      dict.is_a?(::Hash) ? dict : nil
    end

    #: (untyped) -> untyped
    def convert(value)
      convert_value(value, Set.new)
    end

    #: (untyped, Set[Integer]) -> untyped
    def convert_value(value, seen)
      case value
      when ::Hash
        id = value.object_id
        return {} if seen.include?(id)

        seen.add(id)
        value.each_with_object({}) do |(key, item), result|
          result[key] = convert_value(item, seen)
        end
      when Array
        id = value.object_id
        return [] if seen.include?(id)

        seen.add(id)
        value.map { |item| convert_value(item, seen) }
      when String
        PDF::Reader::EncodingUtils.string_to_utf8(value)
      else
        value
      end
    end

    #: (untyped) -> untyped
    def deep_dereference(value)
      @objects.deref!(value)
    rescue MalformedPDFError
      dereference(value)
    end

    #: (Symbol, String, Hash[Symbol, untyped]) -> void
    def diagnostic(code, message, details = {})
      @diagnostics << { code: code, message: message }.merge(details)
    end
  end
end

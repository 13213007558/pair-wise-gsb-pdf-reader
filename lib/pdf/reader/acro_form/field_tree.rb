# coding: utf-8
# typed: false
# frozen_string_literal: true

require 'set'

class PDF::Reader
  class AcroForm
    module FieldTree
      private

      def build_fields
        root_fields.each { |field|
          traverse(field, root_inherited_config.dup, [], nil, Set.new, [])
        }
        collect_orphan_widgets
      end

      def root_fields
        fields = safe_array(@root[:Fields])
        return fields || [] if fields

        diagnostic(:invalid_acroform_fields, "AcroForm /Fields must be an Array", @root[:Fields])
        []
      end

      def traverse(raw, inherited, name_parts, parent_raw, path, chain)
        return if raw.nil?

        key = object_key(raw)
        if key && path.include?(key)
          diagnostic(:kid_cycle, "A field Kids array contains a cycle", raw)
          return
        elsif key && @visited.include?(key)
          diagnostic(:field_repeated, "A field object is reachable more than once", raw)
          return
        end

        dict = safe_hash(raw)
        unless dict
          diagnostic(:invalid_field, "Expected a field dictionary", raw)
          return
        end

        check_parent(dict, raw, parent_raw)
        path.add(key) if key
        @visited.add(key) if key

        local_config = inherited.merge(slice_raw(dict, Objects::FIELD_CONFIG_KEYS))
        current_chain = chain + [raw]
        partial_name = normalize_partial_name(dict[:T], raw)
        full_name_parts = partial_name ? name_parts + [partial_name] : name_parts
        kids = safe_array(dict[:Kids])

        if kids.nil?
          build_field(raw, dict, local_config, full_name_parts, current_chain, [raw])
          return
        end

        named_kids, widget_kids, continuation_kids = partition_kids(kids, raw)
        if widget_kids.any? && named_kids.any?
          diagnostic(:mixed_field_children, "Field mixes widget kids and named field kids", raw)
        end

        if widget_kids.any? || (named_kids.empty? && continuation_kids.empty?)
          build_field(raw, dict, local_config, full_name_parts, current_chain, widget_kids)
        end

        inherited_config = select_inherited_field_config(local_config)
        (named_kids + continuation_kids).each { |kid|
          traverse(kid, inherited_config, full_name_parts, raw, path, current_chain)
        }
      ensure
        path.delete(key) if key
      end

      def check_parent(dict, raw, parent_raw)
        return unless parent_raw

        if dict[:Parent].nil?
          diagnostic(:missing_parent, "Field kid has no /Parent entry", raw)
        elsif object_key(dict[:Parent]) != object_key(parent_raw)
          diagnostic(:parent_mismatch, "Field kid does not point back to its parent field", raw)
        end
      end

      def partition_kids(kids, parent_raw)
        named_kids = []
        widget_kids = []
        continuation_kids = []

        kids.each do |kid|
          kid_dict = safe_hash(kid)
          unless kid_dict
            diagnostic(:invalid_field_kid, "Expected a field or widget dictionary", kid)
            next
          end

          if kid_dict.key?(:T)
            named_kids << kid
          elsif widget_dictionary?(kid_dict, parent_raw)
            check_widget_parent(kid_dict, kid, parent_raw)
            widget_kids << kid
          else
            continuation_kids << kid
          end
        end

        [named_kids, widget_kids, continuation_kids]
      end

      def check_widget_parent(dict, raw, parent_raw)
        if dict[:Parent].nil?
          diagnostic(:missing_parent, "Widget kid has no /Parent entry", raw)
        elsif object_key(dict[:Parent]) != object_key(parent_raw)
          diagnostic(:parent_mismatch, "Widget kid does not point back to its field parent", raw)
        end
      end

      def widget_dictionary?(dict, parent_raw)
        dict[:Subtype] == :Widget ||
          (!dict[:Parent].nil? && object_key(dict[:Parent]) == object_key(parent_raw))
      end
    end
  end
end

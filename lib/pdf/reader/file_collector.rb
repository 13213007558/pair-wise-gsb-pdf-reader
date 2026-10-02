# coding: utf-8
# typed: strict
# frozen_string_literal: true

class PDF::Reader
  # Collects every way an embedded file can be reached in a PDF:
  #
  # * the catalog /Names /EmbeddedFiles name tree
  # * the document catalog's /AF (associated files) array
  # * each page dictionary's /AF array
  # * file attachment (/FileAttachment) annotations
  # * form XObject /AF arrays reachable from page resources
  #
  # Results are returned as FileAssociation objects. The walk is deliberately
  # tolerant of malformed sections (e.g. a broken name tree) - everything that
  # can still be resolved is reported.
  #
  class FileCollector
    #: (PDF::Reader::ObjectHash) -> void
    def initialize(objects)
      @objects = objects
    end

    # all embedded file associations in the document, in a deterministic order:
    # name tree entries first (in tree order), then document associations, then
    # page associations in page order.
    #
    #: () -> Array[PDF::Reader::FileAssociation]
    def files
      associations = []
      associations.concat(name_tree_files)
      associations.concat(af_files(catalog, FileAssociation::DOCUMENT, nil, nil))

      page_refs.each_with_index do |page_ref, index|
        page_number = index + 1
        page_dict = @objects.deref_hash(page_ref) || {}

        associations.concat(af_files(page_dict, FileAssociation::PAGE, page_number, page_ref))
        associations.concat(annotation_files(page_dict, page_number))
        associations.concat(xobject_files(page_dict, page_number))
      end

      associations
    end

    # all associations attached (directly or through annotations/xobjects) to a
    # single page. +page_number+ is 1-indexed.
    #
    #: (Integer) -> Array[PDF::Reader::FileAssociation]
    def files_for_page(page_number)
      files.select { |association| association.page_number == page_number }
    end

    # Read embedded content by the identity the caller already holds - a
    # FileAssociation, FileSpec, EmbeddedFile, a Reference to one of those,
    # or a decoded Stream. Never follows external paths and never raises for
    # content problems (see EmbeddedFileReadResult).
    #
    #: (untyped) -> PDF::Reader::EmbeddedFileReadResult
    def read(identity)
      case identity
      when FileAssociation then identity.read
      when FileSpec       then identity.read
      when EmbeddedFile   then identity.read
      when PDF::Reader::Reference
        resolved = @objects.deref(identity)
        case resolved
        when Hash  then FileSpec.new(@objects, identity).read
        when PDF::Reader::Stream then EmbeddedFile.new(@objects, identity).read
        else
          missing_result
        end
      when PDF::Reader::Stream
        EmbeddedFile.new(@objects, identity).read
      else
        missing_result
      end
    end

    private

    #: () -> Hash[Symbol, untyped]
    def catalog
      @catalog ||= safe_hash(@objects.trailer[:Root])
    end

    #: () -> Array[untyped]
    def page_refs
      @objects.page_references
    rescue MalformedPDFError
      []
    end

    #: () -> Array[PDF::Reader::FileAssociation]
    def name_tree_files
      names_dict = safe_hash(catalog[:Names])
      root = names_dict[:EmbeddedFiles]
      return [] if root.nil?

      associations = []
      NameTree.new(@objects, root).each do |name, value|
        spec = wrap_spec(value)
        next if spec.nil?

        associations << FileAssociation.new(
          :scope     => FileAssociation::NAME_TREE,
          :name      => name,
          :filespec  => spec
        )
      end
      associations
    end

    #: (Hash[Symbol, untyped], Symbol, Integer?, PDF::Reader::Reference?)
    #    -> Array[PDF::Reader::FileAssociation]
    def af_files(dict, scope, page_number, container_reference)
      return [] if dict[:AF].nil?
      raw = @objects.deref(dict[:AF])
      array = raw.is_a?(::Array) ? raw : [raw]

      array.each_with_object([]) { |value, associations|
        spec = wrap_spec(value)
        next if spec.nil?

        associations << FileAssociation.new(
          :scope              => scope,
          :filespec           => spec,
          :page_number        => page_number,
          :container_reference => container_reference
        )
      }
    end

    #: (Hash[Symbol, untyped], Integer) -> Array[PDF::Reader::FileAssociation]
    def annotation_files(page_dict, page_number)
      return [] if page_dict[:Annots].nil?
      raw_annots = @objects.deref(page_dict[:Annots])
      annots = raw_annots.is_a?(::Array) ? raw_annots : [raw_annots]
      annots.each_with_object([]) { |annot_ref, associations|
        annot = safe_hash(annot_ref)
        next if annot.nil? || annot[:Subtype] != :FileAttachment

        spec = wrap_spec(annot[:FS])
        next if spec.nil?

        ref = annot_ref.is_a?(PDF::Reader::Reference) ? annot_ref : nil
        associations << FileAssociation.new(
          :scope              => FileAssociation::ANNOTATION,
          :filespec           => spec,
          :page_number        => page_number,
          :container_reference => ref,
          :details            => { :subtype => :FileAttachment, :contents => annot[:Contents] }
        )
      }
    end

    #: (Hash[Symbol, untyped], Integer) -> Array[PDF::Reader::FileAssociation]
    def xobject_files(page_dict, page_number)
      resources = page_resources(page_dict)
      xobjects = safe_hash(resources[:XObject])
      seen = {} #: Hash[Integer, bool]

      associations = []
      xobjects.each do |label, xobj_ref|
        walk_xobject(xobj_ref, label, page_number, seen, associations)
      end
      associations
    end

    #: (untyped, Symbol, Integer, Hash[Integer, bool], Array[untyped]) -> void
    def walk_xobject(xobj_ref, label, page_number, seen, associations)
      resolved = @objects.deref(xobj_ref)
      stream = resolved.is_a?(PDF::Reader::Stream) ? resolved : nil
      return if stream.nil? || stream.hash[:Subtype] != :Form

      xobj_dict = stream.hash
      id = xobj_ref.is_a?(PDF::Reader::Reference) ? xobj_ref.id : xobj_dict.object_id
      return if seen[id]
      seen[id] = true

      ref = xobj_ref.is_a?(PDF::Reader::Reference) ? xobj_ref : nil
      safe_array(xobj_dict[:AF]).each do |value|
        spec = wrap_spec(value)
        next if spec.nil?

        associations << FileAssociation.new(
          :scope              => FileAssociation::XOBJECT,
          :filespec           => spec,
          :page_number        => page_number,
          :container_reference => ref,
          :details            => { :label => label }
        )
      end

      nested = safe_hash(xobj_dict[:Resources])
      nested_xobjects = safe_hash(nested[:XObject])
      nested_xobjects.each do |nested_label, nested_ref|
        walk_xobject(nested_ref, nested_label, page_number, seen, associations)
      end
    end

    # Merge the page's own /Resources with any inherited from parent /Pages nodes
    #
    #: (Hash[Symbol, untyped]) -> Hash[Symbol, untyped]
    def page_resources(page_dict)
      ancestors = []
      parent = page_dict[:Parent]
      seen = {} #: Hash[Integer, bool]
      while parent.is_a?(PDF::Reader::Reference) || parent.is_a?(::Hash)
        key = parent.is_a?(PDF::Reader::Reference) ? parent.id : parent.object_id
        break if seen[key]
        seen[key] = true
        dict = @objects.deref_hash(parent) || {}
        ancestors << dict
        parent = dict[:Parent]
      end

      merged = {}
      ancestors.reverse.each { |dict| merged.merge!(safe_hash(dict[:Resources])) }
      merged.merge!(safe_hash(page_dict[:Resources]))
      merged
    end

    # dereference a dictionary that may already be dereferenced; malformed
    # (non-dictionary) values are treated as absent
    #
    #: (untyped) -> Hash[Symbol, untyped]
    def safe_hash(value)
      resolved = @objects.deref(value)
      resolved.is_a?(::Hash) ? resolved : {}
    end

    #: (untyped) -> Array[untyped]
    def safe_array(value)
      resolved = @objects.deref(value)
      resolved.is_a?(::Array) ? resolved : []
    end

    #: (untyped) -> PDF::Reader::FileSpec?
    def wrap_spec(value)
      resolved = value.is_a?(PDF::Reader::Reference) ? @objects.deref(value) : value
      return nil unless resolved.is_a?(::Hash)

      spec = FileSpec.new(@objects, value.is_a?(PDF::Reader::Reference) ? value : resolved)
      spec.filespec? ? spec : nil
    end

    #: () -> PDF::Reader::EmbeddedFileReadResult
    def missing_result
      EmbeddedFileReadResult.new(
        :missing, nil, nil, "No embedded file stream for the supplied identity"
      )
    end
  end
end

# coding: utf-8
# typed: strict
# frozen_string_literal: true

class PDF::Reader
  # Collects the embedded file (attachment) references of a PDF into a
  # single, unified list.
  #
  # References are gathered from every place the PDF spec allows them:
  #
  #   - the EmbeddedFiles name tree in the document catalog
  #   - the /AF (associated files) array of the catalog
  #   - the /AF array of each page
  #   - the /AF array of any other object
  #
  # As a safety net, every Filespec dictionary in the file is also found
  # by scanning all objects, so references remain listed (with origin
  # :object_scan) even when the name tree is corrupted.
  #
  # Duplicate names are kept as separate entries - callers select the
  # entry they want and read its content by identity, never by assuming
  # names are unique.
  #
  class EmbeddedFiles
    include Enumerable

    #: (PDF::Reader::ObjectHash) -> void
    def initialize(objects)
      @objects = objects #: PDF::Reader::ObjectHash
      @entries = nil #: Array[PDF::Reader::EmbeddedFile]?
      @entries_seen = {} #: Hash[untyped, bool]
      @filespecs_seen = {} #: Hash[untyped, bool]
    end

    #: () { (PDF::Reader::EmbeddedFile) -> untyped } -> untyped
    def each(&block)
      entries.each(&block)
    end

    # all embedded file references found in the document
    #: () -> Array[PDF::Reader::EmbeddedFile]
    def entries
      @entries ||= collect
    end

    private

    #: () -> Array[PDF::Reader::EmbeddedFile]
    def collect
      collected = []
      collected.concat(from_name_tree)
      collected.concat(from_af_arrays)
      collected.concat(from_object_scan)
      collected
    end

    # register a reference unless an identical one (same filespec, name,
    # scope and origin) was already collected. Filespecs already reachable
    # via the name tree or an AF array are not listed again by the object
    # scan safety net.
    #: (untyped, Hash[Symbol, untyped]) -> Array[PDF::Reader::EmbeddedFile]
    def register(filespec_obj, attrs)
      filespec = filespec_obj.is_a?(Hash) ? filespec_obj : @objects.deref_hash(filespec_obj)
      return [] unless filespec.is_a?(Hash)
      return [] unless filespec[:Type] == :Filespec || filespec.key?(:EF) || filespec.key?(:F) || filespec.key?(:UF)

      ref = filespec_obj.is_a?(PDF::Reader::Reference) ? filespec_obj : nil
      identity = ref || filespec.object_id
      return [] if attrs[:origin] == :object_scan && @filespecs_seen[identity]

      key = [identity, attrs[:name], attrs[:scope], attrs[:origin], attrs[:page]]
      return [] if @entries_seen[key]

      name = attrs[:name] || utf8(filespec[:UF]) || utf8(filespec[:F])
      return [] unless name

      @entries_seen[key] = true
      @filespecs_seen[identity] = true
      [PDF::Reader::EmbeddedFile.new(@objects, filespec, ref, attrs.merge(:name => name))]
    rescue PDF::Reader::MalformedPDFError
      []
    end

    ##########################################################################
    # EmbeddedFiles name tree in the document catalog
    ##########################################################################

    #: () -> Array[PDF::Reader::EmbeddedFile]
    def from_name_tree
      root = catalog
      names = root ? @objects.deref_hash(root[:Names]) : nil
      tree = names ? @objects.deref_hash(names[:EmbeddedFiles]) : nil
      return [] unless tree

      walk_name_tree(tree).flat_map do |tree_name, filespec_obj|
        register(filespec_obj,
                 :name => tree_name, :scope => :document, :origin => :name_tree)
      end
    rescue PDF::Reader::MalformedPDFError
      []
    end

    # walk a name tree node, returning [name, value] pairs. Tolerates
    # corrupted nodes (odd /Names arrays, dangling /Kids) by skipping the
    # broken parts instead of raising.
    #: (Hash[Symbol, untyped], ?Integer) -> Array[[String, untyped]]
    def walk_name_tree(node, depth = 0)
      return [] if depth > 20

      pairs = [] #: Array[[String, untyped]]
      names = node[:Names]
      if names.is_a?(Array)
        names.each_slice(2) do |key, value|
          name = utf8(key)
          pairs << [name, value] if name && !value.nil?
        end
      end
      kids = node[:Kids]
      if kids.is_a?(Array)
        kids.each do |kid|
          kid_node = @objects.deref_hash(kid)
          pairs.concat(walk_name_tree(kid_node, depth + 1)) if kid_node
        end
      end
      pairs
    end

    ##########################################################################
    # /AF arrays on the catalog, pages and any other object
    ##########################################################################

    #: () -> Array[PDF::Reader::EmbeddedFile]
    def from_af_arrays
      collected = [] #: Array[PDF::Reader::EmbeddedFile]
      page_numbers = page_object_ids
      root_ref = @objects.trailer[:Root]

      @objects.each do |ref, obj|
        obj = obj.hash if obj.is_a?(PDF::Reader::Stream)
        next unless obj.is_a?(Hash)

        af = @objects.deref_array(obj[:AF])
        next if af.nil? || af.empty?

        scope, page =
          if ref == root_ref
            [:document, nil]
          elsif page_numbers.has_key?(ref.id)
            [:page, page_numbers[ref.id]]
          else
            [:object, nil]
          end

        af.each do |filespec_obj|
          collected.concat(
            register(filespec_obj, :scope => scope, :page => page, :origin => :af)
          )
        end
      end
      collected
    end

    ##########################################################################
    # safety net: every Filespec dictionary in the file, so corrupted name
    # trees cannot hide attachments from the listing
    ##########################################################################

    #: () -> Array[PDF::Reader::EmbeddedFile]
    def from_object_scan
      collected = [] #: Array[PDF::Reader::EmbeddedFile]
      @objects.each do |ref, obj|
        next unless obj.is_a?(Hash) && obj[:Type] == :Filespec

        collected.concat(
          register(ref, :scope => :unknown, :origin => :object_scan)
        )
      end
      collected
    end

    ##########################################################################

    #: () -> Hash[Symbol, untyped]?
    def catalog
      @objects.deref_hash(@objects.trailer[:Root])
    end

    # maps page object ids to 1-based page numbers
    #: () -> Hash[Integer, Integer]
    def page_object_ids
      ids = {} #: Hash[Integer, Integer]
      @objects.page_references.each_with_index do |page_ref, idx|
        ids[page_ref.id] = idx + 1 if page_ref.is_a?(PDF::Reader::Reference)
      end
      ids
    rescue PDF::Reader::MalformedPDFError
      {}
    end

    #: (untyped) -> String?
    def utf8(str)
      return nil unless str.is_a?(String)

      PDF::Reader::EncodingUtils.string_to_utf8(str)
    end
  end
end

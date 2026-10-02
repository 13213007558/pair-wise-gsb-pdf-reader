# coding: utf-8
# typed: strict
# frozen_string_literal: true

class PDF::Reader
  # Utility class for walking a PDF name tree (see section 7.9.6 of the PDF 1.7 spec).
  #
  # A name tree is similar to a dictionary, but allows arbitrarily long keys and keeps
  # them sorted. The structure may also be split over many intermediate nodes to avoid
  # one object growing too large.
  #
  # Unlike a strict parser, this walker is tolerant of broken nodes - malformed kids,
  # cycles or bad leaf pairs don't prevent the rest of the tree from being enumerated.
  #
  class NameTree
    include Enumerable

    #: (PDF::Reader::ObjectHash, untyped) -> void
    def initialize(objects, root)
      @objects = objects
      @root = root
    end

    # Yield each [name, value] pair in the tree. +name+ is converted to a UTF-8 Ruby
    # string. +value+ is the raw object found in the tree (usually an indirect
    # reference), dereferencing is left to the caller so object identity is preserved.
    #
    #: () { (String, untyped) -> void } -> Enumerator[String, untyped]
    def each(&block)
      return enum_for(:each) unless block_given?

      walk(@root, {}, &block)
      self
    end

    private

    #: (untyped, Hash[untyped, bool]) { (String, untyped) -> void } -> void
    def walk(node, seen, &block)
      # references are keyed by their PDF object id (with a marker so they can
      # never collide with a Ruby object_id used for non-reference nodes)
      key = node.is_a?(PDF::Reader::Reference) ? [-1, node.id, node.gen] : node.object_id
      return if seen[key]
      seen[key] = true

      dict = safe_hash(node)

      if dict.nil?
        # some writers inline the leaf array directly as the root
        names = @objects.deref(node)
        walk_array(names, seen, &block) if names.is_a?(::Array)
      elsif dict.has_key?(:Kids)
        kids = safe_array(dict[:Kids])
        kids.each do |kid|
          begin
            walk(kid, seen, &block)
          rescue MalformedPDFError
            # a broken kid never prevents its siblings from being walked
            nil
          end
        end
      elsif dict.has_key?(:Names)
        walk_array(@objects.deref(dict[:Names]), seen, &block)
      end
    end

    #: (untyped, Hash[untyped, bool]) { (String, untyped) -> void } -> void
    def walk_array(array, seen, &block)
      begin
        return unless array.is_a?(::Array)
        pairs = array

        index = 0
        while index + 1 < pairs.length
          name = EncodingUtils.string_to_utf8(pairs[index].to_s)
          block.call(name, pairs[index + 1])
          index += 2
        end
      rescue MalformedPDFError
        nil
      end
    end

    #: (untyped) -> Hash[Symbol, untyped]?
    def safe_hash(value)
      resolved = @objects.deref(value)
      resolved.is_a?(::Hash) ? resolved : nil
    end

    #: (untyped) -> Array[untyped]
    def safe_array(value)
      resolved = @objects.deref(value)
      resolved.is_a?(::Array) ? resolved : []
    end
  end
end

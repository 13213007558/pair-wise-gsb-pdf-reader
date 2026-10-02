# coding: utf-8
# typed: strict
# frozen_string_literal: true

################################################################################
#
# Copyright (C) 2006 Peter J Jones (pjones@pmade.com)
#
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the
# "Software"), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to
# the following conditions:
#
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
# LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
# OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
# WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
#
################################################################################

class PDF::Reader
  class XRef
    # Represents the cross-reference table and trailer that were effective at
    # one point in an incrementally updated PDF file.
    class Revision
      FREE_ENTRY = :free

      #: Integer
      attr_reader :number

      #: Integer
      attr_reader :offset

      #: Hash[Integer, Hash[Integer, Integer | PDF::Reader::Reference | Symbol]]
      attr_reader :entries

      #: Hash[Symbol, untyped]
      attr_reader :trailer

      #: (Integer, Integer, Hash[Integer, Hash[Integer, Integer | PDF::Reader::Reference | Symbol]], Hash[Symbol, untyped]) -> void
      def initialize(number, offset, entries, trailer)
        @number = number
        @offset = offset
        @entries = entries
        @trailer = trailer
      end

      #: (PDF::Reader::Reference) -> (Integer | PDF::Reader::Reference)
      def [](ref)
        location = entries.fetch(ref.id, {}).fetch(ref.gen) do
          raise InvalidObjectError, "Object #{ref.id}, Generation #{ref.gen} is invalid"
        end

        if location == FREE_ENTRY
          raise InvalidObjectError, "Object #{ref.id}, Generation #{ref.gen} is free"
        end

        location
      end

      #: (Integer) -> Integer?
      def generation_for(id)
        generations = entries[id]
        return nil if generations.nil?

        generations.keys.reject { |gen| generations[gen] == FREE_ENTRY }.max
      end

      #: (Integer | PDF::Reader::Reference) -> bool
      def free?(ref)
        ref = PDF::Reader::Reference.new(ref.to_i, 0) unless ref.is_a?(PDF::Reader::Reference)
        entries.fetch(ref.id, {}).values.include?(FREE_ENTRY)
      end

      #: () -> Integer
      def size
        entries.count { |id, generations| id != 0 && !generations.values.include?(FREE_ENTRY) }
      end

      #: () { (PDF::Reader::Reference) -> untyped } -> void
      def each(&block)
        entries.keys.sort.each do |id|
          next if id == 0

          gen = generation_for(id)
          yield PDF::Reader::Reference.new(id, gen) unless gen.nil?
        end
      end
      include Enumerable
    end
  end

  ################################################################################
  # An internal PDF::Reader class that represents the XRef table in a PDF file as a
  # hash-like object.
  #
  # An Xref table is a map of object identifiers and byte offsets. Any time a particular
  # object needs to be found, the Xref table is used to find where it is stored in the
  # file.
  #
  # Hash keys are object ids, values are either:
  #
  # * a byte offset where the object starts (regular PDF objects)
  # * a PDF::Reader::Reference instance that points to a stream that contains the
  #   desired object (PDF objects embedded in an object stream)
  #
  # The class behaves much like a standard Ruby hash, including the use of
  # the Enumerable mixin. The key difference is no []= method - the hash
  # is read only.
  #
  #: [Elem]
  class XRef
    include Enumerable

    FREE_ENTRY = Revision::FREE_ENTRY

    #: Hash[Symbol, untyped]
    attr_reader :trailer

    #: Array[PDF::Reader::XRef::Revision]
    attr_reader :revisions

    ################################################################################
    # create a new Xref table based on the contents of the supplied io object
    #
    # io - must be an IO object, generally either a file or a StringIO
    #
    #: (IO | Tempfile | StringIO) -> void
    def initialize(io)
      @io = io
      @junk_offset = calc_junk_offset(io) || 0 #: Integer
      @xref = {} #: Hash[Integer, Hash[Integer, Integer | PDF::Reader::Reference | Symbol]]
      @revisions = [] #: Array[Revision]
      @trailer = load_revisions #: Hash[Symbol, untyped]
    end

    #: (Integer) -> Revision
    def revision(index)
      index += revisions.size if index < 0

      unless index >= 0 && index < revisions.size
        raise RangeError, "revision #{index} is outside 0..#{revisions.size - 1}"
      end

      revisions[index]
    end

    ################################################################################
    # return the number of objects in this file. Objects with multiple generations are
    # only counter once.
    #
    #: () -> untyped
    def size
      @xref.size
    end
    ################################################################################
    # returns the byte offset for the specified PDF object.
    #
    # ref - a PDF::Reader::Reference object containing an object ID and revision number
    #: (untyped) -> untyped
    def [](ref)
      revisions.last[ref]
    end

    #: (Integer) -> Integer?
    def generation_for(id)
      revisions.last.generation_for(id)
    end

    #: (Integer | PDF::Reader::Reference) -> bool
    def free?(ref)
      revisions.last.free?(ref)
    end
    ################################################################################
    # iterate over each object in the xref table
    #
    # @override(allow_incompatible: true)
    #: () { (PDF::Reader::Reference) -> untyped } -> void
    def each(&block)
      revisions.last.each(&block)
    end

    ################################################################################
    private
    ################################################################################
    #: () -> Hash[Symbol, untyped]
    def load_revisions
      sections = []
      visited = {}
      load_section(nil, true, sections, visited)

      entries = {}
      compatible_entries = {}
      trailer = {}

      sections.each_with_index do |section, index|
        entries = merge_entries(entries, section[:entries])
        compatible_entries = merge_compatible_entries(compatible_entries, section[:entries])
        trailer = merge_trailer(trailer, section[:trailer], section[:entries])
        @revisions << Revision.new(index + 1, section[:offset], entries, trailer)
      end

      @xref = compatible_entries.reject { |id, _generations| id == 0 }
      trailer
    end

    #: (Integer?, bool, Array[Hash[Symbol, untyped]], Hash[Integer, bool]) -> [Hash[Integer, Hash[Integer, Integer | PDF::Reader::Reference | Symbol]], Hash[Symbol, untyped]]
    def load_section(offset, include_junk_offset, sections, visited)
      offset ||= new_buffer.find_first_xref_offset
      offset += @junk_offset if include_junk_offset

      if visited.key?(offset)
        raise MalformedPDFError, "invalid xref chain: cycle detected at offset #{offset}"
      end
      visited[offset] = true

      entries, trailer = parse_section(offset)

      if trailer.has_key?(:XRefStm)
        xrefstm_offset = trailer[:XRefStm].to_i
        begin
          xrefstm_entries, xrefstm_trailer = parse_section(xrefstm_offset)
        rescue MalformedPDFError => error
          raise MalformedPDFError,
            "invalid /XRefStm reference at xref offset #{offset}: #{error.message}"
        end
        entries = merge_entries(xrefstm_entries, entries)
        trailer = xrefstm_trailer.dup.merge(trailer).tap { |dict| dict.delete(:XRefStm) }
      end

      if trailer.has_key?(:Prev) && trailer[:Prev].to_i != 0
        begin
          load_section(trailer[:Prev].to_i, false, sections, visited)
        rescue MalformedPDFError => error
          raise MalformedPDFError,
            "invalid /Prev chain at xref offset #{offset}: #{error.message}"
        end
      end

      sections << {
        :offset => offset,
        :entries => entries,
        :trailer => trailer.dup.tap { |dict|
          dict.delete(:Prev)
        }
      }

      [entries, trailer]
    end

    #: (Integer, Hash[Integer, bool]?) -> [Hash[Integer, Hash[Integer, Integer | PDF::Reader::Reference | Symbol]], Hash[Symbol, untyped]]
    def parse_section(offset, visited = nil)
      if visited && visited.key?(offset)
        raise MalformedPDFError, "invalid xref chain: cycle detected at offset #{offset}"
      end
      visited[offset] = true unless visited.nil?

      buf = new_buffer(offset)
      tok_one = buf.token

      if tok_one == "xref" || tok_one == "ref"
        entries = {}
        trailer = load_xref_table(buf, entries)
        return [entries, trailer]
      else
        tok_two   = buf.token
        tok_three = buf.token

        if tok_one.to_i >= 0 && tok_two.to_i >= 0 && tok_three == "obj"
          buf = new_buffer(offset)
          stream = PDF::Reader::Parser.new(buf).object(tok_one.to_i, tok_two.to_i)
          if stream.is_a?(PDF::Reader::Stream)
            entries = {}
            trailer = load_xref_stream(stream, entries)
            return [entries, trailer]
          end
        end

        raise PDF::Reader::MalformedPDFError,
          "xref table not found at offset #{offset} (#{tok_one} != xref)"
      end
    end

    #: (Hash[Integer, Hash[Integer, Integer | PDF::Reader::Reference | Symbol]], Hash[Integer, Hash[Integer, Integer | PDF::Reader::Reference | Symbol]]) -> Hash[Integer, Hash[Integer, Integer | PDF::Reader::Reference | Symbol]]
    def merge_entries(old_entries, new_entries)
      merged = old_entries.each_with_object({}) do |(id, generations), result|
        result[id] = generations.dup
      end

      new_entries.each do |id, generations|
        if generations.values.include?(FREE_ENTRY)
          free_generations = generations.select { |_generation, location| location == FREE_ENTRY }
          merged[id] = free_generations
          next
        end

        merged[id] ||= {}
        generations.each do |gen, location|
          if location == FREE_ENTRY
            merged[id].delete(gen)
          else
            merged[id][gen] = location
          end
        end
        merged.delete(id) if merged[id].empty?
      end

      merged
    end

    # Older releases exposed the union of all in-use entries from the Prev chain
    # in this raw, internal hash. Revision instances enforce current free entries.
    def merge_compatible_entries(old_entries, new_entries)
      merged = old_entries.each_with_object({}) do |(id, generations), result|
        result[id] = generations.dup
      end

      new_entries.each do |id, generations|
        next if id == 0

        merged[id] ||= {}
        generations.each do |gen, location|
          merged[id][gen] = location unless location == FREE_ENTRY
        end
        merged.delete(id) if merged[id].empty?
      end

      merged
    end

    #: (Hash[Symbol, untyped], Hash[Symbol, untyped], Hash[Integer, Hash[Integer, Integer | PDF::Reader::Reference | Symbol]]) -> Hash[Symbol, untyped]
    def merge_trailer(old_trailer, new_trailer, new_entries)
      merged = old_trailer.dup
      merged.each_key do |key|
        next if new_trailer.key?(key)
        value = merged[key]
        generations = value.is_a?(PDF::Reader::Reference) ? new_entries[value.id] : nil
        if value.is_a?(PDF::Reader::Reference) &&
          (generations.nil? || !generations.key?(value.gen))
          merged.delete(key)
        end
      end
      merged.merge(new_trailer)
    end
    ################################################################################
    # Assumes the underlying buffer is positioned at the start of a traditional
    # Xref table and processes it into memory.
    #
    #: (PDF::Reader::Buffer, Hash[Integer, Hash[Integer, Integer | PDF::Reader::Reference | Symbol]]) -> Hash[Symbol, untyped]
    def load_xref_table(buf, entries)
      params = []

      while !params.include?("trailer") && !params.include?(nil)
        if params.size == 2
          unless params[0].to_s.match(/\A\d+\z/)
            raise MalformedPDFError, "invalid xref table, expected object ID"
          end

          objid, count = params[0].to_i, params[1].to_i
          count.times do |entry_index|
            offset = buf.token.to_i
            generation = buf.token.to_i
            state = buf.token

            # Some PDF writers start numbering at 1 instead of 0. Fix up the number.
            # Only apply this on the first entry of the section - if entry_index > 0,
            # objid has been incremented from 0 and object 1 is a legitimate free entry.
            if entry_index == 0 and objid == 1 and offset == 0 and generation == 65535 and state == 'f'
              objid = 0
            end
            if state == "n" && offset > 0
              store(entries, objid, generation, offset + @junk_offset)
            elsif state == "f"
              store(entries, objid, generation, FREE_ENTRY)
            end
            objid += 1
            params.clear
          end
        end
        params << buf.token
      end

      trailer = Parser.new(buf).parse_token

      unless trailer.kind_of?(Hash)
        raise MalformedPDFError, "PDF malformed, trailer should be a dictionary"
      end

      trailer
    end

    ################################################################################
    # Read an XRef stream from the underlying buffer instead of a traditional xref table.
    #
    #: (PDF::Reader::Stream, Hash[Integer, Hash[Integer, Integer | PDF::Reader::Reference | Symbol]]) -> Hash[Symbol, untyped]
    def load_xref_stream(stream, entries = {})
      unless stream.hash[:Type] == :XRef
        raise PDF::Reader::MalformedPDFError, "xref stream not found when expected"
      end
      trailer = stream.hash.reject { |key, _value|
        [:Type, :W, :Index, :Length, :Filter, :DecodeParms].include?(key)
      }

      widths = stream.hash[:W]

      PDF::Reader::Error.validate_type_as_malformed(widths, "xref stream widths", Array)

      entry_length = widths.inject(0) { |s, w|
        unless w.is_a?(Integer)
          w = 0
        end
        s + w
      }
      raw_data     = StringIO.new(stream.unfiltered_data)
      if stream.hash[:Index]
        index = stream.hash[:Index]
      else
        index = [0, stream.hash[:Size]]
      end
      index.each_slice(2) do |start_id, size|
        obj_ids = (start_id..(start_id+(size-1)))
        obj_ids.each do |objid|
          entry = raw_data.read(entry_length) || ""
          f1    = unpack_bytes(entry[0,widths[0]])
          f2    = unpack_bytes(entry[widths[0],widths[1]])
          f3    = unpack_bytes(entry[widths[0]+widths[1],widths[2]])
          if f1 == 0
            store(entries, objid, f3, FREE_ENTRY)
          elsif f1 == 1 && f2 > 0
            store(entries, objid, f3, f2 + @junk_offset)
          elsif f1 == 2 && f2 > 0
            store(entries, objid, 0, PDF::Reader::Reference.new(f2, 0))
          end
        end
      end

      trailer
    end
    ################################################################################
    # XRef streams pack info into integers 1-N bytes wide. Depending on the number of
    # bytes they need to be converted to an int in different ways.
    #
    #: (String?) -> Integer
    def unpack_bytes(bytes)
      res = if bytes.nil? || bytes == ""
        0
      elsif bytes.size == 1
        bytes.unpack("C")[0]
      elsif bytes.size == 2
        bytes.unpack("n")[0]
      elsif bytes.size == 3
        ("\x00" + bytes).unpack("N")[0]
      elsif bytes.size == 4
        bytes.unpack("N")[0]
      elsif bytes.size == 8
        bytes.unpack("Q>")[0]
      else
        raise UnsupportedFeatureError, "Unable to unpack xref stream entries of #{bytes.size} bytes"
      end
      TypeCheck.cast_to_int!(res)
    end
    ################################################################################
    # Wrap the io stream we're working with in a buffer that can tokenise it for us.
    #
    # We create multiple buffers so we can be tokenising multiple sections of the file
    # at the same time without worrying about clearing the buffers contents.
    #
    #: (?Integer) -> PDF::Reader::Buffer
    def new_buffer(offset = 0)
      PDF::Reader::Buffer.new(@io, :seek => offset)
    end
    ################################################################################
    # Stores an offset value for a particular PDF object ID and revision number
    #
    #: (Integer, Integer, Integer | PDF::Reader::Reference) -> (Integer | PDF::Reader::Reference)
    def store(entries, id, gen, offset)
      (entries[id] ||= {})[gen] ||= offset
    end

    #: (PDF::Reader::Stream, Hash[Integer, Hash[Integer, Integer | PDF::Reader::Reference | Symbol]]?=nil) -> Hash[Symbol, untyped]
    ################################################################################
    # Returns the offset of the PDF document in the +stream+. In theory this
    # should always be 0, but all sort of crazy junk is prefixed to PDF files
    # in the real world.
    #
    # Checks up to 1024 chars into the file,
    # returns nil if no PDF data detected.
    # Adobe PDF 1.4 spec (3.4.1) 12. Acrobat viewers require only that the
    # header appear somewhere within the first 1024 bytes of the file
    #
    #: (IO | Tempfile | StringIO) -> Integer?
    def calc_junk_offset(io)
      io.rewind
      offset = io.pos
      until (c = io.readchar) == '%' || c == 37 || offset > 1024
        offset += 1
      end
      io.rewind
      offset < 1024 ? offset : nil
    rescue EOFError
      nil
    end
  end
  ################################################################################
end
################################################################################

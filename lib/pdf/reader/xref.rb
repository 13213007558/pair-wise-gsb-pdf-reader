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

    #: Hash[Symbol, untyped]
    attr_reader :trailer

    # The number of revisions (xref sections) found while walking the /Prev
    # chain from the most recent xref section to the oldest.
    #
    #: Integer
    attr_reader :revision_count

    # The revision this XRef is pinned to. 0 is the oldest revision,
    # revision_count - 1 is the most recent.
    #
    #: Integer
    attr_reader :revision

    ################################################################################
    # create a new Xref table based on the contents of the supplied io object
    #
    # io - must be an IO object, generally either a file or a StringIO
    # revision - pin this table to a particular revision of the document. 0 is
    #            the oldest revision, -1 (the default) is the most recent.
    #
    #: (IO | Tempfile | StringIO, ?Integer?) -> void
    def initialize(io, revision = nil)
      @io = io
      @junk_offset = calc_junk_offset(io) || 0 #: Integer
      @sections = [] #: Array[Hash[Symbol, untyped]]
      load_offsets
      @revision_count = @sections.size #: Integer
      @revision = normalize_revision(revision) #: Integer
      @xref = merge_sections(@revision) #: Hash[Integer, Hash[Integer, untyped]]
      @trailer = @sections.fetch(section_index(@revision))[:trailer] #: Hash[Symbol, untyped]
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
      @xref.fetch(ref.id, {}).fetch(ref.gen)
    rescue
      raise InvalidObjectError, "Object #{ref.id}, Generation #{ref.gen} is invalid"
    end
    ################################################################################
    # iterate over each object in the xref table
    #
    # @override(allow_incompatible: true)
    #: () { (PDF::Reader::Reference) -> untyped } -> void
    def each(&block)
      ids = @xref.keys.sort
      ids.each do |id|
        gen = @xref.fetch(id, {}).keys.sort[-1]
        yield PDF::Reader::Reference.new(id, gen.to_i)
      end
    end
    ################################################################################
    private
    ################################################################################
    # Convert a user supplied revision number to a 0-based index where 0 is the
    # oldest revision. Negative values count back from the most recent revision.
    #
    #: (Integer?) -> Integer
    def normalize_revision(revision)
      return @revision_count - 1 if revision.nil?

      rev = Integer(revision)
      rev += @revision_count if rev < 0
      unless rev >= 0 && rev < @revision_count
        raise ArgumentError,
          "revision #{revision} is out of range, this file has #{@revision_count} revision(s)"
      end
      rev
    end
    ################################################################################
    # Sections are stored newest first, so convert a 0-based oldest-first revision
    # number into an index into @sections.
    #
    #: (Integer) -> Integer
    def section_index(revision)
      @revision_count - 1 - revision
    end
    ################################################################################
    # Merge the xref sections that were valid at the requested revision into a
    # single offset map. Newer sections win over older ones, and free entries in
    # newer sections mask in-use entries from older sections so deleted objects
    # stay deleted.
    #
    #: (Integer) -> Hash[Integer, Hash[Integer, Integer | PDF::Reader::Reference]]
    def merge_sections(revision)
      merged = {} #: Hash[Integer, Hash[Integer, Integer | PDF::Reader::Reference]]
      freed  = {} #: Hash[Integer, Integer]

      @sections[section_index(revision)..-1].each do |section|
        section[:entries].each do |id, gens|
          gens.each do |gen, value|
            if value == :free
              # tombstone: masks in-use entries with lower generations from
              # older sections, even if a newer section redefines this gen
              freed[id] = gen if gen > (freed[id] || -1)
            elsif merged.fetch(id, {}).has_key?(gen)
              next
            elsif freed[id] && gen < freed[id]
              next
            else
              (merged[id] ||= {})[gen] = value
            end
          end
        end
      end
      merged
    end
    ################################################################################
    # Read a xref table from the underlying buffer.
    #
    # If offset is specified the table will be loaded from there, otherwise the
    # default offset will be located and used.
    #
    # After seeking to the offset, processing is handed of to either load_xref_table()
    # or load_xref_stream() based on what we find there.
    #
    # Each call appends one section (entries + trailer) to @sections, newest first,
    # then follows the /Prev chain (and /XRefStm hybrid references) recursively.
    #
    #: (?Integer?) -> void
    def load_offsets(offset = nil)
      offset ||= new_buffer.find_first_xref_offset
      offset += @junk_offset

      buf = new_buffer(offset)
      tok_one = buf.token

      # we have a traditional xref table
      if tok_one == "xref" || tok_one == "ref"
        section = load_xref_table(buf)
        @sections << section
        trailer = section[:trailer]

        # hybrid files keep some entries in an xref stream that belongs to the
        # same revision as the traditional xref table
        if trailer.has_key?(:XRefStm)
          hybrid = load_xref_stream_at(trailer[:XRefStm].to_i)
          merge_entries(section[:entries], hybrid[:entries])
          trailer[:Prev] ||= hybrid[:trailer][:Prev]
        end

        load_prev(trailer[:Prev])
        return
      end

      tok_two   = buf.token
      tok_three = buf.token

      # we have an XRef stream
      if tok_one.to_i >= 0 && tok_two.to_i >= 0 && tok_three == "obj"
        buf = new_buffer(offset)
        # Maybe we should be parsing the ObjectHash second argument to the Parser here,
        # to handle the case where an XRef Stream has the Length specified via an
        # indirect object
        stream = PDF::Reader::Parser.new(buf).object(tok_one.to_i, tok_two.to_i)
        if stream.is_a?(PDF::Reader::Stream)
          section = load_xref_stream(stream)
          @sections << section
          load_prev(section[:trailer][:Prev])
          return
        end
      end

      raise PDF::Reader::MalformedPDFError,
        "xref table not found at offset #{offset} (#{tok_one} != xref)"
    end
    ################################################################################
    # Follow the /Prev pointer to the previous xref section. A broken chain is a
    # hard error - without the previous sections the object map is incomplete and
    # silently returning wrong objects is worse than failing loudly.
    #
    #: (untyped) -> void
    def load_prev(prev)
      # Some PDF creators seem to use '/Prev 0' in trailer if there is no previous xref
      # It's not possible for an xref to appear at offset 0, so can safely skip the ref
      return if prev.nil? || prev.to_i == 0

      begin
        load_offsets(prev.to_i)
      rescue PDF::Reader::MalformedPDFError => e
        raise PDF::Reader::MalformedPDFError,
          "broken xref chain: unable to load previous xref section at byte offset " \
          "#{prev.to_i} referenced via /Prev (#{e.message})"
      end
    end
    ################################################################################
    # Assumes the underlying buffer is positioned at the start of a traditional
    # Xref table and processes it into memory.
    #
    #: (PDF::Reader::Buffer) -> Hash[Symbol, untyped]
    def load_xref_table(buf)
      entries = {} #: Hash[Integer, Hash[Integer, Integer | PDF::Reader::Reference | Symbol]]
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
              store_entry(entries, objid, generation, offset + @junk_offset)
            elsif state == "f"
              store_entry(entries, objid, generation, :free)
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

      { :entries => entries, :trailer => trailer }
    end
    ################################################################################
    # Load the xref stream found at the given byte offset. Used for hybrid files
    # where a traditional xref table points to a supplementary xref stream via
    # the /XRefStm trailer key.
    #
    #: (Integer) -> Hash[Symbol, untyped]
    def load_xref_stream_at(offset)
      buf    = new_buffer(offset + @junk_offset)
      obj_id = buf.token.to_i
      gen    = buf.token.to_i
      unless buf.token == "obj"
        raise PDF::Reader::MalformedPDFError,
          "xref stream not found at offset #{offset} referenced via /XRefStm"
      end
      stream = PDF::Reader::Parser.new(new_buffer(offset + @junk_offset)).object(obj_id, gen)
      unless stream.is_a?(PDF::Reader::Stream)
        raise PDF::Reader::MalformedPDFError,
          "xref stream not found at offset #{offset} referenced via /XRefStm"
      end
      load_xref_stream(stream)
    end

    ################################################################################
    # Read an XRef stream from the underlying buffer instead of a traditional xref table.
    #
    #: (PDF::Reader::Stream) -> Hash[Symbol, untyped]
    def load_xref_stream(stream)
      unless stream.hash[:Type] == :XRef
        raise PDF::Reader::MalformedPDFError, "xref stream not found when expected"
      end
      trailer = Hash[stream.hash.select { |key, value|
        [:Size, :Prev, :Root, :Encrypt, :Info, :ID].include?(key)
      }]

      entries = {} #: Hash[Integer, Hash[Integer, Integer | PDF::Reader::Reference | Symbol]]
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
          # a zero width type field defaults to type 1 (in-use), see PDF 32000-1:2008 7.5.8.2
          f1    = widths[0].to_i == 0 ? 1 : unpack_bytes(entry[0,widths[0]])
          f2    = unpack_bytes(entry[widths[0],widths[1]])
          f3    = unpack_bytes(entry[widths[0]+widths[1],widths[2]])
          if f1 == 1 && f2 > 0
            store_entry(entries, objid, f3, f2 + @junk_offset)
          elsif f1 == 2 && f2 > 0
            store_entry(entries, objid, 0, PDF::Reader::Reference.new(f2, 0))
          elsif f1 == 0
            store_entry(entries, objid, f3, :free)
          end
        end
      end

      { :entries => entries, :trailer => trailer }
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
    # Stores an offset value for a particular PDF object ID and generation number
    # within a single xref section. The value is a byte offset, a Reference to an
    # object stream, or the :free tombstone for deleted objects.
    #
    #: (Hash[Integer, Hash[Integer, untyped]], Integer, Integer, untyped) -> untyped
    def store_entry(entries, id, gen, value)
      (entries[id] ||= {})[gen] ||= value
    end
    ################################################################################
    # Merge the entries of a supplementary xref section (eg. the xref stream of a
    # hybrid file) into another section without overwriting existing entries.
    #
    #: (Hash[Integer, Hash[Integer, untyped]], Hash[Integer, Hash[Integer, untyped]]) -> void
    def merge_entries(target, source)
      source.each do |id, gens|
        gens.each do |gen, value|
          store_entry(target, id, gen, value)
        end
      end
    end
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

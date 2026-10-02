# coding: utf-8
# typed: strict
# frozen_string_literal: true

class PDF::Reader
  # The outcome of attempting to decode an embedded file stream, or of
  # attempting to read a file specification that points outside the PDF.
  #
  # Content is never executed and external paths are never followed, so an
  # unreadable entry always comes back as one of these status objects instead
  # of raising or returning nil.
  #
  class EmbeddedFileReadResult
    STATUSES = [:ok, :external, :missing, :unsupported_filter, :error].freeze #: Array[Symbol]

    #: Symbol
    attr_reader :status

    #: String?
    attr_reader :data

    #: Symbol?
    attr_reader :filter

    #: String?
    attr_reader :message

    #: (Symbol, ?String?, ?Symbol?, ?String?) -> void
    def initialize(status, data = nil, filter = nil, message = nil)
      raise ArgumentError, "unknown status #{status}" unless STATUSES.include?(status)

      @status = status
      @data = data
      @filter = filter
      @message = message
    end

    # return true if the embedded bytes were successfully decoded
    #: () -> bool
    def ok?
      status == :ok
    end

    # return true if the file specification points at content that isn't embedded
    # in this PDF (a URL or an external file path). The path is never followed.
    #: () -> bool
    def external?
      status == :external
    end

    # return true if the file specification claimed to embed content, but the
    # stream object couldn't be found
    #: () -> bool
    def missing?
      status == :missing
    end

    # return true if decoding requires a filter this library doesn't implement.
    # #filter names the unsupported filter.
    #: () -> bool
    def unsupported_filter?
      status == :unsupported_filter
    end

    # return true if decoding an otherwise supported stream raised an error
    # (e.g. corrupt compressed data)
    #: () -> bool
    def error?
      status == :error
    end
  end

  # Wraps an embedded file stream (PDF 1.7 table 46) - the actual bytes attached
  # to a FileSpec via its EF dictionary.
  #
  class EmbeddedFile
    #: PDF::Reader::ObjectHash
    attr_reader :objects

    #: PDF::Reader::Reference?
    attr_reader :reference

    #: PDF::Reader::Stream?
    attr_reader :stream

    #: (PDF::Reader::ObjectHash, PDF::Reader::Reference | PDF::Reader::Stream) -> void
    def initialize(objects, stream_or_ref)
      @objects = objects
      if stream_or_ref.is_a?(PDF::Reader::Reference)
        @reference = stream_or_ref
        resolved = objects.deref(stream_or_ref)
        @stream = resolved.is_a?(PDF::Reader::Stream) ? resolved : nil
      else
        @reference = nil
        @stream = stream_or_ref.is_a?(PDF::Reader::Stream) ? stream_or_ref : nil
      end
    end

    # the filters applied to the embedded bytes, in decode order
    #
    #: () -> Array[Symbol]
    def filters
      return [] if stream.nil?
      Array(stream.hash[:Filter]).map { |filter|
        filter.is_a?(::Hash) ? filter[:Name] : filter
      }.compact.map { |name|
        name.respond_to?(:to_sym) ? name.to_sym : name
      }
    end

    # return true if every applied filter can be decoded by this library
    #
    #: () -> bool
    def supported?
      filters.all? { |name| Filter.supported?(name) }
    end

    # the first filter the library can't decode, or nil if all are supported
    #
    #: () -> Symbol?
    def unsupported_filter
      filters.find { |name| !Filter.supported?(name) }
    end

    # the /Subtype of the embedded content (often a MIME-style name)
    #
    #: () -> Symbol?
    def subtype
      return nil if stream.nil?
      stream.hash[:Subtype]
    end

    # the raw /Params dictionary (Size, CheckSum, CreationDate, ModDate, ...)
    #
    #: () -> Hash[Symbol, untyped]
    def params
      return {} if stream.nil?
      objects.deref_hash(stream.hash[:Params]) || {}
    end

    # the advertised uncompressed size of the embedded bytes
    #
    #: () -> Integer?
    def size
      objects.deref_integer(params[:Size])
    end

    # the advertised 16-byte MD5 checksum, as a raw binary string
    #
    #: () -> String?
    def checksum
      params[:CheckSum]
    end

    # the advertised MD5 checksum, as uppercase hex
    #
    #: () -> String?
    def checksum_hex
      checksum && checksum.unpack("H*").first.upcase
    end

    # the advertised creation date (a PDF date string)
    #
    #: () -> String?
    def creation_date
      params[:CreationDate]
    end

    # the advertised last-modified date (a PDF date string)
    #
    #: () -> String?
    def mod_date
      params[:ModDate]
    end

    # Decode the embedded bytes using the library's supported filters. Never
    # raises for content problems - check #status / #ok? on the result instead.
    #
    #: () -> PDF::Reader::EmbeddedFileReadResult
    def read
      return EmbeddedFileReadResult.new(
        :missing, nil, nil, "Embedded file stream could not be resolved"
      ) if stream.nil?

      name = unsupported_filter
      if name
        return EmbeddedFileReadResult.new(
          :unsupported_filter, nil, name, "Unsupported filter: #{name}"
        )
      end

      data = stream.unfiltered_data
      data.force_encoding(::Encoding::BINARY)
      EmbeddedFileReadResult.new(:ok, data)
    rescue UnsupportedFeatureError => e
      EmbeddedFileReadResult.new(:unsupported_filter, nil, name, e.message)
    rescue => e
      EmbeddedFileReadResult.new(:error, nil, nil, e.message)
    end
  end

  # Wraps a File Specification dictionary (PDF 1.7 section 7.11.3). A filespec
  # names an attachment (with /F, /UF and platform specific aliases) and links
  # those names to embedded streams through its /EF dictionary.
  #
  class FileSpec
    # keys that may appear in both the filespec itself (platform specific file
    # names) and its /EF dictionary (matching embedded streams)
    PLATFORM_KEYS = [:F, :UF, :DOS, :Mac, :Unix].freeze #: Array[Symbol]

    # preferred order when choosing a single display name or embedded stream
    PREFERRED_KEYS = [:UF, :F, :DOS, :Mac, :Unix].freeze #: Array[Symbol]

    #: PDF::Reader::ObjectHash
    attr_reader :objects

    #: PDF::Reader::Reference?
    attr_reader :reference

    #: Hash[Symbol, untyped]
    attr_reader :dict

    #: (PDF::Reader::ObjectHash, PDF::Reader::Reference | Hash[Symbol, untyped]) -> void
    def initialize(objects, spec_or_ref)
      @objects = objects
      if spec_or_ref.is_a?(PDF::Reader::Reference)
        @reference = spec_or_ref
        @dict = objects.deref_hash(spec_or_ref) || {} # type: ignore
      else
        @reference = nil
        @dict = spec_or_ref
      end
    end

    # return true if the dictionary looks like a File Specification
    #
    #: () -> bool
    def filespec?
      type = dict[:Type]
      return true if type == :Filespec
      return false unless type.nil?

      ef = safe_ef_dict
      !ef.empty? || dict[:FS] == :URL
    end

    # the /FS entry - :URL for remote specifications, nil for ordinary files
    #
    #: () -> Symbol?
    def file_system
      dict[:FS]
    end

    # true for specifications that point outside the PDF (a URL or a path with
    # no embedded stream). Such paths are never followed.
    #
    #: () -> bool
    def external?
      file_system == :URL || (embedded_streams.empty? && dict.key?(:F))
    end

    # the value of /AFRelationship (e.g. :Alternative, :Data, :Source, :Supplement)
    #
    #: () -> Symbol?
    def relationship
      dict[:AFRelationship]
    end
    alias :af_relationship :relationship

    # the file description text, decoded to UTF-8
    #
    #: () -> String?
    def description
      desc = dict[:Desc]
      desc && EncodingUtils.string_to_utf8(desc)
    end

    # all advertised file names decoded to UTF-8. Keys are :F, :UF, :DOS,
    # :Mac and :Unix.
    #
    #: () -> Hash[Symbol, String]
    def names
      each_name_key.each_with_object({}) { |key, memo|
        value = dict[key]
        memo[key] = EncodingUtils.string_to_utf8(value) if value.is_a?(::String)
      }
    end

    # the recommended display name: /UF (Unicode) when present, then /F, then
    # the first platform specific alias
    #
    #: () -> String?
    def name
      key = PREFERRED_KEYS.find { |candidate| dict[candidate].is_a?(::String) }
      key && EncodingUtils.string_to_utf8(dict[key])
    end

    # every embedded stream advertised via /EF, keyed by :F, :UF, :DOS, :Mac
    # and :Unix. Multiple keys may wrap the same stream object - each alias is
    # retained.
    #
    #: () -> Hash[Symbol, PDF::Reader::EmbeddedFile]
    def embedded_files
      embedded_streams.each_with_object({}) { |(key, stream), memo|
        memo[key] = EmbeddedFile.new(objects, stream)
      }
    end

    # the recommended embedded stream: /UF when present, otherwise /F, then the
    # first platform specific stream available
    #
    #: () -> PDF::Reader::EmbeddedFile?
    def embedded
      key = embedded_key
      key && EmbeddedFile.new(objects, embedded_streams.fetch(key))
    end

    # Decode the recommended embedded stream. Returns an :external result for
    # URL/external-path specifications (the path is not followed) and a :missing
    # result if a promised stream can't be resolved.
    #
    #: () -> PDF::Reader::EmbeddedFileReadResult
    def read
      return external_result if external?

      target = embedded
      return missing_result if target.nil?

      target.read
    end

    private

    #: () -> Enumerable[Symbol]
    def each_name_key
      PLATFORM_KEYS.select { |key| dict[key].is_a?(::String) }
    end

    #: () -> Hash[Symbol, untyped]
    def ef_dict
      safe_ef_dict
    end

    #: () -> Hash[Symbol, untyped]
    def safe_ef_dict
      resolved = objects.deref(dict[:EF])
      resolved.is_a?(::Hash) ? resolved : {}
    end

    #: () -> Hash[Symbol, untyped]
    def embedded_streams
      @embedded_streams ||= PLATFORM_KEYS.each_with_object({}) { |key, memo|
        value = ef_dict[key]
        memo[key] = value unless value.nil?
      }
    end

    #: () -> Symbol?
    def embedded_key
      PREFERRED_KEYS.find { |key| embedded_streams.key?(key) }
    end

    #: () -> PDF::Reader::EmbeddedFileReadResult
    def external_result
      EmbeddedFileReadResult.new(
        :external, nil, nil, "File specification is external and will not be followed"
      )
    end

    #: () -> PDF::Reader::EmbeddedFileReadResult
    def missing_result
      EmbeddedFileReadResult.new(
        :missing, nil, nil, "Embedded file stream could not be resolved"
      )
    end
  end
end

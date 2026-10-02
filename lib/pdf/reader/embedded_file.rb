# coding: utf-8
# typed: strict
# frozen_string_literal: true

require 'digest/md5'

class PDF::Reader
  # A single embedded file (attachment) reference found in a PDF.
  #
  # Each instance represents one association between a Filespec dictionary
  # and the document: an entry in the document EmbeddedFiles name tree, or
  # a member of an /AF array on the catalog, a page, or another object.
  #
  # Instances are value-like descriptors. The embedded bytes are only read
  # when #data is called, and only ever from an embedded stream inside the
  # PDF. External file references are never followed and embedded content
  # is never executed.
  #
  class EmbeddedFile
    # preference order when a filespec offers multiple embedded streams
    EF_PREFERENCE = [:UF, :F, :DOS, :Mac, :Unix].freeze #: Array[Symbol]

    # the name this reference is listed under. For name tree entries this
    # is the tree key (which may be duplicated by other entries); for
    # AF-only entries it falls back to the UF or F filename
    #: String
    attr_reader :name

    # how this reference is associated with the document:
    # :document (name tree or catalog /AF), :page (page /AF),
    # :object (any other object's /AF) or :unknown (only found by
    # scanning objects, e.g. when the name tree is corrupted)
    #: Symbol
    attr_reader :scope

    # where this reference was discovered: :name_tree, :af or :object_scan
    #: Symbol
    attr_reader :origin

    # 1-based page number when scope is :page, otherwise nil
    #: Integer?
    attr_reader :page

    # the AFRelationship value (:Data, :Source, :Supplement, ...) or nil
    #: Symbol?
    attr_reader :relationship

    #: (PDF::Reader::ObjectHash, Hash[Symbol, untyped], untyped, ?Hash[Symbol, untyped]) -> void
    def initialize(objects, filespec, filespec_ref, attrs = {})
      @objects      = objects #: PDF::Reader::ObjectHash
      @filespec     = filespec #: Hash[Symbol, untyped]
      @filespec_ref = filespec_ref #: untyped
      @name         = attrs[:name] #: String
      @scope        = attrs[:scope] #: Symbol
      @origin       = attrs[:origin] #: Symbol
      @page         = attrs[:page] #: Integer?
      @relationship = objects.deref_name(filespec[:AFRelationship]) #: Symbol?
      @uf           = nil #: String?
      @f            = nil #: String?
      @description  = nil #: String?
      @ef_dict      = nil #: Hash[Symbol, untyped]?
      @ef_dict_set  = false #: bool
      @ef_stream    = nil #: PDF::Reader::Stream?
      @ef_stream_set = false #: bool
      @data         = nil #: String?
      @status       = nil #: Symbol?
    end

    # the /UF (unicode) filename from the filespec, as UTF-8
    #: () -> String?
    def uf
      @uf ||= utf8_string(@filespec[:UF])
    end

    # the /F (platform independent) filename from the filespec, as UTF-8
    #: () -> String?
    def f
      @f ||= utf8_string(@filespec[:F])
    end

    # the /Desc description from the filespec, as UTF-8
    #: () -> String?
    def description
      @description ||= utf8_string(@filespec[:Desc])
    end

    # the raw Params dict of the selected embedded stream ({}, if none)
    #: () -> Hash[Symbol, untyped]
    def params
      stream = ef_stream
      params = stream ? @objects.deref_hash(stream.hash[:Params]) : nil
      params || {}
    end

    # declared size of the uncompressed file in bytes (from Params), or nil
    #: () -> Integer?
    def size
      params[:Size]
    end

    # declared MD5 checksum of the uncompressed file as a hex string
    # (from Params), or nil
    #: () -> String?
    def checksum
      raw = params[:CheckSum]
      raw.is_a?(String) ? raw.unpack1("H*") : nil
    end

    # the EF entries this filespec offers, e.g. [:UF, :F] or [:DOS, :Mac]
    #: () -> Array[Symbol]
    def ef_keys
      dict = ef_dict
      return [] unless dict

      EF_PREFERENCE.select { |key| dict.has_key?(key) }
    end

    # the EF entry that #data reads, chosen by UF/F/platform preference
    #: () -> Symbol?
    def ef_key
      ef_keys.first
    end

    # the filters applied to the selected embedded stream
    #: () -> Array[Symbol]
    def filters
      stream = ef_stream
      return [] unless stream

      Array(stream.hash[:Filter]).compact
    end

    # true when the filespec points at an embedded stream inside this PDF
    #: () -> bool
    def embedded?
      !ef_stream.nil?
    end

    # true when the filespec has no embedded stream and only names an
    # external file. External paths are never followed.
    #: () -> bool
    def external?
      ef_dict.nil?
    end

    # the state of the embedded content:
    #   :ok             - #data returns the uncompressed bytes
    #   :external       - no embedded stream, names an external file
    #   :missing_stream - the EF entry does not point at a stream
    #   :unknown_filter - the stream uses a filter pdf-reader cannot decode
    #: () -> Symbol
    def status
      read
      @status || :ok
    end

    # the uncompressed content of the embedded file as a binary String, or
    # nil when it cannot be provided (see #status). The bytes are returned
    # as-is; they are never executed and no external path is ever read.
    #: () -> String?
    def data
      read
      @data
    end

    # true if the actual uncompressed size matches the declared Params Size.
    # nil when the content cannot be read or no Size was declared.
    #: () -> bool?
    def size_valid?
      actual = data
      declared = size
      return nil if declared.nil? || actual.nil?

      actual.bytesize == declared
    end

    # true if the MD5 of the uncompressed content matches the declared
    # Params CheckSum. nil when the content cannot be read or no CheckSum
    # was declared.
    #: () -> bool?
    def checksum_valid?
      actual = data
      declared = checksum
      return nil if declared.nil? || actual.nil?

      Digest::MD5.hexdigest(actual) == declared
    end

    # a stable identity for this reference, so callers can read content
    # for a specific entry even when names are duplicated
    #: () -> untyped
    def filespec_ref
      @filespec_ref
    end

    private

    #: (untyped) -> String?
    def utf8_string(str)
      return nil unless str.is_a?(String)

      PDF::Reader::EncodingUtils.string_to_utf8(str)
    end

    #: () -> Hash[Symbol, untyped]?
    def ef_dict
      unless @ef_dict_set
        @ef_dict = @objects.deref_hash(@filespec[:EF])
        @ef_dict_set = true
      end
      @ef_dict
    end

    #: () -> PDF::Reader::Stream?
    def ef_stream
      unless @ef_stream_set
        dict = ef_dict
        key = dict && EF_PREFERENCE.find { |k| dict.has_key?(k) }
        @ef_stream = key ? @objects.deref_stream(dict[key]) : nil
        @ef_stream_set = true
      end
      @ef_stream
    end

    #: () -> void
    def read
      return if @status

      if external?
        @status = :external
      elsif ef_stream.nil?
        @status = :missing_stream
      else
        begin
          @data = ef_stream.unfiltered_data
          @status = :ok
        rescue PDF::Reader::UnsupportedFeatureError
          @status = :unknown_filter
        end
      end
    end
  end
end

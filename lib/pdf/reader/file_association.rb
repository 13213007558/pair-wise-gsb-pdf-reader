# coding: utf-8
# typed: strict
# frozen_string_literal: true

class PDF::Reader
  # A single entry listing how an embedded file is associated with the PDF.
  #
  # The same FileSpec may legitimately appear more than once - under duplicate
  # names in the EmbeddedFiles name tree, through a page's /AF array, or shared
  # by a name and an association. Each appearance gets its own FileAssociation
  # so no alias or relationship is ever lost.
  #
  class FileAssociation
    # the entry was found in the catalog's EmbeddedFiles name tree
    NAME_TREE   = :name_tree
    # the entry was found in the document catalog's /AF array
    DOCUMENT    = :document
    # the entry was found in a page dictionary's /AF array
    PAGE        = :page
    # the entry was found in a file attachment annotation
    ANNOTATION  = :annotation
    # the entry was found in a form XObject's /AF array
    XOBJECT     = :xobject

    SCOPES = [NAME_TREE, DOCUMENT, PAGE, ANNOTATION, XOBJECT].freeze #: Array[Symbol]

    # where the association was found - one of the SCOPES constants
    #
    #: Symbol
    attr_reader :scope

    # the name the entry was registered under in a name tree, or nil for
    # associations reached through an /AF array or annotation
    #
    #: String?
    attr_reader :name

    #: PDF::Reader::FileSpec
    attr_reader :filespec

    # 1-indexed number of the page carrying the association, or nil for
    # document level associations
    #
    #: Integer?
    attr_reader :page_number

    # a reference to the object that carries the association (page,
    # annotation or xobject dictionary). nil for the name tree/catalog root
    #
    #: PDF::Reader::Reference?
    attr_reader :container_reference

    # extra context describing the container, e.g. the resource name of an
    # xobject or the annotation subtype
    #
    #: Hash[Symbol, untyped]
    attr_reader :details

    #: (Hash[untyped, untyped]) -> void
    def initialize(attrs)
      @scope = attrs.fetch(:scope)
      raise ArgumentError, "unknown scope #{@scope}" unless SCOPES.include?(@scope)

      @name = attrs[:name]
      @filespec = attrs.fetch(:filespec)
      @page_number = attrs[:page_number]
      @container_reference = attrs[:container_reference]
      @details = attrs[:details] || {}
    end

    # the /AFRelationship advertised by the FileSpec (e.g. :Data, :Source,
    # :Alternative, :Supplement), or nil
    #
    #: () -> Symbol?
    def relationship
      filespec.relationship
    end
    alias :af_relationship :relationship

    # the recommended display name from the FileSpec (/UF preferred over /F)
    #
    #: () -> String?
    def file_name
      filespec.name
    end
    alias :filename :file_name

    # reference to the FileSpec dictionary itself - useful as a stable
    # identity for reading content
    #
    #: () -> PDF::Reader::Reference?
    def reference
      filespec.reference
    end

    # true when the filespec points outside the PDF (URL or external path)
    #
    #: () -> bool
    def external?
      filespec.external?
    end

    # Decode the recommended embedded stream for this association. The caller
    # decides where (if anywhere) the bytes are written - the advertised file
    # name is never used as a path.
    #
    #: () -> PDF::Reader::EmbeddedFileReadResult
    def read
      filespec.read
    end

    #: () -> String
    def inspect
      "<PDF::Reader::FileAssociation scope=#{scope} name=#{name.inspect} " \
      "file=#{file_name.inspect} page=#{page_number.inspect} " \
      "relationship=#{relationship.inspect}>"
    end
  end
end

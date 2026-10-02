# coding: utf-8
# typed: true
# frozen_string_literal: true

require 'openssl'

class PDF::Reader
  # A single digital signature found in a PDF file, plus the raw file bytes
  # it applies to.
  #
  # Verification is performed completely offline: no certificates, CRLs or
  # OCSP responses are ever fetched from the network. Whether the signer is
  # trusted is decided solely by the explicit list of trusted certificates
  # the caller passes to #verify.
  #
  #   reader = PDF::Reader.new("signed.pdf")
  #   reader.signatures.each do |sig|
  #     result = sig.verify(trusted_certs: [ca_cert])
  #     puts result.cms_valid?        # cryptographic integrity of signed bytes
  #     puts result.trusted?          # signer chains to the explicit trust anchors
  #     puts result.covered_revision  # which PDF revision the signature covers
  #     puts result.appended_content? # were bytes/revisions added after signing?
  #   end
  #
  # Only the CMS based sub filters adbe.pkcs7.detached and
  # ETSI.CAdES.detached are supported. Note that signature dictionaries in
  # encrypted documents cannot be verified, because their Contents string is
  # stored encrypted.
  #
  class Signature
    # Sub filters we know how to verify. Both are CMS (PKCS#7) detached
    # signatures over the bytes selected by ByteRange.
    #
    SUPPORTED_SUB_FILTERS = ["adbe.pkcs7.detached", "ETSI.CAdES.detached"].freeze

    #: Symbol?
    attr_reader :sub_filter

    #: Array[Integer]?
    attr_reader :byte_range

    #: String?
    attr_reader :contents

    #: String?
    attr_reader :reason

    #: String?
    attr_reader :location

    #: String?
    attr_reader :name

    # Find every signature dictionary in a document and return one Signature
    # instance per dictionary, each bound to the raw bytes of the file.
    #
    #: (PDF::Reader::ObjectHash) -> Array[PDF::Reader::Signature]
    def self.find_all(objects)
      data = extract_bytes(objects)
      signatures = [] #: Array[PDF::Reader::Signature]
      objects.each do |ref, obj|
        next unless obj.is_a?(Hash)
        next unless obj.key?(:ByteRange) && obj.key?(:Contents)

        dict = objects.deref!(ref)
        signatures << new(dict, data) if dict.is_a?(Hash)
      end
      signatures
    end

    #: (Hash[Symbol, untyped], String) -> void
    def initialize(dict, raw_bytes)
      @dict       = dict       #: Hash[Symbol, untyped]
      @raw_bytes  = raw_bytes  #: String
      @sub_filter = dict[:SubFilter] #: Symbol?
      @byte_range = dict[:ByteRange] #: Array[Integer]?
      @contents   = dict[:Contents]  #: String?
      @reason     = dict[:Reason]    #: String?
      @location   = dict[:Location]  #: String?
      @name       = dict[:Name]      #: String?
    end

    # Verify this signature against the raw file bytes.
    #
    # trusted_certs - an array of OpenSSL::X509::Certificate objects (or PEM
    #                 strings) that form the explicit trust policy. The
    #                 signer is only considered trusted if its chain
    #                 terminates at one of these anchors. An empty array
    #                 means "trust nobody".
    # at            - the time at which the certificate chain should be
    #                 evaluated. Defaults to the signing time embedded in
    #                 the CMS structure (or the /M entry), falling back to
    #                 the current time.
    #
    # Returns a PDF::Reader::SignatureVerification.
    #
    #: (?trusted_certs: Array[untyped], ?at: Time?) -> PDF::Reader::SignatureVerification
    def verify(trusted_certs: [], at: nil)
      PDF::Reader::SignatureVerification.new(
        self, @raw_bytes, trusted_certs: trusted_certs, at: at
      )
    end

    # The raw bytes of the document this signature was found in.
    #
    #: () -> String
    def raw_bytes
      @raw_bytes
    end

    # The time the document claims to have been signed, taken from the /M
    # entry of the signature dictionary. Nil when absent or unparseable.
    #
    #: () -> Time?
    def declared_signing_time
      m = @dict[:M]
      return nil unless m.is_a?(String)

      match = m.match(/\AD:(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})/)
      return nil unless match

      Time.utc(*match[1..6].map(&:to_i))
    rescue ArgumentError
      nil
    end

    #: (PDF::Reader::ObjectHash) -> String
    def self.extract_bytes(objects)
      io = objects.io
      pos = io.pos
      io.rewind
      data = io.read
      io.pos = pos
      data.to_s.dup.force_encoding(::Encoding::BINARY)
    end
    private_class_method :extract_bytes
  end
end

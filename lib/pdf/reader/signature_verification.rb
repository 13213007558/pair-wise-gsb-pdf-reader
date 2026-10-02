# coding: utf-8
# typed: true
# frozen_string_literal: true

require 'openssl'

class PDF::Reader
  # The result of verifying one PDF::Reader::Signature against the raw
  # bytes of the document it was found in.
  #
  # The checks are deliberately decomposed so callers can tell *why* a
  # document should (not) be trusted:
  #
  # * byte_range_valid? - the ByteRange is well formed: four non-negative
  #   integers, in order, non overlapping, inside the file, and covering
  #   the whole file except a single gap.
  # * gap_valid?        - the single uncovered gap is exactly the
  #   /Contents placeholder ("<" hex ">") and nothing else.
  # * cms_valid?        - the CMS/PKCS#7 signature cryptographically
  #   verifies over the bytes selected by ByteRange.
  # * trusted?          - every signer chains to the explicit trust
  #   anchors passed to Signature#verify. Performed fully offline.
  # * covered_revision  - which PDF revision (1-based) the signature
  #   covers.
  # * appended_content? - whether any non-whitespace bytes (usually a
  #   newer incremental revision) exist after the signed revision. This
  #   is informational: a normal incremental save does NOT invalidate
  #   the signature of the earlier revision.
  #
  # valid? combines the structural and cryptographic checks of the signed
  # revision only. Trust is a policy decision and is reported separately
  # via trusted?.
  #
  class SignatureVerification
    # PDF whitespace bytes, per section 7.2.2 of ISO 32000.
    PDF_WHITESPACE = "\x00\x09\x0A\x0C\x0D\x20".freeze

    # Matches the canonical end of a PDF revision: a startxref line
    # followed by the EOF marker.
    REVISION_END = /startxref[#{PDF_WHITESPACE}]+\d+[#{PDF_WHITESPACE}]+%%EOF/n.freeze

    #: PDF::Reader::Signature
    attr_reader :signature

    # Structural problems found while checking ByteRange, as a symbol
    # (:byte_range_not_four_integers, :byte_range_negative_values,
    # :byte_range_zero_length, :byte_range_uncovered_prefix,
    # :byte_range_unordered, :byte_range_overlap,
    # :byte_range_out_of_bounds). Nil when the range is well formed.
    #: Symbol?
    attr_reader :byte_range_error

    # OpenSSL error message when the CMS structure could not be parsed or
    # failed to verify. Nil when cms_valid? is true.
    #: String?
    attr_reader :cms_error

    # Symbol or String describing why the signer is not trusted. Nil when
    # trusted? is true.
    #: (Symbol | String)?
    attr_reader :trust_error

    #: (PDF::Reader::Signature, String, ?trusted_certs: Array[untyped], ?at: Time?) -> void
    def initialize(signature, raw_bytes, trusted_certs: [], at: nil)
      @signature     = signature
      @raw_bytes     = raw_bytes
      @trusted_certs = trusted_certs
      @at            = at

      @byte_range_error = validate_byte_range #: Symbol?
      @gap_valid        = check_gap           #: bool
      @pkcs7            = nil #: OpenSSL::PKCS7?
      @cms_valid        = false
      @cms_error        = nil #: String?
      @trusted          = false
      @trust_error      = nil #: (Symbol | String)?
      @revision_ends    = scan_revision_ends  #: Array[Integer]

      check_cms
      check_trust
    end

    # Does the signature use a sub filter we can verify?
    #: () -> bool
    def supported?
      PDF::Reader::Signature::SUPPORTED_SUB_FILTERS.include?(signature.sub_filter.to_s)
    end

    # Is the ByteRange array structurally sound?
    #: () -> bool
    def byte_range_valid?
      @byte_range_error.nil?
    end

    # Are the bytes not covered by ByteRange exactly the /Contents
    # placeholder (angle brackets plus hex) and nothing else?
    #: () -> bool
    def gap_valid?
      @gap_valid
    end

    # Does the CMS signature verify over the ByteRange selected bytes?
    # Chain of trust is NOT part of this check (see trusted?).
    #: () -> bool
    def cms_valid?
      @cms_valid
    end

    # Do all signers chain to the caller supplied trust anchors?
    # Verified offline; an empty trust list never trusts anyone.
    #: () -> bool
    def trusted?
      @trusted
    end

    # Structural and cryptographic integrity of the signed revision.
    # Deliberately unaffected by later incremental updates and by the
    # trust policy.
    #: () -> bool
    def valid?
      supported? && byte_range_valid? && gap_valid? && cms_valid? &&
        !covered_revision.nil? && covered_revision >= 1
    end

    # The 1-based revision of the document that the signature covers, or
    # nil when the covered bytes do not include one complete revision.
    #: () -> Integer?
    def covered_revision
      return nil unless byte_range_valid?

      count = @revision_ends.count { |eof| eof <= covered_end }
      count >= 1 ? count : nil
    end

    # The total number of revisions found in the file.
    #: () -> Integer
    def total_revisions
      @revision_ends.size
    end

    # How many revisions were appended after the signed one.
    #: () -> Integer
    def revisions_after_signature
      total_revisions - covered_revision.to_i
    end

    # Does the file contain any non-whitespace bytes beyond the end of
    # the signed revision? True for documents that were incrementally
    # updated after signing. This does NOT mean the signed bytes were
    # modified.
    #: () -> bool
    def appended_content?
      return false unless byte_range_valid?

      trailing = @raw_bytes.byteslice(covered_end, @raw_bytes.bytesize - covered_end)
      return false if trailing.nil?

      trailing.match?(/[^#{PDF_WHITESPACE}]/n)
    end

    # The byte offset (exclusive) up to which the signature covers the
    # file. Nil when ByteRange is not well formed.
    #: () -> Integer?
    def covered_end
      return nil unless byte_range_valid?

      signature.byte_range[2] + signature.byte_range[3]
    end

    # The exact bytes the CMS signature was computed over.
    #: () -> String?
    def signed_bytes
      return nil unless byte_range_valid?

      offset_one, length_one, offset_two, length_two = signature.byte_range
      @raw_bytes.byteslice(offset_one, length_one).to_s +
        @raw_bytes.byteslice(offset_two, length_two).to_s
    end

    # The signing time embedded in the CMS structure, falling back to the
    # /M entry of the signature dictionary. May be nil.
    #: () -> Time?
    def signing_time
      cms_time = @pkcs7&.signers&.first&.signed_time rescue nil
      cms_time || signature.declared_signing_time
    end

    # The certificate of the first signer, when present in the CMS.
    #: () -> OpenSSL::X509::Certificate?
    def signer_certificate
      signer_certificates.first
    end

    # Certificates of all signers found in the CMS structure.
    #: () -> Array[OpenSSL::X509::Certificate]
    def signer_certificates
      return [] if @pkcs7.nil?

      certs = @pkcs7.certificates || []
      @pkcs7.signers.filter_map do |info|
        certs.find { |cert| cert.serial == info.serial && cert.issuer == info.issuer }
      end
    rescue OpenSSL::PKCS7::PKCS7Error
      []
    end

    private

    #: () -> Symbol?
    def validate_byte_range
      range = signature.byte_range
      unless range.is_a?(Array) && range.size == 4 && range.all? { |v| v.is_a?(Integer) }
        return :byte_range_not_four_integers
      end

      offset_one, length_one, offset_two, length_two = range
      return :byte_range_negative_values if range.any? { |v| v < 0 }
      return :byte_range_zero_length if length_one <= 0 || length_two <= 0
      return :byte_range_uncovered_prefix if offset_one != 0
      return :byte_range_unordered if offset_two < offset_one
      return :byte_range_overlap if offset_two < offset_one + length_one
      return :byte_range_out_of_bounds if offset_two + length_two > @raw_bytes.bytesize

      nil
    end

    #: () -> bool
    def check_gap
      return false unless byte_range_valid?

      contents = signature.contents
      return false unless contents.is_a?(String)

      offset_one, length_one, offset_two, = signature.byte_range
      gap = @raw_bytes.byteslice(offset_one + length_one, offset_two - (offset_one + length_one))
      return false if gap.nil? || gap.empty?
      return false unless gap.start_with?("<") && gap.end_with?(">")

      decode_hex(gap[1..-2].to_s) == contents.b
    end

    #: (String) -> String?
    def decode_hex(str)
      hex = str.gsub(/[#{PDF_WHITESPACE}]/n, "")
      return nil unless hex.match?(/\A[0-9a-fA-F]*\z/n)

      hex += "0" if hex.size.odd?
      [hex].pack("H*")
    end

    #: () -> void
    def check_cms
      return unless supported? && byte_range_valid?

      @pkcs7 = OpenSSL::PKCS7.new(signature.contents.to_s)
      data = signed_bytes.to_s
      flags = OpenSSL::PKCS7::NOVERIFY | OpenSSL::PKCS7::DETACHED
      @cms_valid = @pkcs7.verify(@pkcs7.certificates, OpenSSL::X509::Store.new, data, flags)
      @cms_error = @pkcs7.error_string unless @cms_valid
    rescue OpenSSL::OpenSSLError => e
      @cms_valid = false
      @cms_error = e.message
    end

    #: () -> void
    def check_trust
      if @trusted_certs.empty?
        @trust_error = :no_trusted_certificates_provided
        return
      end
      if @pkcs7.nil?
        @trust_error = :cms_unavailable
        return
      end

      store = OpenSSL::X509::Store.new
      @trusted_certs.each do |cert|
        cert = OpenSSL::X509::Certificate.new(cert) if cert.is_a?(String)
        store.add_cert(cert)
      end
      time = @at || signing_time
      store.time = time if time

      signers = signer_certificates
      if signers.empty?
        @trust_error = :no_signer_certificates
        return
      end

      chain = @pkcs7.certificates || []
      @trusted = signers.all? do |cert|
        store.verify(cert, chain - [cert])
      end
      @trust_error = store.error_string unless @trusted
    rescue OpenSSL::OpenSSLError => e
      @trusted = false
      @trust_error = e.message
    end

    # Byte offsets (exclusive) at which each revision of the document
    # ends, i.e. the offset just after every "startxref N %%EOF".
    #: () -> Array[Integer]
    def scan_revision_ends
      ends = [] #: Array[Integer]
      @raw_bytes.scan(REVISION_END) do
        ends << Regexp.last_match.end(0)
      end
      ends
    end
  end
end

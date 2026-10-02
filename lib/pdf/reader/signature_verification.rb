# coding: utf-8
# typed: strict
# frozen_string_literal: true

require 'openssl'

module PDF
  class Reader

    # The result of verifying a single digital signature embedded in a PDF,
    # performed against the raw bytes of the file.
    #
    # Four questions are answered independently:
    #
    # 1. structurally_valid? - is the ByteRange well formed (ordered, in bounds,
    #    non overlapping) and is the uncovered gap exactly the /Contents
    #    placeholder of the signature dictionary?
    # 2. cms_valid? - does the CMS/PKCS7 signature cryptographically verify over
    #    the exact bytes selected by ByteRange? This says nothing about trust.
    # 3. trusted? - does the signer certificate chain satisfy the explicit trust
    #    policy (trusted certificates) supplied by the caller? Verified fully
    #    offline; no certificates or revocation lists are fetched.
    # 4. signed_revision / appended? - which PDF revision (delimited by %%EOF)
    #    the signature covers, and whether any bytes were appended afterwards,
    #    for example by a later incremental save. Appended bytes do NOT
    #    invalidate the signature of the earlier revision.
    #
    class SignatureVerification

      #: String?
      attr_reader :sub_filter

      #: Array[Integer]?
      attr_reader :byte_range

      #: Array[String]
      attr_reader :errors

      #: Array[OpenSSL::X509::Certificate]
      attr_reader :signer_certificates

      #: Integer?
      attr_reader :signed_revision

      #: Integer
      attr_reader :total_revisions

      #: Integer
      attr_reader :appended_bytes

      #: (sub_filter: String?, byte_range: Array[Integer]?, errors: Array[String], cms_valid: bool, trust_checked: bool, trusted: bool, signer_certificates: Array[OpenSSL::X509::Certificate], signed_revision: Integer?, total_revisions: Integer, appended_bytes: Integer) -> void
      def initialize(sub_filter:, byte_range:, errors:, cms_valid:, trust_checked:,
                     trusted:, signer_certificates:, signed_revision:,
                     total_revisions:, appended_bytes:)
        @sub_filter = sub_filter
        @byte_range = byte_range
        @errors = errors
        @cms_valid = cms_valid
        @trust_checked = trust_checked
        @trusted = trusted
        @signer_certificates = signer_certificates
        @signed_revision = signed_revision
        @total_revisions = total_revisions
        @appended_bytes = appended_bytes
      end

      # true when the ByteRange and /Contents placeholder are structurally sound
      #: -> bool
      def structurally_valid?
        @errors.empty?
      end

      # true when the CMS signature verifies over the signed bytes. Trust in the
      # signer is a separate question, see trusted?
      #: -> bool
      def cms_valid?
        @cms_valid
      end

      # true when the caller supplied an explicit trust policy to check against
      #: -> bool
      def trust_checked?
        @trust_checked
      end

      # true when the signer certificate chains up to the caller supplied trust
      # anchors. Always false when no trust policy was supplied.
      #: -> bool
      def trusted?
        @trusted
      end

      # true when non-whitespace bytes exist after the region covered by this
      # signature, e.g. a newer revision added by an incremental save
      #: -> bool
      def appended?
        @appended_bytes > 0
      end

      # true when the signed bytes are intact: the structure is sound and the
      # CMS signature verifies. Trust is intentionally NOT part of this check.
      #: -> bool
      def valid?
        structurally_valid? && cms_valid?
      end
    end
  end
end

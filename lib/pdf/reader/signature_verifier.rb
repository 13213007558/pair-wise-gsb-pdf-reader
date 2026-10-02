# coding: utf-8
# typed: strict
# frozen_string_literal: true

require 'openssl'

module PDF
  class Reader

    # Offline verification of digital signatures embedded in a PDF file.
    #
    # Supports the two CMS based SubFilters in wide use:
    #
    #   * adbe.pkcs7.detached
    #   * ETSI.CAdES.detached
    #
    # Verification is performed against the raw bytes of the file, not the
    # parsed object graph, so tampering that would confuse the xref tables is
    # still detected. For each signature found, a PDF::Reader::SignatureVerification
    # reports:
    #
    #   * whether the ByteRange structure is sound (ordered, in bounds, non
    #     overlapping, and the uncovered gap is exactly the /Contents placeholder)
    #   * whether the CMS signature cryptographically verifies over the signed
    #     bytes
    #   * whether the signer certificate satisfies an explicit trust policy
    #     supplied by the caller (checked offline, no network access)
    #   * which PDF revision the signature covers and whether any content was
    #     appended after it (e.g. a later incremental save, which does not
    #     invalidate the earlier signature)
    #
    #   results = PDF::Reader::SignatureVerifier.new("signed.pdf").verify(
    #     trusted_certificates: [OpenSSL::X509::Certificate.new(File.read("ca.pem"))]
    #   )
    #   results.each do |result|
    #     puts result.valid?
    #     puts result.trusted?
    #     puts result.signed_revision
    #     puts result.appended?
    #   end
    #
    class SignatureVerifier

      SUPPORTED_SUBFILTERS = ["adbe.pkcs7.detached", "ETSI.CAdES.detached"].freeze #: Array[String]

      BYTE_RANGE_RE = /\/ByteRange[\x00\x09\x0a\x0c\x0d\x20]*\[[\x00\x09\x0a\x0c\x0d\x20]*(\d+)[\x00\x09\x0a\x0c\x0d\x20]+(\d+)[\x00\x09\x0a\x0c\x0d\x20]+(\d+)[\x00\x09\x0a\x0c\x0d\x20]+(\d+)[\x00\x09\x0a\x0c\x0d\x20]*\]/n #: Regexp
      EOF_RE = /%%EOF/n #: Regexp
      WS_RE = /[\x00\x09\x0a\x0c\x0d\x20]/n #: Regexp
      HEX_RE = /\A[0-9A-Fa-f\x00\x09\x0a\x0c\x0d\x20]*\z/n #: Regexp
      CONTENTS_BEFORE_GAP_RE = /\/Contents[\x00\x09\x0a\x0c\x0d\x20]*\z/n #: Regexp
      SUB_FILTER_RE = /\/SubFilter[\x00\x09\x0a\x0c\x0d\x20]*\/([A-Za-z0-9.]+)/n #: Regexp
      OBJ_MARKER_RE = /\bobj[\x00\x09\x0a\x0c\x0d]/n #: Regexp

      # input can be a filename or an IO-ish object (StringIO, File, etc)
      #: (String | IO | StringIO) -> void
      def initialize(input)
        @data = read_input(input) #: String
        @data.force_encoding(::Encoding::BINARY)
      end

      # Verify every embedded signature found in the raw bytes of the file.
      #
      # trusted_certificates: explicit trust anchors (OpenSSL::X509::Certificate
      # objects or PEM/DER strings). When empty, no trust policy is applied and
      # trusted? will be false on every result. Verification never touches the
      # network: no certificates or CRLs are fetched.
      #
      #: (?trusted_certificates: Array[OpenSSL::X509::Certificate] | OpenSSL::X509::Certificate) -> Array[PDF::Reader::SignatureVerification]
      def verify(trusted_certificates: [])
        anchors = Array(trusted_certificates)
        store = nil #: OpenSSL::X509::Store?
        unless anchors.empty?
          store = OpenSSL::X509::Store.new
          anchors.each { |cert| store.add_cert(cert) }
        end

        eof_ends = [] #: Array[Integer]
        offset = 0 #: Integer
        while (match = @data.match(EOF_RE, offset))
          eof_ends << match.end(0)
          offset = match.end(0)
        end

        results = [] #: Array[PDF::Reader::SignatureVerification]
        offset = 0
        while (match = @data.match(BYTE_RANGE_RE, offset))
          results << verify_one(match, eof_ends, store)
          offset = match.end(0)
        end
        results
      end

      private

      #: (String | IO | StringIO) -> String
      def read_input(input)
        if input.is_a?(String)
          File.binread(input)
        else
          input.read.to_s.dup
        end
      end

      #: (MatchData, Array[Integer], OpenSSL::X509::Store?) -> PDF::Reader::SignatureVerification
      def verify_one(match, eof_ends, store)
        range = (1..4).map { |i| match[i].to_s.to_i } #: Array[Integer]
        offset_a = range[0]
        length_a = range[1]
        offset_b = range[2]
        length_b = range[3]
        file_size = @data.bytesize
        errors = [] #: Array[String]

        if length_a <= 0 || length_b <= 0
          errors << "ByteRange sections must have a positive length"
        end
        if offset_a + length_a > offset_b
          errors << "ByteRange sections overlap or are out of order"
        end
        if offset_b + length_b > file_size
          errors << "ByteRange extends past the end of the file"
        end

        gap_start = offset_a + length_a
        gap_end = offset_b
        hex = nil #: String?
        if errors.empty?
          hex = validate_gap(gap_start, gap_end, errors)
        end

        sub_filter = find_sub_filter(match, gap_start)
        if sub_filter.nil?
          errors << "no /SubFilter found near the /ByteRange"
        elsif !SUPPORTED_SUBFILTERS.include?(sub_filter)
          errors << "unsupported /SubFilter #{sub_filter}"
        end

        cms_valid = false
        trusted = false
        signers = [] #: Array[OpenSSL::X509::Certificate]
        if errors.empty? && hex
          contents = [hex].pack("H*")
          der, der_error = extract_cms_der(contents)
          if der.nil?
            errors << der_error.to_s
          else
            signed_data = @data.byteslice(offset_a, length_a).to_s + @data.byteslice(offset_b, length_b).to_s
            cms_valid, trusted, signers = cms_verify(der, signed_data, store)
          end
        end

        signed_revision = nil #: Integer?
        appended_bytes = 0 #: Integer
        if offset_b + length_b <= file_size
          covered_end = offset_b + length_b
          signed_revision = eof_ends.count { |pos| pos <= covered_end }
          if signed_revision == 0
            errors << "signature does not cover a complete PDF revision"
          end
          tail = @data.byteslice(covered_end, file_size - covered_end).to_s
          appended_bytes = tail.gsub(WS_RE, "").empty? ? 0 : tail.bytesize
        end

        PDF::Reader::SignatureVerification.new(
          sub_filter: sub_filter,
          byte_range: range,
          errors: errors,
          cms_valid: cms_valid,
          trust_checked: !store.nil?,
          trusted: trusted,
          signer_certificates: signers,
          signed_revision: signed_revision,
          total_revisions: eof_ends.length,
          appended_bytes: appended_bytes
        )
      end

      # The bytes between the two ByteRange sections must be exactly the
      # /Contents placeholder: a "<" immediately after a /Contents key, then
      # hexadecimal, then ">". Returns the hex string when valid.
      #: (Integer, Integer, Array[String]) -> String?
      def validate_gap(gap_start, gap_end, errors)
        gap = @data.byteslice(gap_start, gap_end - gap_start).to_s
        unless gap.start_with?("<") && gap.end_with?(">")
          errors << "bytes not covered by ByteRange are not a /Contents hex string placeholder"
          return nil
        end
        inner = gap[1..-2].to_s
        unless inner.match?(HEX_RE)
          errors << "/Contents placeholder contains non-hexadecimal bytes"
          return nil
        end
        stripped = inner.gsub(WS_RE, "")
        if stripped.empty? || stripped.length.odd?
          errors << "/Contents placeholder is not valid hexadecimal"
          return nil
        end
        prefix_start = [gap_start - 64, 0].max
        prefix = @data.byteslice(prefix_start, gap_start - prefix_start).to_s
        unless prefix.match?(CONTENTS_BEFORE_GAP_RE)
          errors << "uncovered gap is not preceded by a /Contents key"
          return nil
        end
        stripped
      end

      #: (MatchData, Integer) -> String?
      def find_sub_filter(match, gap_start)
        window_start = [match.begin(0) - 2048, 0].max
        before = @data.byteslice(window_start, match.begin(0) - window_start).to_s
        obj_marker = before.rindex(OBJ_MARKER_RE)
        scope = obj_marker ? before[obj_marker..].to_s : before
        found = nil #: String?
        pos = 0 #: Integer
        while (candidate = scope.match(SUB_FILTER_RE, pos))
          found = candidate[1]
          pos = candidate.end(0)
        end
        return found if found
        after = @data.byteslice(match.end(0), gap_start - match.end(0)).to_s
        later = after.match(SUB_FILTER_RE)
        later && later[1]
      end

      # Slice the CMS DER structure out of the (usually zero padded) Contents
      # string. Any padding after the DER structure must be zero bytes, which
      # is what conforming writers use to fill the placeholder.
      #: (String) -> [String?, String?]
      def extract_cms_der(contents)
        return [nil, "Contents is too short to hold a CMS structure"] if contents.bytesize < 2
        unless contents.getbyte(0) == 0x30
          return [nil, "Contents does not start with a DER SEQUENCE"]
        end
        length_byte = contents.getbyte(1).to_i
        if length_byte < 0x80
          total = 2 + length_byte
        else
          count = length_byte & 0x7f
          return [nil, "Contents uses an unsupported DER length form"] if count == 0 || count > 4
          return [nil, "Contents is truncated inside the DER header"] if contents.bytesize < 2 + count
          length = 0 #: Integer
          contents.byteslice(2, count).to_s.each_byte { |byte| length = (length << 8) | byte }
          total = 2 + count + length
        end
        if total > contents.bytesize
          return [nil, "CMS structure is larger than the Contents placeholder"]
        end
        padding = contents.byteslice(total, contents.bytesize - total).to_s
        unless padding.bytes.all? { |byte| byte == 0 }
          return [nil, "unexpected non-zero data after the CMS structure"]
        end
        [contents.byteslice(0, total), nil]
      end

      # Cryptographic verification of the CMS structure over the signed bytes.
      # cms_valid checks only the signature math (NOVERIFY); trusted checks the
      # signer chain against the caller supplied trust anchors. Both are fully
      # offline.
      #: (String, String, OpenSSL::X509::Store?) -> [bool, bool, Array[OpenSSL::X509::Certificate]]
      def cms_verify(der, signed_data, store)
        pkcs7 = OpenSSL::PKCS7.new(der)
        signers = pkcs7.certificates || []
        flags = OpenSSL::PKCS7::DETACHED | OpenSSL::PKCS7::BINARY
        cms_valid = pkcs7.verify(signers, OpenSSL::X509::Store.new, signed_data,
                                 flags | OpenSSL::PKCS7::NOVERIFY)
        trusted = store ? pkcs7.verify(signers, store, signed_data, flags) : false
        [cms_valid, trusted, signers]
      rescue OpenSSL::OpenSSLError
        [false, false, []]
      end
    end
  end
end

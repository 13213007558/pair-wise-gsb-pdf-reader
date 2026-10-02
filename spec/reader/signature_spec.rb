# coding: utf-8
# frozen_string_literal: true

require 'stringio'
require 'openssl'

describe PDF::Reader::Signature do
  # Builds a CA and an end-entity signing certificate entirely locally.
  # Nothing in these specs touches the network.
  def make_ca(subject: '/CN=Test CA')
    key = OpenSSL::PKey::RSA.new(2048)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = 1
    cert.subject = OpenSSL::X509::Name.parse(subject)
    cert.issuer = cert.subject
    cert.public_key = key.public_key
    cert.not_before = Time.now - 3600
    cert.not_after = Time.now + 365 * 86_400
    ef = OpenSSL::X509::ExtensionFactory.new
    ef.subject_certificate = cert
    ef.issuer_certificate = cert
    cert.add_extension ef.create_extension('basicConstraints', 'CA:TRUE', true)
    cert.add_extension ef.create_extension('keyUsage', 'keyCertSign,cRLSign', true)
    cert.sign(key, OpenSSL::Digest::SHA256.new)
    [cert, key]
  end

  def make_signer(ca_cert, ca_key)
    key = OpenSSL::PKey::RSA.new(2048)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = 2
    cert.subject = OpenSSL::X509::Name.parse('/CN=Test Signer')
    cert.issuer = ca_cert.subject
    cert.public_key = key.public_key
    cert.not_before = Time.now - 3600
    cert.not_after = Time.now + 365 * 86_400
    ef = OpenSSL::X509::ExtensionFactory.new
    ef.subject_certificate = cert
    ef.issuer_certificate = ca_cert
    cert.add_extension ef.create_extension('basicConstraints', 'CA:FALSE', true)
    cert.sign(ca_key, OpenSSL::Digest::SHA256.new)
    [cert, key]
  end

  # Assemble a minimal one-page PDF with a signature dictionary whose
  # /Contents is a placeholder of zero bytes. Returns the document and
  # recomputes the ByteRange until the digit widths are stable.
  def assemble_pdf(byte_range_str, sub_filter, placeholder_size)
    header = "%PDF-1.4\n"
    bodies = [
      "1 0 obj\n<< /Type /Catalog /Pages 2 0 R " \
        "/AcroForm << /Fields [4 0 R] /SigFlags 3 >> >>\nendobj\n",
      "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n",
      "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>\nendobj\n",
      "4 0 obj\n<< /Type /Sig /Filter /Adobe.PPKLite /SubFilter /#{sub_filter} " \
        "/ByteRange [#{byte_range_str}] /Contents <#{'0' * placeholder_size}> " \
        "/Reason (rspec) /M (D:20261001120000Z) >>\nendobj\n"
    ]
    offsets = []
    doc = header.dup
    bodies.each do |obj|
      offsets << doc.bytesize
      doc << obj
    end
    xref_offset = doc.bytesize
    doc << "xref\n0 #{bodies.size + 1}\n"
    doc << "0000000000 65535 f \n"
    offsets.each { |off| doc << format("%010d 00000 n \n", off) }
    doc << "trailer\n<< /Size #{bodies.size + 1} /Root 1 0 R >>\n"
    doc << "startxref\n#{xref_offset}\n%%EOF\n"
    doc
  end

  # Build a PDF and embed a real CMS signature over its ByteRange bytes.
  def build_signed_pdf(sub_filter: 'adbe.pkcs7.detached', placeholder_size: 32_768)
    byte_range_str = '0 0 0 0'
    doc = nil
    cstart = cend = nil
    4.times do
      doc = assemble_pdf(byte_range_str, sub_filter, placeholder_size)
      cstart = doc.index('/Contents <') + '/Contents '.length
      cend = doc.index('>', cstart)
      new_str = [0, cstart, cend + 1, doc.bytesize - (cend + 1)].join(' ')
      break if new_str == byte_range_str

      byte_range_str = new_str
    end

    signed_bytes = doc[0...cstart] + doc[(cend + 1)..]
    flags = OpenSSL::PKCS7::DETACHED | OpenSSL::PKCS7::BINARY
    pkcs7 = OpenSSL::PKCS7.sign(signer_cert, signer_key, signed_bytes, [ca_cert], flags)
    hex = pkcs7.to_der.unpack1('H*')
    raise 'placeholder too small for signature' if hex.length > placeholder_size

    doc[0...cstart] + '<' + hex.ljust(placeholder_size, '0') + '>' + doc[(cend + 1)..]
  end

  # Append a well-formed incremental update (a second revision) to a PDF.
  def append_incremental_revision(pdf)
    prev_startxref = pdf[/startxref\s*(\d+)\s*%%EOF/, 1].to_i
    offset_of_6 = pdf.bytesize
    addition = +"6 0 obj\n<< /Producer (incremental update) >>\nendobj\n"
    xref_offset = pdf.bytesize + addition.bytesize
    addition << "xref\n6 1\n"
    addition << format("%010d 00000 n \n", offset_of_6)
    addition << "trailer\n<< /Size 7 /Root 1 0 R /Prev #{prev_startxref} >>\n"
    addition << "startxref\n#{xref_offset}\n%%EOF\n"
    pdf + addition
  end

  # Replace the ByteRange values in-place, zero-padding to the original
  # digit widths so every other byte in the file stays put.
  def rewrite_byte_range(pdf, values)
    pdf.sub(/\/ByteRange \[(\d+) (\d+) (\d+) (\d+)\]/) do
      widths = [Regexp.last_match(1).size, Regexp.last_match(2).size,
                Regexp.last_match(3).size, Regexp.last_match(4).size]
      padded = values.each_with_index.map { |v, i| v.to_s.rjust(widths[i], '0') }
      "/ByteRange [#{padded.join(' ')}]"
    end
  end

  def byte_range_of(pdf)
    pdf[/\/ByteRange \[(\d+) (\d+) (\d+) (\d+)\]/, 0]
    [Regexp.last_match(1).to_i, Regexp.last_match(2).to_i,
     Regexp.last_match(3).to_i, Regexp.last_match(4).to_i]
  end

  def verify(pdf, **opts)
    reader = PDF::Reader.new(StringIO.new(pdf))
    signatures = reader.signatures
    raise 'expected exactly one signature' unless signatures.size == 1

    signatures.first.verify(**opts)
  end

  let(:ca_cert) { @ca_cert }
  let(:ca_key) { @ca_key }
  let(:signer_cert) { @signer_cert }
  let(:signer_key) { @signer_key }

  before(:all) do
    @ca_cert, @ca_key = make_ca
    @signer_cert, @signer_key = make_signer(@ca_cert, @ca_key)
  end

  let(:signed_pdf) { @signed_pdf ||= build_signed_pdf }

  context 'a valid adbe.pkcs7.detached signature' do
    it 'passes all structural and cryptographic checks' do
      result = verify(signed_pdf, trusted_certs: [ca_cert])

      expect(result.supported?).to eq(true)
      expect(result.byte_range_valid?).to eq(true)
      expect(result.byte_range_error).to be_nil
      expect(result.gap_valid?).to eq(true)
      expect(result.cms_valid?).to eq(true)
      expect(result.valid?).to eq(true)
    end

    it 'trusts the signer when the CA is an explicit trust anchor' do
      result = verify(signed_pdf, trusted_certs: [ca_cert])
      expect(result.trusted?).to eq(true)
      expect(result.trust_error).to be_nil
    end

    it 'does not trust anyone without an explicit trust policy' do
      result = verify(signed_pdf)
      expect(result.trusted?).to eq(false)
      expect(result.trust_error).to eq(:no_trusted_certificates_provided)
      # the signature itself is still cryptographically sound
      expect(result.cms_valid?).to eq(true)
    end

    it 'does not trust a signer chained to an unknown CA' do
      other_ca, = make_ca(subject: '/CN=Other CA')
      result = verify(signed_pdf, trusted_certs: [other_ca])
      expect(result.trusted?).to eq(false)
    end

    it 'honours an explicit verification time in the trust policy' do
      result = verify(signed_pdf, trusted_certs: [ca_cert], at: Time.utc(2035, 1, 1))
      expect(result.trusted?).to eq(false)
    end

    it 'reports the covered revision and no appended content' do
      result = verify(signed_pdf, trusted_certs: [ca_cert])
      expect(result.covered_revision).to eq(1)
      expect(result.total_revisions).to eq(1)
      expect(result.revisions_after_signature).to eq(0)
      expect(result.appended_content?).to eq(false)
    end

    it 'exposes signature metadata' do
      reader = PDF::Reader.new(StringIO.new(signed_pdf))
      sig = reader.signatures.first
      expect(sig.sub_filter).to eq(:'adbe.pkcs7.detached')
      expect(sig.reason).to eq('rspec')
      expect(sig.declared_signing_time).to eq(Time.utc(2026, 10, 1, 12, 0, 0))
    end

    it 'reports the signing time and signer certificate' do
      result = verify(signed_pdf, trusted_certs: [ca_cert])
      expect(result.signing_time).to be_within(5).of(Time.now)
      expect(result.signer_certificate.subject.to_s).to include('Test Signer')
    end
  end

  context 'an ETSI.CAdES.detached signature' do
    it 'is supported and verifies the same way' do
      pdf = build_signed_pdf(sub_filter: 'ETSI.CAdES.detached')
      result = verify(pdf, trusted_certs: [ca_cert])

      expect(result.supported?).to eq(true)
      expect(result.valid?).to eq(true)
      expect(result.cms_valid?).to eq(true)
      expect(result.trusted?).to eq(true)
    end
  end

  context 'an unsupported sub filter' do
    it 'is reported as unsupported' do
      pdf = build_signed_pdf(sub_filter: 'adbe.x509.rsa_sha1')
      result = verify(pdf, trusted_certs: [ca_cert])

      expect(result.supported?).to eq(false)
      expect(result.valid?).to eq(false)
    end
  end

  context 'when covered bytes are modified after signing' do
    let(:tampered) do
      signed_pdf.sub('MediaBox [0 0 612 792]', 'MediaBox [0 0 613 792]')
    end

    it 'fails the CMS check while the structure stays intact' do
      result = verify(tampered, trusted_certs: [ca_cert])

      expect(result.byte_range_valid?).to eq(true)
      expect(result.gap_valid?).to eq(true)
      expect(result.cms_valid?).to eq(false)
      expect(result.valid?).to eq(false)
      # the certificate chain itself is unaffected
      expect(result.trusted?).to eq(true)
    end
  end

  context 'when the uncovered gap is enlarged beyond the Contents placeholder' do
    let(:tampered) do
      range = byte_range_of(signed_pdf)
      delta = (1..).find { |d| (range[1] - d).to_s.size == range[1].to_s.size }
      rewrite_byte_range(signed_pdf, [range[0], range[1] - delta, range[2], range[3]])
    end

    it 'is detected by the gap check, distinctly from a CMS failure' do
      result = verify(tampered, trusted_certs: [ca_cert])

      expect(result.byte_range_valid?).to eq(true)
      expect(result.gap_valid?).to eq(false)
      expect(result.cms_valid?).to eq(false)
      expect(result.valid?).to eq(false)
    end
  end

  context 'when a new revision is appended after signing' do
    let(:appended) { append_incremental_revision(signed_pdf) }

    it 'still verifies the original signature and reports the appendage' do
      result = verify(appended, trusted_certs: [ca_cert])

      expect(result.valid?).to eq(true)
      expect(result.cms_valid?).to eq(true)
      expect(result.trusted?).to eq(true)

      expect(result.covered_revision).to eq(1)
      expect(result.total_revisions).to eq(2)
      expect(result.revisions_after_signature).to eq(1)
      expect(result.appended_content?).to eq(true)
    end
  end

  context 'when only whitespace trails the signed revision' do
    it 'is not reported as appended content' do
      result = verify(signed_pdf + "\r\n\x00 ", trusted_certs: [ca_cert])
      expect(result.appended_content?).to eq(false)
      expect(result.valid?).to eq(true)
    end
  end

  context 'ByteRange structural checks' do
    it 'rejects ranges that do not start at byte 0' do
      range = byte_range_of(signed_pdf)
      pdf = rewrite_byte_range(signed_pdf, [5, range[1] - 5, range[2], range[3]])
      result = verify(pdf, trusted_certs: [ca_cert])
      expect(result.byte_range_valid?).to eq(false)
      expect(result.byte_range_error).to eq(:byte_range_uncovered_prefix)
    end

    it 'rejects overlapping ranges' do
      range = byte_range_of(signed_pdf)
      pdf = rewrite_byte_range(signed_pdf, [range[0], range[1], range[1] - 5, range[3]])
      result = verify(pdf, trusted_certs: [ca_cert])
      expect(result.byte_range_valid?).to eq(false)
      expect(result.byte_range_error).to eq(:byte_range_overlap)
    end

    it 'rejects ranges that run past the end of the file' do
      range = byte_range_of(signed_pdf)
      pdf = rewrite_byte_range(signed_pdf, [range[0], range[1], range[2], range[3] * 2])
      result = verify(pdf, trusted_certs: [ca_cert])
      expect(result.byte_range_valid?).to eq(false)
      expect(result.byte_range_error).to eq(:byte_range_out_of_bounds)
    end

    it 'rejects a ByteRange that is not four integers' do
      pdf = signed_pdf.sub(/\/ByteRange \[([^\]]+)\]/) do
        # pad with extra elements so the file length (and xref) is unchanged
        replacement = '0 1 2'
        replacement += ' 9' while replacement.length < Regexp.last_match(1).length
        "/ByteRange [#{replacement}]"
      end
      result = verify(pdf, trusted_certs: [ca_cert])
      expect(result.byte_range_valid?).to eq(false)
      expect(result.byte_range_error).to eq(:byte_range_not_four_integers)
    end
  end
end

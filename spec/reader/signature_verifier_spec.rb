# coding: utf-8
# frozen_string_literal: true

require 'stringio'
require 'openssl'
require 'tempfile'

RSpec.describe PDF::Reader::SignatureVerifier do
  # All certificates are generated locally in memory. Nothing is fetched from
  # the network.
  before(:all) do
    @ca_key = OpenSSL::PKey::RSA.new(2048)
    @ca_cert = build_ca_cert(@ca_key)

    @signer_key = OpenSSL::PKey::RSA.new(2048)
    @signer_cert = build_signer_cert(@signer_key, @ca_cert, @ca_key)

    # a second, unrelated CA that never signed our signer certificate
    @other_ca_key = OpenSSL::PKey::RSA.new(2048)
    @other_ca_cert = build_ca_cert(@other_ca_key, common_name: "Other CA")
  end

  def build_ca_cert(key, common_name: "Test CA")
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = 1
    cert.subject = OpenSSL::X509::Name.parse("/CN=#{common_name}")
    cert.issuer = cert.subject
    cert.public_key = key.public_key
    cert.not_before = Time.now - 3600
    cert.not_after = Time.now + 86_400
    ef = OpenSSL::X509::ExtensionFactory.new
    ef.subject_certificate = cert
    ef.issuer_certificate = cert
    cert.add_extension ef.create_extension("basicConstraints", "CA:TRUE", true)
    cert.add_extension ef.create_extension("keyUsage", "keyCertSign,cRLSign", true)
    cert.sign key, OpenSSL::Digest::SHA256.new
    cert
  end

  def build_signer_cert(key, ca_cert, ca_key)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = 2
    cert.subject = OpenSSL::X509::Name.parse("/CN=Test Signer")
    cert.issuer = ca_cert.subject
    cert.public_key = key.public_key
    cert.not_before = Time.now - 3600
    cert.not_after = Time.now + 86_400
    ef = OpenSSL::X509::ExtensionFactory.new
    ef.subject_certificate = cert
    ef.issuer_certificate = ca_cert
    cert.add_extension ef.create_extension("basicConstraints", "CA:FALSE", true)
    cert.add_extension ef.create_extension("keyUsage", "digitalSignature", true)
    cert.sign ca_key, OpenSSL::Digest::SHA256.new
    cert
  end

  SignedPdf = Struct.new(:bytes, :byte_range)

  CONTENT_STREAM = "BT /F1 12 Tf 100 700 Td (Hello) Tj ET"

  # Assemble a minimal one-page PDF with a single signature dictionary, then
  # compute a real CMS signature over the ByteRange bytes and embed it.
  def build_signed_pdf(sub_filter: "adbe.pkcs7.detached", placeholder_bytes: 8192)
    placeholder_hex = "00" * placeholder_bytes
    byte_range = nil
    pdf = nil
    br_string = "[0 0 0 0]"

    # The ByteRange values depend on the length of their own textual
    # representation, so iterate until the string stabilises.
    10.times do
      pdf = assemble_pdf(br_string, placeholder_hex, sub_filter)
      lt = pdf.index("<", pdf.index("/Contents"))
      a = 0
      b = lt
      c = lt + placeholder_hex.bytesize + 2
      d = pdf.bytesize - c
      new_br = "[#{a} #{b} #{c} #{d}]"
      if new_br == br_string
        byte_range = [a, b, c, d]
        break
      end
      br_string = new_br
    end
    raise "ByteRange did not stabilise" if byte_range.nil?

    a, b, c, d = byte_range
    signed_data = pdf.byteslice(a, b) + pdf.byteslice(c, d)
    flags = OpenSSL::PKCS7::DETACHED | OpenSSL::PKCS7::BINARY
    pkcs7 = OpenSSL::PKCS7.sign(@signer_cert, @signer_key, signed_data, [@ca_cert], flags)
    der = pkcs7.to_der
    raise "CMS too large for placeholder" if der.bytesize > placeholder_bytes
    hex = der.unpack1("H*").ljust(placeholder_hex.bytesize, "0")
    pdf = pdf.dup
    pdf[b + 1, placeholder_hex.bytesize] = hex
    SignedPdf.new(pdf, byte_range)
  end

  def assemble_pdf(br_string, placeholder_hex, sub_filter)
    sig_dict = "<< /Type /Sig /Filter /Adobe.PPKLite /SubFilter /#{sub_filter} " +               "/ByteRange #{br_string} /Contents <#{placeholder_hex}> >>"
    objects = [
      "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [5 0 R] /SigFlags 3 >> >>",
      "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
      "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [5 0 R] >>",
      "<< /Length #{CONTENT_STREAM.bytesize} >>\nstream\n#{CONTENT_STREAM}\nendstream",
      "<< /Type /Annot /Subtype /Widget /FT /Sig /Rect [0 0 0 0] /V 6 0 R /P 3 0 R /F 4 >>",
      sig_dict
    ]
    pdf = +"%PDF-1.4\n"
    offsets = []
    objects.each_with_index do |body, idx|
      offsets << pdf.bytesize
      pdf << "#{idx + 1} 0 obj\n#{body}\nendobj\n"
    end
    xref_pos = pdf.bytesize
    pdf << "xref\n0 #{objects.size + 1}\n"
    pdf << "0000000000 65535 f \n"
    offsets.each { |off| pdf << format("%010d 00000 n \n", off) }
    pdf << "trailer\n<< /Size #{objects.size + 1} /Root 1 0 R >>\n"
    pdf << "startxref\n#{xref_pos}\n%%EOF\n"
    pdf
  end

  # Append a well formed incremental update (a second revision) after the
  # signed bytes. This must NOT be reported as a modification of the signed
  # revision.
  def append_incremental_update(pdf)
    prev_xref = pdf[/startxref\n(\d+)\n%%EOF\n\z/, 1].to_i
    body = +""
    obj_offset = pdf.bytesize
    body << "7 0 obj\n<< /Producer (incremental update) >>\nendobj\n"
    xref_pos = pdf.bytesize + body.bytesize
    body << "xref\n7 1\n"
    body << format("%010d 00000 n \n", obj_offset)
    body << "trailer\n<< /Size 8 /Root 1 0 R /Prev #{prev_xref} >>\n"
    body << "startxref\n#{xref_pos}\n%%EOF\n"
    pdf + body
  end

  def verify(data, **opts)
    described_class.new(StringIO.new(data)).verify(**opts)
  end

  let(:signed_pdf) { build_signed_pdf }

  context "a well formed adbe.pkcs7.detached signature" do
    it "passes all checks" do
      results = verify(signed_pdf.bytes, trusted_certificates: [@ca_cert])
      expect(results.size).to eq(1)
      result = results.first
      expect(result.sub_filter).to eq("adbe.pkcs7.detached")
      expect(result.byte_range).to eq(signed_pdf.byte_range)
      expect(result.errors).to be_empty
      expect(result.structurally_valid?).to be(true)
      expect(result.cms_valid?).to be(true)
      expect(result.valid?).to be(true)
      expect(result.trusted?).to be(true)
      expect(result.signed_revision).to eq(1)
      expect(result.total_revisions).to eq(1)
      expect(result.appended?).to be(false)
      expect(result.appended_bytes).to eq(0)
      expect(result.signer_certificates.map { |c| c.subject.to_s })
        .to include(a_string_including("Test Signer"))
    end

    it "is also found when the input is a filename" do
      Tempfile.create(["signed", ".pdf"]) do |file|
        file.binmode
        file.write(signed_pdf.bytes)
        file.flush
        results = described_class.new(file.path).verify(trusted_certificates: [@ca_cert])
        expect(results.size).to eq(1)
        expect(results.first.valid?).to be(true)
      end
    end
  end

  context "a well formed ETSI.CAdES.detached signature" do
    it "passes all checks" do
      cades = build_signed_pdf(sub_filter: "ETSI.CAdES.detached")
      results = verify(cades.bytes, trusted_certificates: [@ca_cert])
      expect(results.size).to eq(1)
      result = results.first
      expect(result.sub_filter).to eq("ETSI.CAdES.detached")
      expect(result.valid?).to be(true)
      expect(result.trusted?).to be(true)
    end
  end

  context "trust policy" do
    it "reports trusted? false when no trust anchors are supplied" do
      result = verify(signed_pdf.bytes).first
      expect(result.cms_valid?).to be(true)
      expect(result.trust_checked?).to be(false)
      expect(result.trusted?).to be(false)
    end

    it "reports trusted? false when the signer chains to a different CA" do
      result = verify(signed_pdf.bytes, trusted_certificates: [@other_ca_cert]).first
      expect(result.cms_valid?).to be(true)
      expect(result.trust_checked?).to be(true)
      expect(result.trusted?).to be(false)
    end
  end

  context "when bytes covered by the signature are modified" do
    it "fails CMS verification but keeps the structure valid" do
      tampered = signed_pdf.bytes.sub("(Hello)", "(Jello)")
      expect(tampered).not_to eq(signed_pdf.bytes)
      result = verify(tampered, trusted_certificates: [@ca_cert]).first
      expect(result.structurally_valid?).to be(true)
      expect(result.cms_valid?).to be(false)
      expect(result.valid?).to be(false)
      expect(result.trusted?).to be(false)
      expect(result.signed_revision).to eq(1)
    end
  end

  context "when the uncovered gap (Contents placeholder) is enlarged" do
    it "fails structural verification" do
      _a, b, _c, _d = signed_pdf.byte_range
      enlarged = signed_pdf.bytes.dup
      enlarged.insert(b + 1, "00") # grow the hex placeholder, ByteRange untouched
      result = verify(enlarged, trusted_certificates: [@ca_cert]).first
      expect(result.structurally_valid?).to be(false)
      expect(result.errors).to include(a_string_including("Contents"))
      expect(result.cms_valid?).to be(false)
      expect(result.valid?).to be(false)
    end
  end

  context "when a new revision is appended after signing" do
    it "still verifies the original signature and reports the appendage" do
      appended = append_incremental_update(signed_pdf.bytes)
      result = verify(appended, trusted_certificates: [@ca_cert]).first
      expect(result.structurally_valid?).to be(true)
      expect(result.cms_valid?).to be(true)
      expect(result.valid?).to be(true)
      expect(result.trusted?).to be(true)
      expect(result.signed_revision).to eq(1)
      expect(result.total_revisions).to eq(2)
      expect(result.appended?).to be(true)
      expect(result.appended_bytes).to be > 0
    end
  end

  context "structural ByteRange violations" do
    it "rejects ranges that run past the end of the file" do
      data = "%PDF-1.4\n<< /Type /Sig /SubFilter /adbe.pkcs7.detached " \
             "/ByteRange [0 10 20 999999] /Contents <00> >>\n%%EOF\n"
      result = verify(data).first
      expect(result.structurally_valid?).to be(false)
      expect(result.errors).to include(a_string_including("past the end of the file"))
      expect(result.cms_valid?).to be(false)
    end

    it "rejects overlapping or out of order ranges" do
      data = "%PDF-1.4\n<< /Type /Sig /SubFilter /adbe.pkcs7.detached " \
             "/ByteRange [0 30 20 10] /Contents <00> >>\n%%EOF\n"
      result = verify(data).first
      expect(result.structurally_valid?).to be(false)
      expect(result.errors).to include(a_string_including("overlap"))
    end

    it "rejects a gap that is not the Contents placeholder" do
      data = "%PDF-1.4\n<< /Type /Sig /SubFilter /adbe.pkcs7.detached " \
             "/ByteRange [0 10 20 10] /Contents <00> >>\n0123456789" \
             "not-a-placeholder!\n%%EOF\n"
      result = verify(data).first
      expect(result.structurally_valid?).to be(false)
      expect(result.errors).to include(a_string_including("hex string placeholder"))
    end

    it "rejects an unsupported SubFilter" do
      data = "%PDF-1.4\n<< /Type /Sig /SubFilter /adbe.x509.rsa_sha1 " \
             "/ByteRange [0 10 20 10] /Contents <00> >>\n0123456789" \
             "<00>\n%%EOF\n"
      result = verify(data).first
      expect(result.structurally_valid?).to be(false)
      expect(result.errors).to include(a_string_including("unsupported /SubFilter"))
    end
  end

  context "a PDF without signatures" do
    it "returns an empty result set" do
      data = "%PDF-1.4\n1 0 obj\n<< >>\nendobj\n%%EOF\n"
      expect(verify(data)).to eq([])
    end
  end
end

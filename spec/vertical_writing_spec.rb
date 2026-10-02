# typed: false
# coding: utf-8

# Integration specs for vertical writing mode (WMode 1) in CID-keyed fonts.
#
# Each test assembles a minimal PDF by hand and checks the extracted glyph
# origins and advances against values computed by hand from the PDF spec
# (ISO 32000-1:2008, sections 9.4.4 and 9.7.4.3):
#
#   - the vertical displacement vector for a glyph is (0, w1y), where w1y
#     comes from the W2 array or the DW2 default of [880 -1000]
#   - after each glyph the text position moves by (0, w1y/1000 * font_size)
#   - TJ adjustments move the text position along the same (vertical) axis
#
# All the test PDFs use a 24pt font and place the first glyph at (100, 700),
# so with the default w1y of -1000 each glyph advances 24pt down the page.

describe "vertical writing mode (WMode 1)" do
  TO_UNICODE_CMAP = <<~EOS
    /CIDInit /ProcSet findresource begin
    12 dict begin
    begincmap
    /CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def
    /CMapName /Probe-UCS def
    /CMapType 2 def
    1 begincodespacerange
    <0000> <FFFF>
    endcodespacerange
    3 beginbfchar
    <0001> <0041>
    <0002> <0042>
    <0003> <0043>
    endbfchar
    endcmap
    CMapName currentdict /CMap defineresource pop
    end
    end
  EOS

  TEXT_CONTENT = <<~EOS
    BT
    /V1 24 Tf
    1 0 0 1 100 700 Tm
    <0001> Tj
    <0002> Tj
    <0003> Tj
    ET
  EOS

  TJ_CONTENT = <<~EOS
    BT
    /V1 24 Tf
    1 0 0 1 100 700 Tm
    [<0001> 250 <0002> -125 <0003>] TJ
    ET
  EOS

  def stream_object(dict_entries, data)
    "<< #{dict_entries} /Length #{data.bytesize} >>\nstream\n#{data}\nendstream"
  end

  def assemble_pdf(objects)
    pdf = +"%PDF-1.4\n"
    offsets = {}
    objects.keys.sort.each do |id|
      offsets[id] = pdf.bytesize
      pdf << "#{id} 0 obj\n#{objects[id]}\nendobj\n"
    end
    xref = pdf.bytesize
    size = objects.keys.max + 1
    pdf << "xref\n0 #{size}\n0000000000 65535 f \n"
    (1...size).each do |id|
      pdf << (offsets[id] ? "%010d 00000 n \n" % offsets[id] : "0000000000 65535 f \n")
    end
    pdf << "trailer\n<< /Size #{size} /Root 1 0 R >>\nstartxref\n#{xref}\n%%EOF\n"
    pdf
  end

  # A Type0 font with an Identity-V encoding and a CIDFontType2 descendant.
  # Horizontal widths are 500 for cids 0-3, vertical metrics are configurable.
  def vertical_font_objects(dw2: "880 -1000", w2: nil, encoding: "/Identity-V")
    w2_entries = w2 ? "/W2 [#{w2}] " : ""
    {
      4 => "<< /Type /Font /Subtype /Type0 /BaseFont /ProbeFont " \
           "/Encoding #{encoding} /DescendantFonts [7 0 R] /ToUnicode 8 0 R >>",
      7 => "<< /Type /Font /Subtype /CIDFontType2 /BaseFont /ProbeFont " \
           "/CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> " \
           "/DW 1000 /W [0 [500 500 500 500]] /DW2 [#{dw2}] #{w2_entries}>>",
      8 => stream_object("", TO_UNICODE_CMAP),
    }
  end

  def vertical_text_pdf(content: TEXT_CONTENT, rotate: 0, page_resources: "",
                        page_objects: {}, **font_options)
    assemble_pdf({
      1 => "<< /Type /Catalog /Pages 2 0 R >>",
      2 => "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
      3 => "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] " \
           "#{rotate.zero? ? "" : "/Rotate #{rotate} "}" \
           "/Resources << /Font << /V1 4 0 R >> #{page_resources} >> " \
           "/Contents 6 0 R >>",
      6 => stream_object("", content),
    }.merge(vertical_font_objects(**font_options)).merge(page_objects))
  end

  def extract_runs(pdf_string)
    reader = PDF::Reader.new(StringIO.new(pdf_string))
    page = reader.page(1)
    receiver = PDF::Reader::PageTextReceiver.new
    page.walk(receiver)
    receiver.runs(:rect => nil, :merge => false)
  end

  context "with default vertical metrics (DW2 [880 -1000], no W2)" do
    it "advances each glyph straight down by one em" do
      runs = extract_runs(vertical_text_pdf)

      expect(runs.map { |run| [run.x, run.y] }).to eq([
        [100, 700],
        [100, 676],
        [100, 652],
      ])
      expect(runs.map(&:text)).to eq(%w{A B C})
    end

    it "keeps the horizontal width for each glyph" do
      runs = extract_runs(vertical_text_pdf)

      # 500 glyph units at 24pt = 12pt
      expect(runs.map(&:width)).to eq([12, 12, 12])
    end
  end

  context "with a W2 entry overriding a single glyph" do
    # cid 1 advances by half an em (-500), the rest use the DW2 default
    it "advances each glyph by its own vertical displacement" do
      runs = extract_runs(vertical_text_pdf(:w2 => "1 [-500 250 440]"))

      expect(runs.map { |run| [run.x, run.y] }).to eq([
        [100, 700],
        [100, 688],
        [100, 664],
      ])
    end
  end

  context "with a W2 range overriding several glyphs" do
    # cids 2-3 advance by a quarter em (-250), cid 1 uses the DW2 default
    it "advances each glyph by its own vertical displacement" do
      runs = extract_runs(vertical_text_pdf(:w2 => "2 3 [-250 500 880]"))

      expect(runs.map { |run| [run.x, run.y] }).to eq([
        [100, 700],
        [100, 676],
        [100, 670],
      ])
    end
  end

  context "with TJ adjustments between glyphs" do
    it "applies the adjustments along the vertical axis" do
      runs = extract_runs(vertical_text_pdf(:content => TJ_CONTENT))

      # after glyph 1: (-1.0 - 250/1000) * 24 = -30
      # after glyph 2: (-1.0 + 125/1000) * 24 = -21
      expect(runs.map { |run| [run.x, run.y] }).to eq([
        [100, 700],
        [100, 670],
        [100, 649],
      ])
    end
  end

  context "on a page rotated 90 degrees" do
    it "rotates the vertically displaced origins" do
      runs = extract_runs(vertical_text_pdf(:rotate => 90))

      expect(runs.map { |run| [run.x, run.y] }).to eq([
        [700, -100],
        [676, -100],
        [652, -100],
      ])
    end
  end

  context "inside nested Form XObjects" do
    let(:pdf) do
      vertical_text_pdf(
        :content => "/Fm1 Do\n",
        :page_resources => "/XObject << /Fm1 9 0 R >>",
        :page_objects => {
          9 => stream_object(
            "/Type /XObject /Subtype /Form /BBox [0 0 612 792] " \
            "/Matrix [1 0 0 1 10 20] " \
            "/Resources << /XObject << /Fm2 10 0 R >> >>",
            "/Fm2 Do\n"
          ),
          10 => stream_object(
            "/Type /XObject /Subtype /Form /BBox [0 0 612 792] " \
            "/Resources << /Font << /V1 4 0 R >> >>",
            TEXT_CONTENT
          ),
        }
      )
    end

    it "applies the vertical displacement through the nested matrices" do
      runs = extract_runs(pdf)

      expect(runs.map { |run| [run.x, run.y] }).to eq([
        [110, 720],
        [110, 696],
        [110, 672],
      ])
      expect(runs.map(&:text)).to eq(%w{A B C})
    end
  end

  context "with a horizontal (Identity-H) CID font" do
    it "keeps the existing horizontal advances" do
      runs = extract_runs(vertical_text_pdf(:encoding => "/Identity-H"))

      expect(runs.map { |run| [run.x, run.y] }).to eq([
        [100, 700],
        [112, 700],
        [124, 700],
      ])
      expect(runs.map(&:text)).to eq(%w{A B C})
    end
  end

  context "with a vertical CMap on a font that is not CID-keyed" do
    let(:pdf) do
      assemble_pdf({
        1 => "<< /Type /Catalog /Pages 2 0 R >>",
        2 => "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        3 => "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] " \
             "/Resources << /Font << /V1 4 0 R >> >> /Contents 6 0 R >>",
        4 => "<< /Type /Font /Subtype /TrueType /BaseFont /Helvetica " \
             "/Encoding /Identity-V >>",
        6 => stream_object("", TEXT_CONTENT),
      })
    end

    it "raises an explicit error instead of silently using horizontal metrics" do
      reader = PDF::Reader.new(StringIO.new(pdf))
      page = reader.page(1)
      receiver = PDF::Reader::PageTextReceiver.new

      expect {
        page.walk(receiver)
      }.to raise_error(PDF::Reader::UnsupportedFeatureError)
    end
  end
end

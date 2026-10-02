# typed: false
# coding: utf-8

# End-to-end coverage for CID fonts declared with WMode 1 (vertical writing).
#
# The fixtures (spec/data/vertical-wmode*.pdf) use a 10pt font with the text
# matrix at (100, 700):
#
#   cid 1 ("A") - no W2 entry, uses DW2 defaults [880 -1000]:
#       origin (100 + 880/1000*10, 700) = (108.8, 700), advance 1000/1000*10 = 10
#
#   cid 2 ("B") - single-CID W2 override [-1200 250 0]:
#       origin (100 + 250/1000*10, 690) = (102.5, 690), advance 1200/1000*10 = 12
#
#   cid 3 ("C") and cid 4 ("D") - range W2 override (3 4 -900 600 0):
#       origin x = 100 + 600/1000*10 = 106, advance 900/1000*10 = 9
#
# The content is  <0001>Tj <0002>Tj [<0003> -200 <0004>] TJ
#
# Vertical TJ applies (w1 - tj/1000)*Tfs to the y advance, so between C and D:
#   ty = (-0.9 - (-200)/1000) * 10 = -7.0
# C therefore starts at y 678, D at y 671. Measured from the raw glyph
# stream, C reports an advance of 11 (its own 9 plus the 2-unit TJ shift to
# D) and D reports 9; the merge check uses the nominal 9-unit displacement
# so C and D are concatenated top-to-bottom as "C\nD".
describe "vertical CID font (WMode 1) text extraction" do
  let(:filename) { pdf_spec_file("vertical-wmode") }

  def glyphs(filename)
    PDF::Reader.open(filename) do |reader|
      page = reader.page(1)
      receiver = PDF::Reader::PageTextReceiver.new
      page.walk(receiver)
      receiver.runs(merge: false)
    end
  end

  it "reports wmode 1 and the decoded characters unchanged" do
    PDF::Reader.open(filename) do |reader|
      page = reader.page(1)
      receiver = PDF::Reader::PageTextReceiver.new
      page.walk(receiver)
      chars = receiver.runs(merge: false)
      expect(chars.map(&:text)).to eq(%w[A B C D])
      expect(chars.map(&:wmode)).to eq([1, 1, 1, 1])
    end
  end

  it "places the default-metrics glyph (cid 1) at the hand calculated origin" do
    char = glyphs(filename).first
    expect(char.text).to eq("A")
    expect(char.origin).to be_close_to(PDF::Reader::Point.new(108.8, 700.0))
    expect(char.advance).to be_within(0.001).of(10.0)
  end

  it "places the single-CID W2 override (cid 2) correctly" do
    char = glyphs(filename)[1]
    expect(char.text).to eq("B")
    expect(char.origin).to be_close_to(PDF::Reader::Point.new(102.5, 690.0))
    expect(char.advance).to be_within(0.001).of(12.0)
  end

  it "places the range W2 override cids (3, 4) correctly" do
    c_char = glyphs(filename)[2]
    d_char = glyphs(filename)[3]
    expect(c_char.text).to eq("C")
    expect(c_char.origin).to be_close_to(PDF::Reader::Point.new(106.0, 678.0))
    expect(d_char.text).to eq("D")
    expect(d_char.origin).to be_close_to(PDF::Reader::Point.new(106.0, 671.0))
    expect(d_char.advance).to be_within(0.001).of(9.0)
  end

  it "keeps the horizontal ink width (W array) separate from the vertical advance" do
    char = glyphs(filename).first
    expect(char.width).to be_within(0.001).of(5.0)
  end

  it "folds the TJ adjustment into C's measured advance" do
    c_char = glyphs(filename)[2]
    expect(c_char.advance).to be_within(0.001).of(11.0)
  end

  it "merges adjacent vertical glyphs top to bottom without reordering" do
    runs = PDF::Reader.open(filename) { |reader|
      receiver = PDF::Reader::PageTextReceiver.new
      reader.page(1).walk(receiver)
      receiver.runs
    }
    expect(runs.map(&:text)).to eq(["A", "B", "C\nD"])
  end

  context "with a /Rotate 90 page" do
    let(:rotated) { pdf_spec_file("vertical-wmode-rotated") }

    it "applies the page rotation to the vertical origins" do
      chars = glyphs(rotated)
      expect(chars.map(&:text)).to eq(%w[A B C D])
      expect(chars[0].origin).to be_close_to(PDF::Reader::Point.new(700.0, -108.8))
      expect(chars[1].origin).to be_close_to(PDF::Reader::Point.new(690.0, -102.5))
      expect(chars[2].origin).to be_close_to(PDF::Reader::Point.new(678.0, -106.0))
      expect(chars[3].origin).to be_close_to(PDF::Reader::Point.new(671.0, -106.0))
      expect(chars.map(&:wmode)).to eq([1, 1, 1, 1])
    end

    it "merges adjacent vertical glyphs in reading order after rotation" do
      runs = PDF::Reader.open(rotated) { |reader|
        receiver = PDF::Reader::PageTextReceiver.new
        reader.page(1).walk(receiver)
        receiver.runs
      }
      expect(runs.map(&:text)).to include("C\nD")
    end
  end

  context "with nested Form XObjects" do
    let(:forms) { pdf_spec_file("vertical-wmode-forms") }

    it "positions glyphs in the outer form correctly" do
      chars = glyphs(forms)
      # outer form Matrix [1 0 0 1 50 400], content starts at (0,0):
      # A: (50 + 8.8, 400) = (58.8, 400); B: (50 + 2.5, 390-2) = (52.5, 388)
      outer_a = chars.find { |char| char.text == "A" && char.y.round(2) == 400.0 }
      outer_b = chars.find { |char| char.text == "B" && char.x.round(2) == 52.5 && char.y < 400.0 }
      expect(outer_a.origin).to be_close_to(PDF::Reader::Point.new(58.8, 400.0))
      expect(outer_b.origin).to be_close_to(PDF::Reader::Point.new(52.5, 390.0))
    end

    it "positions glyphs in the nested form correctly" do
      chars = glyphs(forms)
      # nested form Matrix [1 0 0 1 0 100] inside the outer (50,400) form;
      # content Tm at (0,100): C at (50 + 6, 600) = (56, 600)
      nested_c = chars.find { |char| char.text == "C" && char.x.round(2) == 56.0 }
      expect(nested_c.origin).to be_close_to(PDF::Reader::Point.new(56.0, 600.0))
    end
  end
end

describe PDF::Reader::CMap do
  it "defaults to horizontal writing (wmode 0)" do
    expect(PDF::Reader::CMap.new("").wmode).to eq(0)
  end

  it "parses /WMode 1 from a CMap stream" do
    data = <<~CMAP
      /CIDInit /ProcSet findresource begin
      12 dict begin
      begincmap
      /WMode 1 def
      1 begincodespacerange
      <0000> <ffff>
      endcodespacerange
      endcmap
    CMAP
    expect(PDF::Reader::CMap.new(data).wmode).to eq(1)
  end
end

describe PDF::Reader::Font, "vertical CID metrics" do
  let(:object_hash) do
    oh = PDF::Reader::ObjectHash.allocate
    def oh.deref(key); key.is_a?(Symbol) || key.is_a?(Numeric) || key.is_a?(Array) ? key : nil; end
    def oh.deref_name(key); key.is_a?(Symbol) ? key : nil; end
    def oh.deref_integer(key); key.is_a?(Integer) ? key : nil; end
    def oh.deref_number(key); key.is_a?(Numeric) ? key : nil; end
    def oh.deref_array(key); key.is_a?(Array) ? key : nil; end
    def oh.deref_array_of_numbers(key); key.is_a?(Array) ? key : nil; end
    oh
  end

  let(:cidfont) do
    PDF::Reader::Font.new(object_hash, {
      :Subtype  => :CIDFontType2,
      :BaseFont => :TestVertical,
      :WMode    => 1,
      :DW2      => [880, -1000],
      :W2       => [2, [-1200, 250, 0], 3, 4, -900, 600, 0],
    })
  end

  let(:type0) do
    PDF::Reader::Font.new(object_hash, {
      :Subtype          => :Type0,
      :Encoding         => :"Identity-V",
      :DescendantFonts  => [cid_dictionary],
    })
  end

  let(:cid_dictionary) do
    {
      :Subtype  => :CIDFontType2,
      :BaseFont => :TestVertical,
      :WMode    => 1,
      :DW2      => [880, -1000],
      :W2       => [2, [-1200, 250, 0], 3, 4, -900, 600, 0],
    }
  end

  it "reports vertical? for a WMode 1 CIDFont" do
    expect(cidfont.vertical?).to eq(true)
  end

  it "returns the DW2 defaults for an uncovered CID" do
    expect(cidfont.glyph_vertical_metrics(1)).to eq([880.0, -1000.0, 0.0])
  end

  it "returns single-CID W2 metrics in [position_x, displacement_y, displacement_x] order" do
    expect(cidfont.glyph_vertical_metrics(2)).to eq([250.0, -1200.0, 0.0])
  end

  it "returns range W2 metrics" do
    expect(cidfont.glyph_vertical_metrics(3)).to eq([600.0, -900.0, 0.0])
    expect(cidfont.glyph_vertical_metrics(4)).to eq([600.0, -900.0, 0.0])
  end

  it "converts the metrics to text space (1000 units = 1)" do
    expect(cidfont.glyph_vertical_metrics_in_text_space(2)).to eq([0.25, -1.2, 0.0])
  end

  it "inherits WMode and metrics from the Type0's CIDFont descendant" do
    allow(object_hash).to receive(:deref_hash) { |key| key }
    expect(type0.vertical?).to eq(true)
    expect(type0.glyph_vertical_metrics(2)).to eq([250.0, -1200.0, 0.0])
  end

  it "treats a horizontal CIDFont as non-vertical even with Identity-V encoding" do
    horizontal_cid = PDF::Reader::Font.new(object_hash, {
      :Subtype  => :CIDFontType2,
      :BaseFont => :TestHorizontal,
    })
    allow(object_hash).to receive(:deref_hash) { |key| key }
    font = PDF::Reader::Font.new(object_hash, {
      :Subtype          => :Type0,
      :Encoding         => :"Identity-V",
      :DescendantFonts  => [{ :Subtype => :CIDFontType2, :BaseFont => :TestHorizontal }],
    })
    expect(font.vertical?).to eq(false)
  end

  it "parses WMode 1 from an Encoding CMap stream" do
    data = <<~CMAP
      /CIDInit /ProcSet findresource begin
      12 dict begin
      begincmap
      /WMode 1 def
      1 begincodespacerange
      <0000> <ffff>
      endcodespacerange
      endcmap
    CMAP
    stream = PDF::Reader::Stream.new({}, data)
    expect(PDF::Reader::CMap.new(stream.unfiltered_data).wmode).to eq(1)
  end

  it "prefers the CIDFont WMode 0 over a vertical Encoding CMap stream" do
    data = "/WMode 1 def\n"
    stream = PDF::Reader::Stream.new({}, data)
    allow(object_hash).to receive(:deref) { |key| key.is_a?(Symbol) || key.is_a?(Numeric) || key.is_a?(Array) || key.is_a?(PDF::Reader::Stream) ? key : nil }
    allow(object_hash).to receive(:deref_hash) { |key| key }
    font = PDF::Reader::Font.new(object_hash, {
      :Subtype          => :Type0,
      :Encoding         => stream,
      :DescendantFonts  => [{ :Subtype => :CIDFontType2, :BaseFont => :StreamVertical, :WMode => 0 }],
    })
    expect(font.vertical?).to eq(false)
  end
end

describe PDF::Reader::Font, "unsupported vertical CMap combinations" do
  let(:object_hash) { PDF::Reader::ObjectHash.allocate }

  it "raises UnsupportedFeatureError for a named CMap that isn't Identity-H/V" do
    raw = {
      :Subtype   => :Type0,
      :BaseFont  => :Test,
      :Encoding  => :"UniJIS-UCS2-H",
    }
    allow(object_hash).to receive(:deref_name).and_return(nil)
    allow(object_hash).to receive(:deref_array).and_return(nil)
    allow(object_hash).to receive(:deref_integer).and_return(nil)
    allow(object_hash).to receive(:deref_number).and_return(nil)
    allow(object_hash).to receive(:deref_array_of_numbers).and_return(nil)
    # pass through the Encoding name untouched
    allow(object_hash).to receive(:deref) { |key| key }
    allow(object_hash).to receive(:deref_name) { |key| key }
    allow(object_hash).to receive(:deref_array) { |key| key if key.is_a?(Array) }
    allow(object_hash).to receive(:deref_integer) { |key| key if key.is_a?(Integer) }
    allow(object_hash).to receive(:deref_number) { |key| key if key.is_a?(Numeric) }
    expect {
      PDF::Reader::Font.new(object_hash, raw)
    }.to raise_error(PDF::Reader::UnsupportedFeatureError, /UniJIS-UCS2-H/)
  end
end

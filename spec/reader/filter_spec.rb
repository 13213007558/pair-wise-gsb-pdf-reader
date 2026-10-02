# typed: false
# coding: utf-8

describe PDF::Reader::Filter do

  describe ".supported?" do
    it "recognises filters the library can fully decode" do
      expect(PDF::Reader::Filter.supported?(:FlateDecode)).to eq(true)
      expect(PDF::Reader::Filter.supported?(:ASCIIHexDecode)).to eq(true)
      expect(PDF::Reader::Filter.supported?(:ASCII85Decode)).to eq(true)
      expect(PDF::Reader::Filter.supported?(:LZWDecode)).to eq(true)
      expect(PDF::Reader::Filter.supported?(:RunLengthDecode)).to eq(true)
    end

    it "does not claim support for image-only or unknown filters" do
      expect(PDF::Reader::Filter.supported?(:DCTDecode)).to eq(false)
      expect(PDF::Reader::Filter.supported?(:CCITTFaxDecode)).to eq(false)
      expect(PDF::Reader::Filter.supported?(:FantasyDecode)).to eq(false)
    end
  end

  describe "#with" do
    context "when passed :ASCII85Decode" do
      it "returns the appropriate class" do
        expect(PDF::Reader::Filter.with(:ASCII85Decode)).to be_a(PDF::Reader::Filter::Ascii85)
      end
    end

    context "when passed :ASCIIHexDecode" do
      it "returns the appropriate class" do
        expect(PDF::Reader::Filter.with(:ASCIIHexDecode)).to be_a(PDF::Reader::Filter::AsciiHex)
      end
    end

    context "when passed :CCITTFaxDecode" do
      it "returns the appropriate class" do
        expect(PDF::Reader::Filter.with(:CCITTFaxDecode)).to be_a(PDF::Reader::Filter::Null)
      end
    end

    context "when passed :DCTDecode" do
      it "returns the appropriate class" do
        expect(PDF::Reader::Filter.with(:DCTDecode)).to be_a(PDF::Reader::Filter::Null)
      end
    end

    context "when passed :ASCII85Decode" do
      it "returns the appropriate class" do
        expect(PDF::Reader::Filter.with(:ASCII85Decode)).to be_a(PDF::Reader::Filter::Ascii85)
      end
    end

    context "when passed :FlateDecode" do
      it "returns the appropriate class" do
        expect(PDF::Reader::Filter.with(:FlateDecode)).to be_a(PDF::Reader::Filter::Flate)
      end
    end

    context "when passed :JBIG2ecode" do
      it "returns the appropriate class" do
        expect(PDF::Reader::Filter.with(:JBIG2Decode)).to be_a(PDF::Reader::Filter::Null)
      end
    end

    context "when passed :JPXDecode" do
      it "returns the appropriate class" do
        expect(PDF::Reader::Filter.with(:JPXDecode)).to be_a(PDF::Reader::Filter::Null)
      end
    end

    context "when passed :LZWDecode" do
      it "returns the appropriate class" do
        expect(PDF::Reader::Filter.with(:LZWDecode)).to be_a(PDF::Reader::Filter::Lzw)
      end
    end

    context "when passed :RunLengthDecode" do
      it "returns the appropriate class" do
        expect(PDF::Reader::Filter.with(:RunLengthDecode)).to be_a(PDF::Reader::Filter::RunLength)
      end
    end

    context "when passed an unrecognised filter" do
      it "raises an exception" do
        expect {
          PDF::Reader::Filter.with(:FooDecode)
        }.to raise_error(PDF::Reader::UnsupportedFeatureError)
      end
    end
  end
end

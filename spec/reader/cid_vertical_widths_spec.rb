# typed: false
# coding: utf-8

describe PDF::Reader::CidVerticalWidths do
  describe "the DW2-derived defaults" do
    it "uses [880, -1000, 0] when DW2 is absent" do
      widths = PDF::Reader::CidVerticalWidths.new(
        PDF::Reader::CidVerticalWidths.default_metrics(nil), []
      )

      expect(widths[1]).to eq([880, -1000, 0])
    end

    it "honours an explicit DW2 array" do
      widths = PDF::Reader::CidVerticalWidths.new(
        PDF::Reader::CidVerticalWidths.default_metrics([500, -900]), []
      )

      expect(widths[42]).to eq([500.0, -900.0, 0])
    end
  end

  describe "the first W2 form (per-CID triples)" do
    # 10 [-500 250 0  -600 300 10]
    let(:w2) { [10, [-500, 250, 0, -600, 300, 10]] }

    subject do
      PDF::Reader::CidVerticalWidths.new(
        PDF::Reader::CidVerticalWidths.default_metrics(nil), w2
      )
    end

    it "returns [position_x, displacement_y, displacement_x] for cid 10" do
      # [w1x, w1y, w1w]
      expect(subject[10]).to eq([250.0, -500.0, 0.0])
    end

    it "returns the metrics for cid 11" do
      expect(subject[11]).to eq([300.0, -600.0, 10.0])
    end

    it "falls back to the default for uncovered cids" do
      expect(subject[9]).to eq([880, -1000, 0])
      expect(subject[12]).to eq([880, -1000, 0])
    end
  end

  describe "the second W2 form (CID range)" do
    # 20 22 -750 400 0
    let(:w2) { [20, 22, -750, 400, 0] }

    subject do
      PDF::Reader::CidVerticalWidths.new(
        PDF::Reader::CidVerticalWidths.default_metrics([880, -1000]), w2
      )
    end

    it "returns the same metrics for every CID in the range" do
      expect(subject[20]).to eq([400.0, -750.0, 0.0])
      expect(subject[21]).to eq([400.0, -750.0, 0.0])
      expect(subject[22]).to eq([400.0, -750.0, 0.0])
    end

    it "falls back outside the range" do
      expect(subject[19]).to eq([880.0, -1000.0, 0])
      expect(subject[23]).to eq([880.0, -1000.0, 0])
    end

    it "supports a range covering a single CID" do
      widths = PDF::Reader::CidVerticalWidths.new(
        PDF::Reader::CidVerticalWidths.default_metrics(nil), [7, 7, -500, 250, 0]
      )
      expect(widths[7]).to eq([250.0, -500.0, 0.0])
      expect(widths[8]).to eq([880, -1000, 0])
    end

    it "raises when the range start exceeds the range end" do
      expect {
        PDF::Reader::CidVerticalWidths.new(
          PDF::Reader::CidVerticalWidths.default_metrics(nil), [9, 8, -500, 250, 0]
        )[9]
      }.to raise_error(PDF::Reader::MalformedPDFError)
    end
  end

  describe "mixed forms" do
    let(:w2) do
      [
        1, [-500, 250, 0, -600, 300, 0],
        4, 6, -750, 400, 0,
      ]
    end

    subject do
      PDF::Reader::CidVerticalWidths.new(
        PDF::Reader::CidVerticalWidths.default_metrics(nil), w2
      )
    end

    it "looks up each form correctly" do
      expect(subject[1]).to eq([250.0, -500.0, 0.0])
      expect(subject[2]).to eq([300.0, -600.0, 0.0])
      expect(subject[3]).to eq([880, -1000, 0])
      expect(subject[4]).to eq([400.0, -750.0, 0.0])
      expect(subject[5]).to eq([400.0, -750.0, 0.0])
      expect(subject[6]).to eq([400.0, -750.0, 0.0])
      expect(subject[7]).to eq([880, -1000, 0])
    end
  end

  describe "malformed W2 arrays" do
    it "raises when a per-CID section has a trailing partial triple" do
      expect {
        PDF::Reader::CidVerticalWidths.new(
          PDF::Reader::CidVerticalWidths.default_metrics(nil),
          [1, [-500, 250, 0, -600]]
        )[1]
      }.to raise_error(PDF::Reader::MalformedPDFError)
    end
  end
end

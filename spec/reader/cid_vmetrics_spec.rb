# typed: false
# coding: utf-8

describe PDF::Reader::CidVMetrics do
  # Each metrics triple is [w1y, v1x, v1y]:
  #   w1y - the vertical component of the vertical displacement vector
  #   v1x - the horizontal component of the position vector (nil means "half
  #         the glyph width", the consumer fills this in)
  #   v1y - the vertical component of the position vector

  context "with no W2 array" do
    subject { PDF::Reader::CidVMetrics.new([880, -1000], [])}

    it "returns the default metrics from DW2" do
      expect(subject[1]).to eq([-1000, nil, 880])
    end
  end

  context "with no DW2 or W2" do
    subject { PDF::Reader::CidVMetrics.new([], [])}

    it "returns the spec default metrics" do
      expect(subject[1]).to eq([-1000, nil, 880])
    end
  end

  context "with an array using the first form" do
    subject {
      PDF::Reader::CidVMetrics.new([880, -1000], [1, [-500, 250, 440, -250, 500, 880]])
    }

    it "returns correct metrics for index 1" do
      expect(subject[1]).to eq([-500, 250, 440])
    end

    it "returns correct metrics for index 2" do
      expect(subject[2]).to eq([-250, 500, 880])
    end

    it "returns the default metrics for index 3" do
      expect(subject[3]).to eq([-1000, nil, 880])
    end
  end

  context "with an array using the second form" do
    subject { PDF::Reader::CidVMetrics.new([880, -1000], [2, 3, [-250, 500, 880]])}

    it "returns correct metrics for index 1" do
      expect(subject[1]).to eq([-1000, nil, 880])
    end

    it "returns correct metrics for index 2" do
      expect(subject[2]).to eq([-250, 500, 880])
    end

    it "returns correct metrics for index 3" do
      expect(subject[3]).to eq([-250, 500, 880])
    end

    it "returns the default metrics for index 4" do
      expect(subject[4]).to eq([-1000, nil, 880])
    end

    context "and the range is backwards" do
      it "raises an error" do
        expect {
          PDF::Reader::CidVMetrics.new([880, -1000], [3, 2, [-250, 500, 880]])
        }.to raise_error(PDF::Reader::MalformedPDFError)
      end
    end
  end

  context "with an array mixing the first and second form" do
    subject {
      PDF::Reader::CidVMetrics.new([880, -1000], [
        1, [-500, 250, 440],
        2, 3, [-250, 500, 880],
      ])
    }

    it "returns correct metrics for indexes 1 to 4" do
      expect(subject[1]).to eq([-500, 250, 440])
      expect(subject[2]).to eq([-250, 500, 880])
      expect(subject[3]).to eq([-250, 500, 880])
      expect(subject[4]).to eq([-1000, nil, 880])
    end
  end

  context "with a metrics group that doesn't hold exactly three numbers" do
    subject { PDF::Reader::CidVMetrics.new([880, -1000], [1, [-500, 250]])}

    it "ignores the malformed group and falls back to the default" do
      expect(subject[1]).to eq([-1000, nil, 880])
    end
  end
end

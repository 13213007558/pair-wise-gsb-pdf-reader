# typed: false
# coding: utf-8

describe PDF::Reader::WidthCalculator::Composite do
  it_behaves_like "a WidthCalculator duck type" do
    let!(:font)       { double(:cid_default_width    => 50,
                                :cid_widths           => [10,[30,40]],
                                :cid_default_vmetrics => [880, -1000],
                                :cid_vmetrics         => [])
                      }
    subject           { PDF::Reader::WidthCalculator::Composite.new(font)}
  end

  describe "#glyph_width" do
    context "when font#cid_default_width is defined" do
      let!(:font)       { double(:cid_default_width    => 50,
                                  :cid_widths           => [10,[30,40]],
                                  :cid_default_vmetrics => [880, -1000],
                                  :cid_vmetrics         => [])
                        }
      subject           { PDF::Reader::WidthCalculator::Composite.new(font)}

      context "when the glyph code is provided in cid_widths" do
        it "returns the correct width" do
          expect(subject.glyph_width(10)).to eq(30)
        end
      end
      context "when the glyph code is equal to greater than font#first_char" do
        it "returns the default width" do
          expect(subject.glyph_width(9)).to eq(50)
        end
      end
    end
  end

  describe "#glyph_vertical_metrics" do
    context "when the font has no DW2 or W2" do
      let!(:font)       { double(:cid_default_width    => 1000,
                                  :cid_widths           => [],
                                  :cid_default_vmetrics => [],
                                  :cid_vmetrics         => [])
                        }
      subject           { PDF::Reader::WidthCalculator::Composite.new(font)}

      it "returns the spec default vertical metrics" do
        expect(subject.glyph_vertical_metrics(1)).to eq([-1000, 500, 880])
      end
    end

    context "when the font has DW2 but no W2" do
      let!(:font)       { double(:cid_default_width    => 1000,
                                  :cid_widths           => [],
                                  :cid_default_vmetrics => [880, -1000],
                                  :cid_vmetrics         => [])
                        }
      subject           { PDF::Reader::WidthCalculator::Composite.new(font)}

      it "returns the default vertical displacement from DW2" do
        expect(subject.glyph_vertical_metrics(1)).to eq([-1000, 500, 880])
      end
    end

    context "when the font has a W2 entry covering the glyph" do
      let!(:font)       { double(:cid_default_width    => 1000,
                                  :cid_widths           => [1, [500]],
                                  :cid_default_vmetrics => [880, -1000],
                                  :cid_vmetrics         => [1, [-500, 250, 440]])
                        }
      subject           { PDF::Reader::WidthCalculator::Composite.new(font)}

      it "returns the W2 override" do
        expect(subject.glyph_vertical_metrics(1)).to eq([-500, 250, 440])
      end

      it "returns the DW2 default for other glyphs, centering them on half their width" do
        expect(subject.glyph_vertical_metrics(2)).to eq([-1000, 500, 880])
      end
    end

    context "when the glyph code is nil" do
      let!(:font)       { double(:cid_default_width    => 1000,
                                  :cid_widths           => [],
                                  :cid_default_vmetrics => [880, -1000],
                                  :cid_vmetrics         => [])
                        }
      subject           { PDF::Reader::WidthCalculator::Composite.new(font)}

      it "returns zeroed metrics" do
        expect(subject.glyph_vertical_metrics(nil)).to eq([0, 0, 0])
      end
    end
  end

  describe "#glyph_vertical_displacement" do
    let!(:font)       { double(:cid_default_width    => 1000,
                                :cid_widths           => [],
                                :cid_default_vmetrics => [880, -1000],
                                :cid_vmetrics         => [1, [-500, 250, 440]])
                      }
    subject           { PDF::Reader::WidthCalculator::Composite.new(font)}

    it "returns the vertical component of the displacement vector" do
      expect(subject.glyph_vertical_displacement(1)).to eq(-500)
      expect(subject.glyph_vertical_displacement(2)).to eq(-1000)
    end
  end
end

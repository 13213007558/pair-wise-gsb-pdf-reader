# coding: utf-8
# typed: false

describe "page image decoding" do
  let(:page) do
    PDF::Reader.new(pdf_spec_file("shared_image_in_forms")).page(1)
  end

  it "decodes a shared image once while retaining both placements" do
    expect(page.images.size).to eq(1)
    expect(page.image_positions.size).to eq(2)

    image = page.images.first.decode
    expect(image.width).to eq(2)
    expect(image.height).to eq(2)
    expect(image.color_space).to eq(:DeviceRGB)
    expect(image.pixel(0, 0)).to eq([255, 0, 0, 255])
    expect(image.pixel(1, 0)).to eq([0, 255, 0, 255])
    expect(image.pixel(0, 1)).to eq([0, 0, 255, 255])
    expect(image.pixel(1, 1)).to eq([255, 255, 0, 255])
  end

  it "reports placement separately from pixel data, including form matrices" do
    first, second = page.image_positions

    expect(first.label).to eq(:Im0)
    expect(first.matrix).to eq([20, 0, 0, 30, 10, 10])
    expect(first.bottom_left).to eq(PDF::Reader::Point.new(10, 10))
    expect(first.bottom_right).to eq(PDF::Reader::Point.new(30, 10))
    expect(first.top_left).to eq(PDF::Reader::Point.new(10, 40))
    expect(first.top_right).to eq(PDF::Reader::Point.new(30, 40))

    expect(second.label).to eq(:Im0)
    expect(second.matrix).to eq([40, 0, 0, 20, 20, 20])
    expect(second.bottom_left).to eq(PDF::Reader::Point.new(20, 20))
    expect(second.bottom_right).to eq(PDF::Reader::Point.new(60, 20))
    expect(second.top_left).to eq(PDF::Reader::Point.new(20, 40))
    expect(second.top_right).to eq(PDF::Reader::Point.new(60, 40))
  end

  it "uses the same decoded image object for both forms" do
    first, second = page.image_positions

    expect(first.image.stream.object_id).to eq(second.image.stream.object_id)
    expect(first.image.decode.pixel(0, 0)).to eq([255, 0, 0, 255])
  end

  it "keeps image pixels independent from page placement geometry" do
    placement = page.image_positions.first
    image = placement.image.decode

    expect(image.width).to eq(2)
    expect(image.height).to eq(2)
    expect(placement.top_right).not_to eq(placement.bottom_left)
  end
end

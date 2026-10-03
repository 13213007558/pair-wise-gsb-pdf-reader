# coding: utf-8
# typed: false

describe PDF::Reader::ImageXObject do
  def image_stream(dictionary, data)
    PDF::Reader::Stream.new(
      { :Subtype => :Image }.merge(dictionary),
      data.b
    )
  end

  def decode(dictionary, data)
    described_class.new(image_stream(dictionary, data)).decode
  end

  def pixels(image)
    image.height.times.map { |y|
      image.width.times.map { |x| image.pixel(x, y) }
    }
  end

  it "decodes 1-bit DeviceGray samples with byte padding" do
    image = decode(
      { :Width => 3, :Height => 2, :BitsPerComponent => 1, :ColorSpace => :DeviceGray },
      "@\xA0"
    )

    expect(pixels(image)).to eq([
      [[0,0,0,255], [255,255,255,255], [0,0,0,255]],
      [[255,255,255,255], [0,0,0,255], [255,255,255,255]],
    ])
  end

  it "decodes 2-bit and 4-bit DeviceGray samples" do
    two = decode(
      { :Width => 2, :Height => 1, :BitsPerComponent => 2, :ColorSpace => :DeviceGray },
      "\x30"
    )
    four = decode(
      { :Width => 2, :Height => 1, :BitsPerComponent => 4, :ColorSpace => :DeviceGray },
      "\x1F"
    )

    expect(pixels(two)).to eq([[[0,0,0,255], [255,255,255,255]]])
    expect(pixels(four)).to eq([[[17,17,17,255], [255,255,255,255]]])
  end

  it "decodes big-endian 16-bit DeviceGray samples" do
    image = decode(
      { :Width => 2, :Height => 1, :BitsPerComponent => 16, :ColorSpace => :DeviceGray },
      "\x00\x00\xff\xff"
    )

    expect(pixels(image)).to eq([[[0,0,0,255], [255,255,255,255]]])
  end

  it "decodes DeviceRGB and applies an inverted Decode array" do
    image = decode(
      {
        :Width => 2, :Height => 1, :BitsPerComponent => 8, :ColorSpace => :DeviceRGB,
        :Decode => [1.0, 0.0, 1.0, 0.0, 1.0, 0.0],
      },
      "\x00\x00\x00\xff\xff\xff"
    )

    expect(pixels(image)).to eq([
      [[255,255,255,255], [0,0,0,255]],
    ])
  end

  it "uses linear DeviceCMYK conversion when no ICC profile is present" do
    image = decode(
      { :Width => 2, :Height => 1, :BitsPerComponent => 8, :ColorSpace => :DeviceCMYK },
      "\x00\x00\x00\x00" "\xff\x00\x00\x00"
    )

    expect(pixels(image)).to eq([
      [[255,255,255,255], [0,255,255,255]],
    ])
  end

  it "honours an explicit inverted DeviceCMYK Decode array" do
    image = decode(
      {
        :Width => 1, :Height => 1, :BitsPerComponent => 8, :ColorSpace => :DeviceCMYK,
        :Decode => [1, 0, 1, 0, 1, 0, 1, 0],
      },
      "\xff\xff\xff\xff"
    )

    expect(pixels(image)).to eq([[[255,255,255,255]]])
  end

  it "decodes Indexed samples, including reversed Decode" do
    image = decode(
      {
        :Width => 2, :Height => 1, :BitsPerComponent => 1,
        :ColorSpace => [:Indexed, :DeviceRGB, 1, "\xff\x00\x00\x00\xff\x00"],
      },
      "\x40"
    )
    reversed = decode(
      {
        :Width => 2, :Height => 1, :BitsPerComponent => 1, :Decode => [1, 0],
        :ColorSpace => [:Indexed, :DeviceRGB, 1, "\xff\x00\x00\x00\xff\x00"],
      },
      "\x40"
    )

    expect(pixels(image)).to eq([[[255,0,0,255], [0,255,0,255]]])
    expect(pixels(reversed)).to eq([[[0,255,0,255], [255,0,0,255]]])
  end

  it "applies a color-key mask" do
    image = decode(
      {
        :Width => 2, :Height => 1, :BitsPerComponent => 8, :ColorSpace => :DeviceGray,
        :Mask => [0, 0],
      },
      "\x00\xff"
    )

    expect(pixels(image)).to eq([[[0,0,0,0], [255,255,255,255]]])
  end

  it "applies a color-key mask to Indexed palette components" do
    image_stream = image_stream(
      {
        :Width => 2, :Height => 1, :BitsPerComponent => 1,
        :ColorSpace => [:Indexed, :DeviceRGB, 1, "\xff\x00\x00\x00\xff\x00"],
        :Mask => [0, 0, 255, 255, 0, 0],
      },
      "\x40"
    )
    image = described_class.new(image_stream).decode

    expect(pixels(image)).to eq([[[255,0,0,255], [0,255,0,0]]])
  end

  it "resolves a named color space from page resources" do
    stream = image_stream(
      { :Width => 1, :Height => 1, :BitsPerComponent => 8, :ColorSpace => :Palette },
      "\xff"
    )
    spaces = { :Palette => [:Indexed, :DeviceGray, 1, "\x00\xff"] }
    image = described_class.new(stream, :color_spaces => spaces).decode

    expect(image.color_space).to eq(:Indexed)
    expect(image.pixel(0, 0)).to eq([255, 255, 255, 255])
  end

  it "applies an explicit same-size image mask" do
    mask = image_stream(
      {
        :Width => 2, :Height => 1, :ImageMask => true, :ColorSpace => :DeviceGray,
        :BitsPerComponent => 1,
      },
      "\x40"
    )
    image = decode(
      {
        :Width => 2, :Height => 1, :BitsPerComponent => 8, :ColorSpace => :DeviceGray,
        :Mask => mask,
      },
      "\x10\x20"
    )

    expect(pixels(image)).to eq([[[16,16,16,0], [32,32,32,255]]])
  end

  it "honours an inverted Decode array on an explicit mask" do
    mask = image_stream(
      {
        :Width => 2, :Height => 1, :ImageMask => true, :ColorSpace => :DeviceGray,
        :BitsPerComponent => 1, :Decode => [1, 0],
      },
      "\x40"
    )
    image = decode(
      {
        :Width => 2, :Height => 1, :BitsPerComponent => 8, :ColorSpace => :DeviceGray,
        :Mask => mask,
      },
      "\x10\x20"
    )

    expect(pixels(image)).to eq([[[16,16,16,0], [32,32,32,255]]])
  end

  it "resamples and applies an SMask with different dimensions" do
    mask = image_stream(
      { :Width => 1, :Height => 2, :BitsPerComponent => 8, :ColorSpace => :DeviceGray },
      "\x80\xff"
    )
    image = decode(
      {
        :Width => 2, :Height => 2, :BitsPerComponent => 8, :ColorSpace => :DeviceGray,
        :SMask => mask,
      },
      "\xff\xff\xff\xff"
    )

    expect(pixels(image)).to eq([
      [[255,255,255,128], [255,255,255,128]],
      [[255,255,255,255], [255,255,255,255]],
    ])
  end

  it "rejects compressed image formats instead of treating bytes as RGB" do
    image = image_stream(
      {
        :Width => 1, :Height => 1, :BitsPerComponent => 8, :ColorSpace => :DeviceRGB,
        :Filter => :DCTDecode,
      },
      "jpeg"
    )

    expect { described_class.new(image).decode }.to raise_error(
      PDF::Reader::UnsupportedFeatureError, /unsupported image filter/
    )
  end

  it "rejects trailing bytes" do
    image = image_stream(
      { :Width => 1, :Height => 1, :BitsPerComponent => 8, :ColorSpace => :DeviceRGB },
      "\xff\xff\xff!"
    )

    expect { described_class.new(image).decode }.to raise_error(
      PDF::Reader::MalformedPDFError, /length mismatch/
    )
  end

  it "rejects unsupported color spaces" do
    image = image_stream(
      { :Width => 1, :Height => 1, :BitsPerComponent => 8, :ColorSpace => :Lab },
      "\x00"
    )

    expect { described_class.new(image).decode }.to raise_error(
      PDF::Reader::UnsupportedFeatureError, /unsupported image color space/
    )
  end

  it "rejects stencil images because the painting color is supplied outside the XObject" do
    image = image_stream(
      { :Width => 1, :Height => 1, :ImageMask => true },
      "\x80"
    )

    expect { described_class.new(image).decode }.to raise_error(
      PDF::Reader::UnsupportedFeatureError, /stencil/
    )
  end

  it "rejects mismatched explicit mask dimensions" do
    mask = image_stream(
      { :Width => 1, :Height => 1, :ImageMask => true, :BitsPerComponent => 1 },
      "\x00"
    )
    image = image_stream(
      {
        :Width => 2, :Height => 1, :BitsPerComponent => 8, :ColorSpace => :DeviceGray,
        :Mask => mask,
      },
      "\x00\x00"
    )

    expect { described_class.new(image).decode }.to raise_error(
      PDF::Reader::MalformedPDFError, /same-sized/
    )
  end
end

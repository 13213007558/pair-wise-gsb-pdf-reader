# typed: false
# coding: utf-8

require File.expand_path("../../spec_helper", __FILE__)

describe PDF::Reader::ImageXObject do
  let(:builder) { PdfImageBuilder.new }

  # Build a one page PDF around a single image XObject and return the
  # decoded ImageXObject. Extra image dictionary entries can be injected to
  # exercise masks, Decode arrays, etc.
  def single_image(builder, image_content, image_data, opts = {})
    image_id = opts[:image_id] || builder.add(builder.stream(
      image_content, image_data,
      flate: opts.fetch(:flate, true),
      raw: opts.fetch(:raw, false),
      decode_parms: opts[:decode_parms]
    ))
    resources = opts[:resources] || builder.page_resources({ Im1: image_id })
    contents = builder.draw_content([:Im1])
    pages_id = builder.reserve
    page_id = builder.add(builder.page(pages_id, resources, contents))
    builder.set(pages_id, builder.pages([page_id]))
    builder.add(builder.catalog(pages_id))
    builder.first_page.images[:Im1]
  end

  # Typical image dictionary contents. Color space and mask details vary by
  # spec, so they're supplied by the caller.
  def image_dict(color_space:, width:, height:, bpc:, extra: "")
    "/Type /XObject /Subtype /Image /Width #{width} /Height #{height} " \
    "/ColorSpace #{color_space} /BitsPerComponent #{bpc} #{extra}"
  end

  describe "metadata" do
    it "exposes dimensions, bits per component and colour space" do
      data = [255, 0, 0].pack("C*")
      content = image_dict(color_space: "/DeviceRGB", width: 1,
                           height: 1, bpc: 8)
      image = single_image(builder, content, data)

      expect(image.width).to eq 1
      expect(image.height).to eq 1
      expect(image.bits_per_component).to eq 8
      expect(image.color_space).to eq :DeviceRGB
      expect(image.components).to eq 3
      expect(image.indexed?).to eq false
      expect(image.stencil?).to eq false
    end
  end

  describe "DeviceRGB" do
    it "decodes an 8 bit image pixel by pixel" do
      # 2x1: red then blue
      data = [255, 0, 0, 0, 0, 255].pack("C*")
      content = image_dict(color_space: "/DeviceRGB", width: 2,
                           height: 1, bpc: 8, extra: "/Filter /FlateDecode")
      image = single_image(builder, content, data)

      expect(image.rgba).to eq expected_rgba([
        [[255, 0, 0]],
        [[0, 0, 255]],
      ])
    end

    it "decodes 16 bit big endian components to 8 bit channels" do
      # one pixel per row: black, mid gray (0x8000), white
      data = [0x00,0x00,0x00,0x00,0x00,0x00,
              0x80,0x00,0x80,0x00,0x80,0x00,
              0xFF,0xFF,0xFF,0xFF,0xFF,0xFF].pack("C*")
      content = image_dict(color_space: "/DeviceRGB", width: 1,
                           height: 3, bpc: 16)
      image = single_image(builder, content, data)

      # 32768/65535 = 0.500007... -> round(127.5...) = 128
      expect(image.rgba).to eq expected_rgba([
        [[0, 0, 0]],
        [[128, 128, 128]],
        [[255, 255, 255]],
      ])
    end
  end

  describe "DeviceGray" do
    it "expands 1 bit samples with row padding" do
      # 1 row, 5 samples packed as 0b10101_000
      data = [0b10101000].pack("C*")
      content = image_dict(color_space: "/DeviceGray", width: 5,
                           height: 1, bpc: 1)
      image = single_image(builder, content, data)

      expect(image.rgba).to eq expected_rgba([
        [[255, 255, 255], [0, 0, 0], [255, 255, 255],
         [0, 0, 0], [255, 255, 255]],
      ])
    end

    it "honours an inverted [1 0] Decode array for 1 bit samples" do
      data = [0b10101000].pack("C*")
      content = image_dict(color_space: "/DeviceGray", width: 5,
                           height: 1, bpc: 1,
                           extra: "/Decode [1 0]")
      image = single_image(builder, content, data)

      expect(image.rgba).to eq expected_rgba([
        [[0, 0, 0], [255, 255, 255], [0, 0, 0],
         [255, 255, 255], [0, 0, 0]],
      ])
    end

    it "expands 2 bit samples two per byte" do
      # samples 0, 1, 2, 3 packed as 0b00_01_10_11
      data = [0b00011011].pack("C*")
      content = image_dict(color_space: "/DeviceGray", width: 4,
                           height: 1, bpc: 2)
      image = single_image(builder, content, data)

      # 0/3 -> 0, 1/3*255 = 85, 2/3*255 = 170
      expect(image.rgba).to eq expected_rgba([
        [[0, 0, 0], [85, 85, 85], [170, 170, 170], [255, 255, 255]],
      ])
    end

    it "expands 4 bit samples and pads rows to a byte boundary" do
      # 3 samples 0x0, 0x8, 0xF packed as 0x8F padded with 0
      data = [0x08, 0xF0].pack("C*")
      content = image_dict(color_space: "/DeviceGray", width: 3,
                           height: 1, bpc: 4)
      image = single_image(builder, content, data)

      # 8/15*255 = 136
      expect(image.rgba).to eq expected_rgba([
        [[0, 0, 0], [136, 136, 136], [255, 255, 255]],
      ])
    end

    it "decodes 8 bit samples directly" do
      data = [0, 128, 255].pack("C*")
      content = image_dict(color_space: "/DeviceGray", width: 3,
                           height: 1, bpc: 8)
      image = single_image(builder, content, data)

      expect(image.rgba).to eq expected_rgba([
        [[0, 0, 0], [128, 128, 128], [255, 255, 255]],
      ])
    end

    it "inverts 8 bit samples with a [1 0] Decode array" do
      data = [0, 128, 255].pack("C*")
      content = image_dict(color_space: "/DeviceGray", width: 3,
                           height: 1, bpc: 8, extra: "/Decode [1 0]")
      image = single_image(builder, content, data)

      expect(image.rgba).to eq expected_rgba([
        [[255, 255, 255], [127, 127, 127], [0, 0, 0]],
      ])
    end

    it "expands 16 bit samples" do
      data = [0x00, 0x00, 0x80, 0x00, 0xFF, 0xFF].pack("C*")
      content = image_dict(color_space: "/DeviceGray", width: 3,
                           height: 1, bpc: 16)
      image = single_image(builder, content, data)

      expect(image.rgba).to eq expected_rgba([
        [[0, 0, 0], [128, 128, 128], [255, 255, 255]],
      ])
    end
  end

  describe "DeviceCMYK" do
    it "converts with the simple subtractive formula" do
      # cyan (255,0,0,0), process black (0,0,0,255), white (0,0,0,0)
      data = [255,0,0,0, 0,0,0,255, 0,0,0,0].pack("C*")
      content = image_dict(color_space: "/DeviceCMYK", width: 3,
                           height: 1, bpc: 8)
      image = single_image(builder, content, data)

      expect(image.rgba).to eq expected_rgba([
        [[0, 255, 255]],
        [[0, 0, 0]],
        [[255, 255, 255]],
      ])
    end

    it "normalises inverted (additive) samples through the Decode array" do
      # Common "inverted CMYK" encoding with [1 0] x4:
      # raw 0 -> 1.0 ink, raw 255 -> 0.0 ink.
      # cyan encoded as (0,255,255,255); black encoded as (255,255,255,0)
      data = [0,255,255,255, 255,255,255,0].pack("C*")
      content = image_dict(color_space: "/DeviceCMYK", width: 2,
                           height: 1, bpc: 8,
                           extra: "/Decode [1 0 1 0 1 0 1 0]")
      image = single_image(builder, content, data)

      expect(image.rgba).to eq expected_rgba([
        [[0, 255, 255]],
        [[0, 0, 0]],
      ])
    end
  end

  describe "Indexed" do
    it "looks up 2 bit indices in an RGB palette" do
      palette = [255,0,0, 0,255,0, 0,0,255, 0,0,0].pack("C*")
      color_space = "[/Indexed /DeviceRGB 3 #{builder.hex(palette).b}]"
      # indices 3,1,0 packed as 0b11_01_00_pad
      data = [0b11010000].pack("C*")
      content = image_dict(color_space: color_space, width: 3,
                           height: 1, bpc: 2)
      image = single_image(builder, content, data)

      expect(image.color_space).to eq :Indexed
      expect(image.indexed_base).to eq :DeviceRGB
      expect(image.rgba).to eq expected_rgba([
        [[0, 0, 0]],
        [[0, 255, 0]],
        [[255, 0, 0]],
      ])
    end

    it "supports 1 bit indices" do
      palette = [255,255,255, 255,0,0].pack("C*")
      color_space = "[/Indexed /DeviceRGB 1 #{builder.hex(palette).b}]"
      data = [0b10000000].pack("C*")
      content = image_dict(color_space: color_space, width: 1,
                           height: 1, bpc: 1)
      image = single_image(builder, content, data)

      expect(image.rgba).to eq expected_rgba([[[255, 0, 0]]])
    end

    it "supports a DeviceGray palette" do
      palette = [0, 255].pack("C*")
      color_space = "[/Indexed /DeviceGray 1 #{builder.hex(palette).b}]"
      data = [0b01000000].pack("C*")
      content = image_dict(color_space: color_space, width: 2,
                           height: 1, bpc: 1)
      image = single_image(builder, content, data)

      expect(image.rgba).to eq expected_rgba([
        [[0, 0, 0]],
        [[255, 255, 255]],
      ])
    end

    it "supports 4 bit indices in an RGB palette" do
      palette = [
        255,0,0, 0,255,0, 0,0,255, 255,255,0,
        255,0,255, 0,255,255, 255,255,255, 0,0,0
      ].pack("C*")
      color_space = "[/Indexed /DeviceRGB 7 #{builder.hex(palette).b}]"
      # indices 0, 7 in the first nibble pair
      data = [0x07].pack("C*")
      content = image_dict(color_space: color_space, width: 2,
                           height: 1, bpc: 4)
      image = single_image(builder, content, data)

      expect(image.rgba).to eq expected_rgba([
        [[255, 0, 0]],
        [[0, 0, 0]],
      ])
    end

    it "maps indices through a reversed [Hival 0] Decode array" do
      palette = [255,0,0, 0,0,255].pack("C*")
      color_space = "[/Indexed /DeviceRGB 1 #{builder.hex(palette).b}]"
      data = [0b00000000].pack("C*")
      content = image_dict(color_space: color_space, width: 1,
                           height: 1, bpc: 1, extra: "/Decode [1 0]")
      image = single_image(builder, content, data)

      # raw 0 mapped through [1 0] to palette index 1 -> blue
      expect(image.rgba).to eq expected_rgba([[[0, 0, 255]]])
    end

    it "supports a palette held in an indirect stream" do
      palette = [10,20,30, 40,50,60].pack("C*")
      palette_id = builder.add(builder.stream("", palette, flate: false))
      color_space = "[/Indexed /DeviceRGB 1 #{palette_id} 0 R]"
      data = [0b10000000].pack("C*")
      content = image_dict(color_space: color_space, width: 1,
                           height: 1, bpc: 1)
      image = single_image(builder, content, data)

      expect(image.rgba).to eq expected_rgba([[[40, 50, 60]]])
    end
  end

  describe "transparency" do
    it "applies a colour key Mask to matching pixels" do
      # green is fully transparent, red and blue stay opaque
      data = [255,0,0, 0,255,0, 0,0,255].pack("C*")
      content = image_dict(color_space: "/DeviceRGB", width: 3,
                           height: 1, bpc: 8,
                           extra: "/Mask [0 0 255 255 0 0]")
      image = single_image(builder, content, data)

      expect(image.rgba).to eq expected_rgba([
        [[255, 0, 0]],
        [[0, 255, 0]],
        [[0, 0, 255]],
      ], alpha: [[255], [0], [255]])
    end

    it "matches colour key ranges inclusively" do
      data = [9, 11, 100].pack("C*")
      content = image_dict(color_space: "/DeviceGray", width: 3,
                           height: 1, bpc: 8, extra: "/Mask [10 20]")
      image = single_image(builder, content, data)

      expect(image.rgba).to eq expected_rgba([
        [[9, 9, 9]],
        [[11, 11, 11]],
        [[100, 100, 100]],
      ], alpha: [[255], [0], [255]])
    end

    it "applies a colour key Mask to packed 1 bit samples" do
      data = [0b10100000].pack("C*")
      content = image_dict(color_space: "/DeviceGray", width: 3,
                           height: 1, bpc: 1, extra: "/Mask [0 0]")
      image = single_image(builder, content, data)

      expect(image.rgba).to eq expected_rgba([
        [[255, 255, 255]],
        [[0, 0, 0]],
        [[255, 255, 255]],
      ], alpha: [[255], [0], [255]])
    end

    it "applies an explicit stencil mask the same size as the image" do
      mask_id = builder.reserve
      data = [255,0,0, 0,255,0].pack("C*")
      content = image_dict(color_space: "/DeviceRGB", width: 2,
                           height: 1, bpc: 8,
                           extra: "/Mask #{mask_id} 0 R")
      image_id = builder.reserve
      resources = builder.page_resources({ Im1: image_id })
      contents = builder.draw_content([:Im1])
      pages_id = builder.reserve
      page_id = builder.add(builder.page(pages_id, resources, contents))
      builder.set(pages_id, builder.pages([page_id]))
      builder.add(builder.catalog(pages_id))

      mask = "/Type /XObject /Subtype /Image /ImageMask true " \
             "/Width 2 /Height 1 /BitsPerComponent 1"
      builder.set(mask_id, builder.stream(mask, [0b10000000].pack("C*"),
                                         flate: false))
      builder.set(image_id, builder.stream(content, data, flate: false))

      image = builder.first_page.images[:Im1]
      expect(image.rgba).to eq expected_rgba([
        [[255, 0, 0]],
        [[0, 255, 0]],
      ], alpha: [[255], [0]])
    end

    it "resamples an explicit mask with different dimensions" do
      # image is 4x1, mask is 2x1; corner aligned nearest neighbour:
      # image pixels 0,1 use mask col 0 (1), pixels 2,3 use col 1 (0)
      mask_id = builder.reserve
      data = [255,0,0, 255,0,0, 255,0,0, 255,0,0].pack("C*")
      content = image_dict(color_space: "/DeviceRGB", width: 4,
                           height: 1, bpc: 8,
                           extra: "/Mask #{mask_id} 0 R")
      image_id = builder.reserve
      resources = builder.page_resources({ Im1: image_id })
      contents = builder.draw_content([:Im1])
      pages_id = builder.reserve
      page_id = builder.add(builder.page(pages_id, resources, contents))
      builder.set(pages_id, builder.pages([page_id]))
      builder.add(builder.catalog(pages_id))

      mask = "/Type /XObject /Subtype /Image /ImageMask true " \
             "/Width 2 /Height 1 /BitsPerComponent 1"
      builder.set(mask_id, builder.stream(mask, [0b10000000].pack("C*"),
                                         flate: false))
      builder.set(image_id, builder.stream(content, data, flate: false))

      image = builder.first_page.images[:Im1]
      expect(image.rgba.bytes[3]).to eq 255
      expect(image.rgba.bytes[7]).to eq 255
      expect(image.rgba.bytes[11]).to eq 0
      expect(image.rgba.bytes[15]).to eq 0
    end

    it "honours a reversed [0 1] Decode array on an explicit mask" do
      mask_id = builder.reserve
      data = [255,0,0, 0,255,0].pack("C*")
      content = image_dict(color_space: "/DeviceRGB", width: 2,
                           height: 1, bpc: 8,
                           extra: "/Mask #{mask_id} 0 R")
      image_id = builder.reserve
      resources = builder.page_resources({ Im1: image_id })
      contents = builder.draw_content([:Im1])
      pages_id = builder.reserve
      page_id = builder.add(builder.page(pages_id, resources, contents))
      builder.set(pages_id, builder.pages([page_id]))
      builder.add(builder.catalog(pages_id))

      mask = "/Type /XObject /Subtype /Image /ImageMask true " \
             "/Width 2 /Height 1 /BitsPerComponent 1 /Decode [0 1]"
      builder.set(mask_id, builder.stream(mask, [0b10000000].pack("C*"),
                                         flate: false))
      builder.set(image_id, builder.stream(content, data, flate: false))

      image = builder.first_page.images[:Im1]
      # reversed polarity: bit 1 (first pixel) is now transparent
      expect(image.rgba).to eq expected_rgba([
        [[255, 0, 0]],
        [[0, 255, 0]],
      ], alpha: [[0], [255]])
    end

    it "applies an SMask with the same dimensions" do
      smask_id = builder.reserve
      data = [255,0,0, 0,255,0].pack("C*")
      content = image_dict(color_space: "/DeviceRGB", width: 2,
                           height: 1, bpc: 8,
                           extra: "/SMask #{smask_id} 0 R")
      image_id = builder.reserve
      resources = builder.page_resources({ Im1: image_id })
      contents = builder.draw_content([:Im1])
      pages_id = builder.reserve
      page_id = builder.add(builder.page(pages_id, resources, contents))
      builder.set(pages_id, builder.pages([page_id]))
      builder.add(builder.catalog(pages_id))

      smask = "/Type /XObject /Subtype /Image /Width 2 /Height 1 " \
              "/ColorSpace /DeviceGray /BitsPerComponent 8"
      builder.set(smask_id, builder.stream(smask, [0, 255].pack("C*"),
                                          flate: false))
      builder.set(image_id, builder.stream(content, data, flate: false))

      image = builder.first_page.images[:Im1]
      expect(image.rgba).to eq expected_rgba([
        [[255, 0, 0]],
        [[0, 255, 0]],
      ], alpha: [[0], [255]])
    end

    it "accepts an SMask dictionary with an image group and subtype" do
      group_id = builder.reserve
      smask_id = builder.reserve
      data = [255,0,0].pack("C*")
      content = image_dict(color_space: "/DeviceRGB", width: 1,
                           height: 1, bpc: 8,
                           extra: "/SMask #{smask_id} 0 R")
      image_id = builder.reserve
      resources = builder.page_resources({ Im1: image_id })
      contents = builder.draw_content([:Im1])
      pages_id = builder.reserve
      page_id = builder.add(builder.page(pages_id, resources, contents))
      builder.set(pages_id, builder.pages([page_id]))
      builder.add(builder.catalog(pages_id))

      group = "/Type /XObject /Subtype /Image /Width 1 /Height 1 " \
              "/ColorSpace /DeviceGray /BitsPerComponent 8"
      builder.set(group_id, builder.stream(group, [64].pack("C*"),
                                          flate: false))
      builder.set(smask_id, builder.dict("/S /Luminosity /G #{group_id} 0 R"))
      builder.set(image_id, builder.stream(content, data, flate: false))

      image = builder.first_page.images[:Im1]
      expect(image.rgba).to eq rgba_bytes(255, 0, 0, 64)
    end

    it "rejects an SMask group stored in a form XObject" do
      form_id = builder.reserve
      smask_id = builder.reserve
      data = [255,0,0].pack("C*")
      content = image_dict(color_space: "/DeviceRGB", width: 1,
                           height: 1, bpc: 8,
                           extra: "/SMask #{smask_id} 0 R")
      image_id = builder.reserve
      resources = builder.page_resources({ Im1: image_id })
      contents = builder.draw_content([:Im1])
      pages_id = builder.reserve
      page_id = builder.add(builder.page(pages_id, resources, contents))
      builder.set(pages_id, builder.pages([page_id]))
      builder.add(builder.catalog(pages_id))

      builder.set(form_id, builder.stream(
        "/Type /XObject /Subtype /Form /BBox [0 0 1 1]", "", flate: false
      ))
      builder.set(smask_id, builder.dict("/S /Luminosity /G #{form_id} 0 R"))
      builder.set(image_id, builder.stream(content, data, flate: false))

      image = builder.first_page.images[:Im1]
      expect {
        image.rgba
      }.to raise_error(PDF::Reader::UnsupportedFeatureError, /form XObject/)
    end

    it "resamples an SMask with different dimensions" do
      # 4x1 image, 2x1 soft mask: opaque, transparent
      smask_id = builder.reserve
      data = [10,20,30, 10,20,30, 10,20,30, 10,20,30].pack("C*")
      content = image_dict(color_space: "/DeviceRGB", width: 4,
                           height: 1, bpc: 8,
                           extra: "/SMask #{smask_id} 0 R")
      image_id = builder.reserve
      resources = builder.page_resources({ Im1: image_id })
      contents = builder.draw_content([:Im1])
      pages_id = builder.reserve
      page_id = builder.add(builder.page(pages_id, resources, contents))
      builder.set(pages_id, builder.pages([page_id]))
      builder.add(builder.catalog(pages_id))

      smask = "/Type /XObject /Subtype /Image /Width 2 /Height 1 " \
              "/ColorSpace /DeviceGray /BitsPerComponent 8"
      builder.set(smask_id, builder.stream(smask, [255, 0].pack("C*"),
                                          flate: false))
      builder.set(image_id, builder.stream(content, data, flate: false))

      image = builder.first_page.images[:Im1]
      expect(image.rgba.bytes[3]).to eq 255
      expect(image.rgba.bytes[7]).to eq 255
      expect(image.rgba.bytes[11]).to eq 0
      expect(image.rgba.bytes[15]).to eq 0
    end

    it "resamples a 2x2 stencil mask onto a 4x4 image" do
      mask_id = builder.reserve
      data = [200,100,50].pack("C*") * 16
      content = image_dict(color_space: "/DeviceRGB", width: 4,
                           height: 4, bpc: 8,
                           extra: "/Mask #{mask_id} 0 R")
      image_id = builder.reserve
      resources = builder.page_resources({ Im1: image_id })
      contents = builder.draw_content([:Im1])
      pages_id = builder.reserve
      page_id = builder.add(builder.page(pages_id, resources, contents))
      builder.set(pages_id, builder.pages([page_id]))
      builder.add(builder.catalog(pages_id))

      mask = "/Type /XObject /Subtype /Image /ImageMask true " \
             "/Width 2 /Height 2 /BitsPerComponent 1"
      # mask rows: 10 (paint, transparent), 01 (transparent, paint)
      builder.set(mask_id, builder.stream(mask, [0b10000000, 0b01000000].pack("C*"),
                                         flate: false))
      builder.set(image_id, builder.stream(content, data, flate: false))

      image = builder.first_page.images[:Im1]
      # each 2x2 block of the 4x4 image samples one mask cell
      alphas = image.rgba.bytes.each_slice(4).map { |pixel| pixel[3] }
      expect(alphas).to eq [
        255, 255, 0,   0,
        255, 255, 0,   0,
        0,   0,   255, 255,
        0,   0,   255, 255,
      ]
    end

    it "uses the SMask instead of a colour key Mask when both are present" do
      smask_id = builder.reserve
      data = [255,0,0].pack("C*")
      content = image_dict(color_space: "/DeviceRGB", width: 1,
                           height: 1, bpc: 8,
                           extra: "/Mask [255 255 0 0 0 0] " \
                                   "/SMask #{smask_id} 0 R")
      image_id = builder.reserve
      resources = builder.page_resources({ Im1: image_id })
      contents = builder.draw_content([:Im1])
      pages_id = builder.reserve
      page_id = builder.add(builder.page(pages_id, resources, contents))
      builder.set(pages_id, builder.pages([page_id]))
      builder.add(builder.catalog(pages_id))

      smask = "/Type /XObject /Subtype /Image /Width 1 /Height 1 " \
              "/ColorSpace /DeviceGray /BitsPerComponent 8"
      builder.set(smask_id, builder.stream(smask, [128].pack("C*"),
                                          flate: false))
      builder.set(image_id, builder.stream(content, data, flate: false))

      image = builder.first_page.images[:Im1]
      # SMask wins: red pixel with alpha 128, despite matching colour key
      expect(image.rgba).to eq rgba_bytes(255, 0, 0, 128)
    end
  end

  describe "reuse across form XObjects" do
    it "decodes the same image identically from two forms" do
      data = [10, 20, 30, 40, 50, 60].pack("C*")
      image_id = builder.add(builder.stream(
        image_dict(color_space: "/DeviceRGB", width: 2, height: 1, bpc: 8),
        data
      ))
      form1_id = builder.form({ ImShared: image_id })
      form2_id = builder.form({ ImShared: image_id })

      resources = builder.dict(
        "/XObject << /F1 #{form1_id} 0 R /F2 #{form2_id} 0 R >>"
      )
      contents = builder.add(builder.stream(
        "", "q /F1 Do Q q /F2 Do Q", flate: false
      ))
      pages_id = builder.reserve
      page_id = builder.add(builder.page(pages_id, resources, contents))
      builder.set(pages_id, builder.pages([page_id]))
      builder.add(builder.catalog(pages_id))

      reader = PDF::Reader.new(builder.to_io)
      page = reader.page(1)

      form1 = PDF::Reader::FormXObject.new(page, page.xobjects[:F1])
      form2 = PDF::Reader::FormXObject.new(page, page.xobjects[:F2])
      expect(form1).to be_a PDF::Reader::FormXObject
      expect(form2).to be_a PDF::Reader::FormXObject

      image1 = form1.images[:ImShared]
      image2 = form2.images[:ImShared]
      expect(image1.rgba).to eq expected_rgba([
        [[10, 20, 30]],
        [[40, 50, 60]],
      ])
      expect(image2.rgba).to eq image1.rgba
      expect(page.images).to be_empty
    end

    it "exposes pixels independently of where the image is painted" do
      data = [7, 8, 9].pack("C*")
      image_id = builder.add(builder.stream(
        image_dict(color_space: "/DeviceRGB", width: 1, height: 1, bpc: 8),
        data
      ))
      # painted twice at different sizes/positions on one page
      resources = builder.dict("/XObject << /Im1 #{image_id} 0 R >>")
      contents_id = builder.add(builder.stream(
        "",
        "q 10 0 0 10 0 0 cm /Im1 Do Q q 5 0 0 5 20 40 cm /Im1 Do Q",
        flate: false
      ))
      pages_id = builder.reserve
      page_id = builder.add(builder.page(pages_id, resources, contents_id))
      builder.set(pages_id, builder.pages([page_id]))
      builder.add(builder.catalog(pages_id))

      image = builder.first_page.images[:Im1]
      expect(image.width).to eq 1
      expect(image.height).to eq 1
      expect(image.rgba).to eq rgba_bytes(7, 8, 9, 255)
    end
  end

  describe "filters and predictors" do
    it "decodes flate with a PNG predictor at 8 bits per component" do
      # RGB 2x1, PNG none-filter on the only row: filter byte 0 then data
      row = [0, 255,0,0, 255,0,255].pack("C*")
      data = Zlib::Deflate.deflate(row)
      content = image_dict(color_space: "/DeviceRGB", width: 2,
                           height: 1, bpc: 8,
                           extra: "/Filter /FlateDecode")
      image = single_image(
        builder, content, data, raw: true,
        decode_parms: "<</Predictor 15 /Colors 3 /Columns 2 /BitsPerComponent 8>>"
      )

      expect(image.rgba).to eq expected_rgba([
        [[255, 0, 0]],
        [[255, 0, 255]],
      ])
    end

    it "dereferences an indirect DecodeParms dictionary" do
      data = [123].pack("C*")
      parms_id = builder.add("<< /Predictor 1 /Colors 1 /Columns 1 >>")
      content = image_dict(color_space: "/DeviceGray", width: 1,
                           height: 1, bpc: 8,
                           extra: "/DecodeParms #{parms_id} 0 R")
      image = single_image(builder, content, data, flate: false)

      expect(image.rgba).to eq expected_rgba([[[123, 123, 123]]])
    end

    it "resolves a resource named colour space" do
      data = [255].pack("C*")
      image_id = builder.add(builder.stream(
        image_dict(color_space: "/Cs1", width: 1, height: 1, bpc: 8),
        data
      ))
      resources = builder.dict(
        "/XObject << /Im1 #{image_id} 0 R >> " \
        "/ColorSpace << /Cs1 /DeviceGray >>"
      )
      contents = builder.draw_content([:Im1])
      pages_id = builder.reserve
      page_id = builder.add(builder.page(pages_id, resources, contents))
      builder.set(pages_id, builder.pages([page_id]))
      builder.add(builder.catalog(pages_id))

      image = builder.first_page.images[:Im1]
      expect(image.rgba).to eq expected_rgba([[[255, 255, 255]]])
    end

    it "decodes an image compressed with RunLengthDecode" do
      # literal run of 6 bytes (length byte 5) followed by EOD (128)
      data = [5, 0, 0, 0, 255, 255, 255, 128].pack("C*")
      content = image_dict(color_space: "/DeviceRGB", width: 2,
                           height: 1, bpc: 8,
                           extra: "/Filter /RunLengthDecode")
      image = single_image(builder, content, data, raw: true)

      expect(image.rgba).to eq expected_rgba([
        [[0, 0, 0]],
        [[255, 255, 255]],
      ])
    end

    it "decodes an Indexed CMYK palette entry" do
      # palette: index 0 = cyan (1.0,0,0,0), index 1 = process black
      palette = [255,0,0,0, 0,0,0,255].pack("C*")
      color_space = "[/Indexed /DeviceCMYK 1 #{builder.hex(palette).b}]"
      data = [0b01000000].pack("C*")
      content = image_dict(color_space: color_space, width: 2,
                           height: 1, bpc: 1)
      image = single_image(builder, content, data)

      expect(image.indexed_base).to eq :DeviceCMYK
      expect(image.rgba).to eq expected_rgba([
        [[0, 255, 255]],
        [[0, 0, 0]],
      ])
    end
  end

  describe "unsupported and malformed input" do
    it "rejects a DCT (JPEG) encoded image" do
      content = image_dict(color_space: "/DeviceRGB", width: 1,
                           height: 1, bpc: 8, extra: "/Filter /DCTDecode")
      expect {
        image = single_image(builder, content, "jpeg bytes", raw: true)
        image.rgba
      }.to raise_error(PDF::Reader::UnsupportedFeatureError, /DCTDecode/)
    end

    it "rejects an ICCBased colour space" do
      content = image_dict(color_space: "[/ICCBased 9 0 R]", width: 1,
                           height: 1, bpc: 8)
      expect {
        single_image(builder, content, "x")
      }.to raise_error(PDF::Reader::UnsupportedFeatureError, /ICCBased/)
    end

    it "rejects a 16 bit Indexed image" do
      palette = [0,0,0].pack("C*")
      color_space = "[/Indexed /DeviceRGB 0 #{builder.hex(palette).b}]"
      content = image_dict(color_space: color_space, width: 1,
                           height: 1, bpc: 16)
      expect {
        single_image(builder, content, [0,0].pack("C*"))
      }.to raise_error(PDF::Reader::UnsupportedFeatureError, /16 bit Indexed/)
    end

    it "rejects a stencil image without colour for RGBA decoding" do
      data = [0xFF].pack("C*")
      content = "/Type /XObject /Subtype /Image /ImageMask true " \
                "/Width 1 /Height 1 /BitsPerComponent 1"
      image_id = builder.add(builder.stream(content, data, flate: false))
      resources = builder.page_resources({ Im1: image_id })
      contents = builder.draw_content([:Im1])
      pages_id = builder.reserve
      page_id = builder.add(builder.page(pages_id, resources, contents))
      builder.set(pages_id, builder.pages([page_id]))
      builder.add(builder.catalog(pages_id))

      image = builder.first_page.images[:Im1]
      expect(image.stencil?).to eq true
      expect {
        image.rgba
      }.to raise_error(PDF::Reader::UnsupportedFeatureError, /stencil/)
    end

    it "does not treat trailing bytes as RGB samples" do
      # 1x1 RGB needs 3 bytes; provide an extra byte
      content = image_dict(color_space: "/DeviceRGB", width: 1,
                           height: 1, bpc: 8)
      image = single_image(builder, content, [1, 2, 3, 4].pack("C*"))
      expect {
        image.rgba
      }.to raise_error(PDF::Reader::MalformedPDFError, /bytes/)
    end

    it "rejects a truncated stream" do
      content = image_dict(color_space: "/DeviceRGB", width: 2,
                           height: 1, bpc: 8)
      image = single_image(builder, content, [1, 2].pack("C*"))
      expect {
        image.rgba
      }.to raise_error(PDF::Reader::MalformedPDFError, /bytes/)
    end

    it "tolerates a single trailing EOL before endstream" do
      # PDF 7.3.8.1 allows one trailing EOL to be counted in the stream
      content = image_dict(color_space: "/DeviceRGB", width: 1,
                           height: 1, bpc: 8)
      image = single_image(builder, content, [10, 20, 30, 13].pack("C*"))

      expect(image.rgba).to eq rgba_bytes(10, 20, 30, 255)
    end

    it "still rejects two trailing non-EOL bytes" do
      content = image_dict(color_space: "/DeviceRGB", width: 1,
                           height: 1, bpc: 8)
      image = single_image(builder, content, [10, 20, 30, 0, 0].pack("C*"))
      expect {
        image.rgba
      }.to raise_error(PDF::Reader::MalformedPDFError, /bytes/)
    end

    it "rejects a malformed Decode array" do
      content = image_dict(color_space: "/DeviceRGB", width: 1,
                           height: 1, bpc: 8, extra: "/Decode [0 1]")
      image = single_image(builder, content, [1, 2, 3].pack("C*"))
      expect {
        image.rgba
      }.to raise_error(PDF::Reader::MalformedPDFError, /Decode/)
    end

    it "rejects a colour key Mask with the wrong number of values" do
      content = image_dict(color_space: "/DeviceRGB", width: 1,
                           height: 1, bpc: 8, extra: "/Mask [0 255 0 255]")
      image = single_image(builder, content, [1, 2, 3].pack("C*"))
      expect {
        image.rgba
      }.to raise_error(PDF::Reader::MalformedPDFError, /Mask/)
    end

    it "rejects an explicit mask that is not a 1 bit image" do
      mask_id = builder.reserve
      data = [123].pack("C*")
      content = image_dict(color_space: "/DeviceGray", width: 1,
                           height: 1, bpc: 8,
                           extra: "/Mask #{mask_id} 0 R")
      image_id = builder.reserve
      resources = builder.page_resources({ Im1: image_id })
      contents = builder.draw_content([:Im1])
      pages_id = builder.reserve
      page_id = builder.add(builder.page(pages_id, resources, contents))
      builder.set(pages_id, builder.pages([page_id]))
      builder.add(builder.catalog(pages_id))
      mask = "/Type /XObject /Subtype /Image /ImageMask true " \
             "/Width 1 /Height 1 /BitsPerComponent 8"
      builder.set(mask_id, builder.stream(mask, data, flate: false))
      builder.set(image_id, builder.stream(content, data, flate: false))

      image = builder.first_page.images[:Im1]
      expect {
        image.rgba
      }.to raise_error(PDF::Reader::MalformedPDFError, /1 bit/)
    end

    it "rejects a non-device SMask colour space" do
      smask_id = builder.reserve
      data = [255,0,0].pack("C*")
      content = image_dict(color_space: "/DeviceRGB", width: 1,
                           height: 1, bpc: 8,
                           extra: "/SMask #{smask_id} 0 R")
      image_id = builder.reserve
      resources = builder.page_resources({ Im1: image_id })
      contents = builder.draw_content([:Im1])
      pages_id = builder.reserve
      page_id = builder.add(builder.page(pages_id, resources, contents))
      builder.set(pages_id, builder.pages([page_id]))
      builder.add(builder.catalog(pages_id))
      smask = "/Type /XObject /Subtype /Image /Width 1 /Height 1 " \
              "/ColorSpace /DeviceRGB /BitsPerComponent 8"
      builder.set(smask_id, builder.stream(smask, [1,2,3].pack("C*"),
                                          flate: false))
      builder.set(image_id, builder.stream(content, data, flate: false))

      image = builder.first_page.images[:Im1]
      expect {
        image.rgba
      }.to raise_error(PDF::Reader::UnsupportedFeatureError, /DeviceGray/)
    end

    it "rejects a predictor with sub-byte samples" do
      content = image_dict(color_space: "/DeviceGray", width: 2,
                           height: 1, bpc: 1,
                           extra: "/DecodeParms " \
                                   "<</Predictor 15 /Columns 2 /Colors 1>>")
      expect {
        single_image(builder, content, [0b00000000].pack("C*"))
      }.to raise_error(PDF::Reader::UnsupportedFeatureError, /predictor/)
    end
  end
end

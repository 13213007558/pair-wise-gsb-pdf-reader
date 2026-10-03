# coding: utf-8
# typed: strict
# frozen_string_literal: true

class PDF::Reader
  # A mask (explicit stencil mask or soft mask) decoded in its native
  # dimensions before it is resampled onto the parent image grid.
  #
  class ImageMaskGrid
    #: Integer
    attr_reader :width

    #: Integer
    attr_reader :height

    #: Array[Integer]
    attr_reader :values

    #: (Integer, Integer, Array[Integer]) -> void
    def initialize(width, height, values)
      @width = width
      @height = height
      @values = values
    end

    #: (Integer, Integer) -> Integer
    def [](column, row)
      @values.fetch(row * width + column)
    end
  end

  # Decode an image XObject (a stream dictionary with +Subtype: /Image+) into
  # raw RGBA pixel samples.
  #
  # The raw +stream+ of an image XObject is *not* a ready to use array of
  # pixels. It may be compressed, split into packed samples of fewer than 8
  # bits per component, indexed into a colour palette, painted through one or
  # more masks, and interpreted through a +Decode+ array. This class takes
  # care of all of that for the image and colour space combinations that the
  # library can decode without an external PDF renderer:
  #
  # * Colour spaces: +DeviceGray+, +DeviceRGB+, +DeviceCMYK+ and
  #   +Indexed+ variants of the three device spaces.
  # * Samples: 1, 2, 4, 8 and 16 bits per component.
  # * Filters: any sequence of the general purpose filters the library knows
  #   how to reverse (Flate, LZW, RunLength, ASCIIHex and ASCII85),
  #   including the PNG and TIFF predictors used with Flate/LZW at 8 bits
  #   per component.
  # * Transparency: colour key +Mask+ arrays, explicit stencil masks and
  #   +SMask+ soft masks, including masks whose dimensions differ from the
  #   image, which are resampled with nearest neighbour interpolation.
  #
  # Any combination that cannot be decoded faithfully (JPEG/JBIG2/JPX/CCITT
  # data, ICCBased/Cal/Separation/DeviceN colour spaces, soft mask groups
  # embedded in a form XObject, 16 bit Indexed samples, etc) raises an
  # UnsupportedFeatureError. Malformed source data raises a
  # MalformedPDFError. Remaining bytes in a stream are never guessed to be
  # pixels: if the decoded stream does not contain exactly the number of
  # bytes the image dictionary describes, decoding fails rather than
  # inventing colour channels.
  #
  # == Output layout
  #
  # The decoded pixels are exposed through #rgba as a binary +String+ of
  # +width * height * 4+ bytes in RGBA order. The pixels are stored in the
  # order defined by the PDF file: the first pixel is the first sample row
  # of the image, rows run left to right and top to bottom. Each channel is
  # an 8 bit value (0-255).
  #
  # This object only describes the pixels of the image itself. It does not
  # know where, at what size, or how many times the image is painted on a
  # page. That information comes from the page content stream (the +Do+
  # operator and the active transformation matrix) and is deliberately kept
  # separate from image decoding.
  #
  # == Colour conversion conventions
  #
  # Samples are first mapped with the image +Decode+ array onto the 0.0 to
  # 1.0 range defined by the colour space. 1, 2, 4, 8 and 16 bit samples are
  # all expanded to 8 bit output channels.
  #
  # +DeviceGray+ values are copied to the red, green and blue channels.
  #
  # +DeviceRGB+ values are copied directly to the red, green and blue
  # channels.
  #
  # +DeviceCMYK+ is converted with the simple, profile independent
  # conversion documented in the "Conversion Among Device Color Spaces"
  # appendix of the PDF 1.7 specification, which assumes the standard
  # subtractive process colour model:
  #
  #   R = 1.0 - min(1.0, C + K)
  #   G = 1.0 - min(1.0, M + K)
  #   B = 1.0 - min(1.0, Y + K)
  #
  # When no ICC profile is supplied, CMYK rendering is device dependent in
  # PDF; this conversion deliberately performs no colour management and
  # will not match a calibrated RIP. CMYK image streams are frequently
  # produced with inverted (additive style) samples and a +Decode+ array of
  # +[1 0 1 0 1 0 1 0]+; honouring the +Decode+ array, as required by the
  # specification, normalises those streams before the conversion above.
  #
  # +Indexed+ samples index an 8 bit lookup table in the underlying device
  # colour space; the looked up colour is then converted with the rules
  # above. With the default Decode, each indexed sample selects the palette
  # entry of the same number (no rescaling); a custom +Decode+ array remaps
  # raw samples onto lookup indices before the lookup.
  #
  # == Transparency conventions
  #
  # A colour key +Mask+ marks a pixel fully transparent when every raw (pre
  # +Decode+) component falls inside the corresponding inclusive mask range.
  # An explicit stencil mask marks a pixel transparent where its (possibly
  # +Decode+ reversed) 1 bit sample does not paint. An +SMask+ supplies a
  # per-pixel coverage value derived from its grayscale samples. Explicit
  # masks and soft masks are resampled with nearest neighbour interpolation
  # when their dimensions differ from the image. When an +SMask+ is present
  # it replaces any +Mask+ entry, as specified by the PDF standard.
  class ImageXObject

    #: Array[Symbol]
    SUPPORTED_FILTERS = [
      :FlateDecode, :Fl,
      :LZWDecode, :LZW,
      :RunLengthDecode, :RL,
      :ASCIIHexDecode, :AHx,
      :ASCII85Decode, :A85,
    ].freeze

    #: Hash[Symbol, Integer]
    COMPONENTS = {
      :DeviceGray => 1,
      :DeviceRGB  => 3,
      :DeviceCMYK => 4,
    }.freeze

    #: [Integer, Integer, Integer, Integer, Integer]
    VALID_BITS = [1, 2, 4, 8, 16].freeze

    #: Array[Symbol]
    PREDICTOR_FILTERS = [:FlateDecode, :Fl, :LZWDecode, :LZW].freeze

    # the number of samples in each row of the image
    #: Integer
    attr_reader :width

    # the number of rows in the image
    #: Integer
    attr_reader :height

    # the number of bits used for each colour component sample (1, 2, 4, 8
    # or 16)
    #: Integer
    attr_reader :bits_per_component

    # the family of the image colour space as a PDF name, e.g. :DeviceRGB,
    # :DeviceCMYK, :DeviceGray or :Indexed
    #: Symbol
    attr_reader :color_space
    alias colour_space color_space

    # for an :Indexed image, the family of the colour space the lookup
    # table is defined in (:DeviceGray, :DeviceRGB or :DeviceCMYK). Nil for
    # non-indexed images.
    #: Symbol?
    attr_reader :indexed_base

    # the raw PDF::Reader::Stream this object was built from
    #: PDF::Reader::Stream
    attr_reader :xobject

    # Create a new decoder.
    #
    # +xobject+ may be a PDF::Reader::Stream, a PDF::Reader::Reference or
    # an object id that resolves to an image stream. +objects+ is the
    # PDF::Reader::ObjectHash for the document and is used to dereference
    # the colour space, masks and other indirect objects. +color_spaces+ is
    # the resolved +ColorSpace+ resource dictionary in scope where the image
    # is painted (from the page or form XObject), allowing the image to
    # name a resource based colour space.
    #
    #: (untyped, objects: PDF::Reader::ObjectHash, color_spaces: Hash[Symbol, untyped]) -> void
    def initialize(xobject, objects:, color_spaces: {})
      @objects = objects #: PDF::Reader::ObjectHash
      @resource_color_spaces = color_spaces #: Hash[Symbol, untyped]
      @xobject = deref_stream!(xobject) #: PDF::Reader::Stream
      @dict = @xobject.hash #: Hash[Symbol, untyped]

      read_dictionary
      validate_dictionary
    end

    #: () -> void
    def read_dictionary
      @width = integer!(:Width) #: Integer
      @height = integer!(:Height) #: Integer
      @bits_per_component = integer!(:BitsPerComponent) #: Integer
      @color_space = :DeviceGray #: Symbol
      @indexed_base = nil #: Symbol?
      @palette = nil #: String?
      @hival = -1 #: Integer
      @color_space, @indexed_base, @palette, @hival = parse_color_space
      @rgba = nil #: String?
      @decode_pairs = nil #: Array[[Float, Float]]?
      @color_key = nil #: Array[[Integer, Integer]]?
      @explicit_grid = nil #: Array[Integer]?
      @soft_grid = nil #: Array[Integer]?
      @explicit_loaded = false #: bool
      @soft_loaded = false #: bool
      @custom_index_decode = false #: bool
    end

    # Decode the stream and return the pixels as a binary String of
    # +width * height * 4+ bytes in RGBA order (top-left to bottom-right).
    #
    #: () -> String
    def rgba
      @rgba ||= build_rgba
    end
    alias to_rgba rgba

    # true when the image is a stencil (1 bit mask painted in the current
    # graphics state colour) rather than a colour image
    #
    #: () -> bool
    def stencil?
      @dict[:ImageMask] == true
    end

    # true when the image uses an :Indexed colour space
    #
    #: () -> bool
    def indexed?
      @color_space == :Indexed
    end

    # the number of colour components stored by each sample (1, 3 or 4).
    # For an indexed image this is always 1 (the palette index).
    #
    #: () -> Integer
    def components
      indexed? ? 1 : COMPONENTS.fetch(@color_space)
    end

    private

    # Raise early for combinations we do not decode, so callers get a
    # clear error rather than garbled pixels.
    #
    #: () -> void
    def validate_dictionary
      validate_image_shape
      validate_stencil if stencil?
      validate_indexed if indexed?
      validate_filters
    end

    #: () -> void
    def validate_image_shape
      unless @dict[:Subtype] == :Image
        raise MalformedPDFError,
          "expected an Image XObject, got #{@dict[:Subtype].inspect}"
      end
      if width < 1 || height < 1
        raise MalformedPDFError, "image Width/Height must be positive"
      end
      unless VALID_BITS.include?(bits_per_component)
        raise MalformedPDFError,
          "unsupported BitsPerComponent #{bits_per_component}"
      end
    end

    #: () -> void
    def validate_stencil
      unless bits_per_component == 1
        raise MalformedPDFError, "ImageMask must use 1 bit per sample"
      end
      if @dict.key?(:ColorSpace) || @dict.key?(:SMask)
        raise MalformedPDFError,
          "ImageMask must not define a ColorSpace or SMask"
      end
    end

    #: () -> void
    def validate_indexed
      if bits_per_component == 16
        raise UnsupportedFeatureError, "16 bit Indexed images are not supported"
      end
      if @hival < 0 || @palette.nil?
        raise MalformedPDFError,
          "Indexed colour space needs a valid Hival and lookup table"
      end
    end

    #: () -> void
    def validate_filters
      filters.each do |name|
        unless SUPPORTED_FILTERS.include?(name)
          raise UnsupportedFeatureError,
            "image filter #{name.inspect} is not supported"
        end
      end
      validate_predictors
    end

    # The bundled PNG/TIFF predictor implementation only reverses 8 bit
    # samples; reject anything else explicitly rather than mis-decoding it.
    # A single DecodeParms dictionary applies to the final filter.
    #
    #: () -> void
    def validate_predictors
      decode_param_hashes.each_with_index do |entry, index|
        next if entry.nil? || entry[:Predictor].to_i <= 1

        validate_predictor_filter!(index)
        if bits_per_component != 8
          raise UnsupportedFeatureError,
            "predictors are only supported for 8 bit samples"
        end
      end
    end

    #: (Integer) -> void
    def validate_predictor_filter!(index)
      filter = filters.length == 1 ? filters.first : filters[index]
      return if filter && PREDICTOR_FILTERS.include?(filter)

      raise UnsupportedFeatureError,
        "predictors are only supported with Flate or LZW filters"
    end

    #: () -> ([Symbol, Symbol, String, Integer] | [Symbol, nil, nil, Integer])
    def parse_color_space
      return [:DeviceGray, nil, nil, -1] if stencil?

      space = resolve_color_space(@dict[:ColorSpace])
      if space.nil?
        raise MalformedPDFError, "image is missing a ColorSpace"
      end
      classify_color_space(space)
    end

    #: (untyped) -> ([Symbol, Symbol, String, Integer] | [Symbol, nil, nil, Integer])
    def classify_color_space(space)
      family = (space.is_a?(Array) ? space[0] : space).to_sym
      if family == :Indexed || family == :I
        parse_indexed_color_space(space)
      elsif COMPONENTS.key?(family)
        [family, nil, nil, -1]
      else
        raise UnsupportedFeatureError,
          "unsupported image colour space #{family.inspect}"
      end
    end

    # Resolve a colour space value, following a resource name (e.g. /CS1)
    # into the page/form resource dictionary when needed.
    #
    #: (untyped) -> untyped
    def resolve_color_space(space)
      if space.is_a?(Symbol) && @resource_color_spaces.key?(space)
        @resource_color_spaces[space]
      else
        @objects.deref(space)
      end
    end

    #: (untyped) -> [Symbol, Symbol, String, Integer]
    def parse_indexed_color_space(space)
      unless space.is_a?(Array) && space.length >= 4
        raise MalformedPDFError, "malformed Indexed colour space"
      end
      base = indexed_base_family(space[1])
      hival = space[2]
      palette = lookup_palette(space[3])
      validate_indexed_parts!(base, hival, palette)

      [:Indexed, base, palette, hival]
    end

    #: (untyped) -> Symbol
    def indexed_base_family(value)
      base = @objects.deref(value)
      base = base[0] if base.is_a?(Array)
      base.to_sym
    end

    #: (Symbol, untyped, untyped) -> void
    def validate_indexed_parts!(base, hival, palette)
      unless COMPONENTS.key?(base)
        raise UnsupportedFeatureError,
          "Indexed colour space on #{base.inspect} is not supported"
      end
      unless hival.is_a?(Integer) && hival >= 0 && palette.is_a?(String)
        raise MalformedPDFError, "malformed Indexed colour space"
      end
    end

    # An Indexed lookup table is normally a string but may also be an
    # indirect stream containing the table bytes.
    #
    #: (untyped) -> String?
    def lookup_palette(value)
      dereferenced = @objects.deref(value)
      if dereferenced.is_a?(PDF::Reader::Stream)
        dereferenced.unfiltered_data
      elsif dereferenced.is_a?(String)
        dereferenced
      end
    end

    #: (Symbol) -> Integer
    def integer!(key)
      value = @objects.deref_integer(@dict[key])
      raise MalformedPDFError, "image is missing #{key}" if value.nil?

      value
    end

    #: (untyped) -> PDF::Reader::Stream
    def deref_stream!(xobject)
      stream = @objects.deref_stream(xobject)
      raise MalformedPDFError, "expected an Image XObject stream" if stream.nil?

      stream
    end

    #: () -> String
    def build_rgba
      raise UnsupportedFeatureError,
        "stencil (ImageMask) images have no intrinsic colour and cannot " \
        "be decoded to RGBA" if stencil?

      data = decode_stream(@xobject)
      expected = row_bytes(width, components, bits_per_component) * height
      data = expected_sample_data(data, expected)
      raw = unpack_components(data, width, height, components, bits_per_component)
      emit_pixels(raw)
    end

    # The stream bytes must describe exactly the image samples, except that
    # PDF 7.3.8.1 permits a single EOL sequence immediately before
    # endstream to be counted as part of the stream. Strip that one EOL and
    # reject any other surplus bytes so trailing data is never read as RGB.
    #
    #: (String, Integer) -> String
    def expected_sample_data(data, expected)
      return data if data.bytesize == expected

      trimmed = strip_stream_eol(data)
      verify_length!(trimmed, expected)
      trimmed
    end

    #: (String) -> String
    def strip_stream_eol(data)
      if data.end_with?("\r\n")
        data.byteslice(0, data.bytesize - 2)
      elsif data.end_with?("\n") || data.end_with?("\r")
        data.chop
      else
        data
      end
    end

    #: (String, Integer) -> void
    def verify_length!(data, expected)
      return if data.bytesize == expected

      raise MalformedPDFError,
        "decoded image stream is #{data.bytesize} bytes but " \
        "#{expected} bytes were expected"
    end

    #: (Array[Integer]) -> String
    def emit_pixels(raw)
      output = String.new
      output.force_encoding(::Encoding::BINARY)
      stencil = explicit_grid
      soft = soft_grid
      pairs = decode_pairs

      (width * height).times do |pixel|
        values = raw[pixel * components, components]
        output << pixel_rgb(values, pairs)
        output << alpha_for(pixel, values, stencil, soft).chr
      end

      output
    end

    #: (Integer, Array[Integer], Array[Integer]?, Array[Integer]?) -> Integer
    def alpha_for(pixel, values, stencil, soft)
      return soft[pixel] if soft
      return 0 if stencil && stencil[pixel] == 0
      return 0 if color_key_match?(values)

      255
    end

    #: (Array[Integer], Array[[Float, Float]]) -> String
    def pixel_rgb(values, pairs)
      if indexed?
        parts = palette_components(index_for(values[0], pairs[0]))
        device_rgb(parts, @indexed_base)
      else
        normalised = values.each_with_index.map { |value, index|
          normalise(value, pairs[index], bits_per_component)
        }
        device_rgb(normalised, @color_space)
      end
    end

    #: (Array[Float], Symbol) -> String
    def device_rgb(parts, family)
      rgb_components(parts, family).pack("CCC")
    end

    #: (Array[Float], Symbol) -> Array[Integer]
    def rgb_components(parts, family)
      case family
      when :DeviceGray
        gray = to_byte(parts[0])
        [gray, gray, gray]
      when :DeviceRGB
        parts.map { |value| to_byte(value) }
      when :DeviceCMYK
        cmyk_to_rgb(parts)
      else
        raise UnsupportedFeatureError,
          "unsupported image colour space #{family.inspect}"
      end
    end

    #: (Array[Float]) -> Array[Integer]
    def cmyk_to_rgb(parts)
      cyan, magenta, yellow, black = parts
      [
        1.0 - [1.0, cyan + black].min,
        1.0 - [1.0, magenta + black].min,
        1.0 - [1.0, yellow + black].min,
      ].map { |value| to_byte(value) }
    end

    #: (Float) -> Integer
    def to_byte(value)
      (clamp_float(value, 0.0, 1.0) * 255.0).round
    end

    #: (Float, Float, Float) -> Float
    def clamp_float(value, low, high)
      return low if value < low
      return high if value > high

      value
    end

    #: (Integer, [Float, Float], Integer) -> Float
    def normalise(sample, pair, bpc)
      low, high = pair
      denominator = bpc == 16 ? 65535.0 : ((1 << bpc) - 1).to_f
      low + sample.to_f * (high - low) / denominator
    end

    #: () -> Array[[Float, Float]]
    def decode_pairs
      @decode_pairs ||= build_decode_pairs
    end

    #: () -> Array[[Float, Float]]
    def build_decode_pairs
      decoded = @objects.deref_array_of_numbers(@dict[:Decode])
      if decoded.nil?
        @custom_index_decode = false
        return default_decode_pairs
      end
      @custom_index_decode = true

      if decoded.length != components * 2
        raise MalformedPDFError,
          "Decode array must have #{components * 2} numbers"
      end

      decoded.each_slice(2).map { |pair| [pair[0].to_f, pair[1].to_f] }
    end

    #: () -> Array[[Float, Float]]
    def default_decode_pairs
      indexed? ? [[0.0, @hival.to_f]] : Array.new(components) { [0.0, 1.0] }
    end

    # Map an indexed sample through the indexed Decode array to a palette
    # index. The default Decode for Indexed colour spaces maps each sample
    # value directly to the palette index of the same number (PDF 1.7
    # 8.9.5.2), so the general Decode interpolation (which would compress
    # the indices into Hival) only applies when a custom Decode is given.
    #
    #: (Integer, [Float, Float]) -> Integer
    def index_for(sample, pair)
      return clamp_index(sample) unless @custom_index_decode

      low, high = pair
      denominator = ((1 << bits_per_component) - 1).to_f
      index = (low + sample.to_f * (high - low) / denominator).round
      clamp_index(index)
    end

    #: (Integer) -> Integer
    def clamp_index(index)
      return 0 if index < 0
      return @hival if index > @hival

      index
    end

    # Palette colour for an index as normalised 0.0-1.0 device components.
    #
    #: (Integer) -> Array[Float]
    def palette_components(index)
      count = COMPONENTS.fetch(@indexed_base)
      offset = index * count
      entries = @palette.to_s
      verify_palette_length!(entries, offset + count, index)
      palette_bytes(entries, offset, count)
    end

    #: (String, Integer, Integer) -> void
    def verify_palette_length!(entries, needed, index)
      return if entries.bytesize >= needed

      raise MalformedPDFError,
        "Indexed lookup table is too short for index #{index}"
    end

    #: (String, Integer, Integer) -> Array[Float]
    def palette_bytes(entries, offset, count)
      entries.byteslice(offset, count).bytes.map { |byte| byte / 255.0 }
    end

    # Number of bytes one row occupies after filtering but before samples
    # are unpacked. Rows of sub-byte samples are padded to a byte boundary.
    #
    #: (Integer, Integer, Integer) -> Integer
    def row_bytes(image_width, component_count, bpc)
      (image_width * component_count * bpc + 7) / 8
    end

    # Extract packed, big endian component samples into a flat array of
    # integer values, row by row.
    #
    #: (String, Integer, Integer, Integer, Integer) -> Array[Integer]
    def unpack_components(data, image_width, image_height, component_count, bpc)
      samples = []
      bytes_per_row = row_bytes(image_width, component_count, bpc)

      image_height.times do |row|
        (image_width * component_count).times do |sample|
          samples << read_sample(data, row * bytes_per_row, sample, bpc)
        end
      end

      samples
    end

    #: (String, Integer, Integer, Integer) -> Integer
    def read_sample(data, row_start, sample, bpc)
      start_bit = sample * bpc
      first_byte = row_start + (start_bit / 8)
      offset = start_bit % 8

      if bpc == 8
        data.getbyte(first_byte)
      elsif bpc == 16
        (data.getbyte(first_byte) << 8) | data.getbyte(first_byte + 1)
      else
        read_packed_sample(data, first_byte, offset, bpc)
      end
    end

    #: (String, Integer, Integer, Integer) -> Integer
    def read_packed_sample(data, first_byte, bit_offset, bpc)
      value = 0
      byte_index = first_byte
      bit = bit_offset
      bpc.times do
        value = (value << 1) | ((data.getbyte(byte_index) >> (7 - bit)) & 1)
        bit += 1
        if bit == 8
          bit = 0
          byte_index += 1
        end
      end
      value
    end

    #: () -> Array[Symbol]
    def filters
      Array(@dict[:Filter]).map(&:to_sym)
    end

    #: (PDF::Reader::Stream) -> Array[Symbol]
    def stream_filters(stream)
      Array(stream.hash[:Filter]).map(&:to_sym)
    end

    # Apply a stream's filters ourselves instead of calling
    # Stream#unfiltered_data, so indirect references inside DecodeParms are
    # dereferenced (the bundled method only handles a direct dictionary).
    #
    #: (PDF::Reader::Stream) -> String
    def decode_stream(stream)
      data = stream.data.dup
      parms = decode_param_hashes(stream)

      stream_filters(stream).each_with_index do |name, index|
        data = Filter.with(name, parms[index] || {}).filter(data)
      end

      data
    end

    #: (PDF::Reader::Stream) -> Array[Hash[Symbol, untyped]?]
    def decode_param_hashes(stream = @xobject)
      raw = @objects.deref(stream.hash[:DecodeParms])
      return [] if raw.nil?

      entries = raw.is_a?(Hash) ? [raw] : Array(raw)
      entries.map { |entry| decode_parm_hash(entry) }
    end

    #: (untyped) -> Hash[Symbol, untyped]?
    def decode_parm_hash(entry)
      return nil if entry.nil?
      hash = @objects.deref_hash(entry)
      raise MalformedPDFError, "DecodeParms must be dictionaries" if hash.nil?

      hash
    end

    # A colour key match requires every raw component to fall inside the
    # inclusive [min, max] range for that component.
    #
    #: (Array[Integer]) -> bool
    def color_key_match?(values)
      mask = color_key
      return false unless mask
      return false if mask.length != values.length

      values.each_with_index.all? { |value, index|
        low, high = mask[index]
        value >= low && value <= high
      }
    end

    #: () -> Array[[Integer, Integer]]?
    def color_key
      return nil if @dict.key?(:SMask)
      @color_key ||= parse_color_key(@dict[:Mask])
    end

    #: (untyped) -> Array[[Integer, Integer]]?
    def parse_color_key(mask)
      return nil if mask.nil?
      values = @objects.deref(mask)
      return nil unless values.is_a?(Array)
      validate_color_key!(values)
      values.each_slice(2).map { |pair| [pair[0].to_i, pair[1].to_i] }
    end

    #: (Array[untyped]) -> void
    def validate_color_key!(values)
      if values.any? { |value| !value.is_a?(Numeric) }
        raise MalformedPDFError, "malformed colour key Mask array"
      end
      if values.length != components * 2
        raise MalformedPDFError,
          "colour key Mask needs #{components * 2} numbers"
      end
    end

    # Explicit stencil mask on the parent image grid, or nil when there is
    # no explicit mask. Entries are 1 (paint) or 0 (transparent).
    #
    #: () -> Array[Integer]?
    def explicit_grid
      unless @explicit_loaded
        @explicit_loaded = true
        @explicit_grid = load_explicit_grid
      end
      @explicit_grid
    end

    #: () -> Array[Integer]?
    def load_explicit_grid
      return nil if @dict.key?(:SMask)
      mask = @dict[:Mask]
      return nil unless mask.is_a?(PDF::Reader::Reference) ||
        mask.is_a?(PDF::Reader::Stream)

      resample(decode_stencil(@objects.deref_stream(mask)))
    end

    # Decode a 1 bit stencil stream to coverage in its own dimensions.
    #
    #: (PDF::Reader::Stream) -> ImageMaskGrid
    def decode_stencil(stream)
      dict = stream.hash
      bpc = @objects.deref_integer(dict[:BitsPerComponent])
      validate_stencil_stream!(dict, bpc)
      mask_width = integer_from!(dict, :Width)
      mask_height = integer_from!(dict, :Height)
      data = decode_stream(stream)
      expected = row_bytes(mask_width, 1, 1) * mask_height
      data = expected_sample_data(data, expected)
      stencil_grid_from(data, mask_width, mask_height, stream)
    end

    #: (String, Integer, Integer, PDF::Reader::Stream) -> ImageMaskGrid
    def stencil_grid_from(data, mask_width, mask_height, stream)
      pairs = stencil_decode_pairs(stream)
      values = unpack_components(data, mask_width, mask_height, 1, 1)
      values.map! { |sample| stencil_paints?(sample, pairs) ? 1 : 0 }
      ImageMaskGrid.new(mask_width, mask_height, values)
    end

    #: (Hash[Symbol, untyped], Integer?) -> void
    def validate_stencil_stream!(dict, bpc)
      if dict[:Subtype] != :Image || bpc != 1 || dict.key?(:ColorSpace)
        raise MalformedPDFError,
          "explicit Mask must be a 1 bit image without a ColorSpace"
      end
      if dict.key?(:ImageMask) && dict[:ImageMask] != true
        raise MalformedPDFError, "Mask ImageMask flag must be true"
      end
    end

    #: (PDF::Reader::Stream) -> [[Float, Float]]
    def stencil_decode_pairs(stream)
      decoded = @objects.deref_array_of_numbers(stream.hash[:Decode])
      return [[1.0, 0.0]] if decoded.nil?

      [[decoded[0].to_f, decoded[1].to_f]]
    end

    #: (Integer, [[Float, Float]]) -> bool
    def stencil_paints?(sample, pairs)
      normalise(sample, pairs[0], 1) < 0.5
    end

    # Soft mask coverage on the parent image grid, or nil when there is no
    # soft mask. Entries are 0-255 alpha values.
    #
    #: () -> Array[Integer]?
    def soft_grid
      unless @soft_loaded
        @soft_loaded = true
        @soft_grid = load_soft_grid
      end
      @soft_grid
    end

    #: () -> Array[Integer]?
    def load_soft_grid
      smask = @objects.deref(@dict[:SMask])
      return nil if smask.nil?

      stream = soft_mask_stream(smask)
      grid = decode_soft_mask(stream)
      resample(grid)
    end

    # Validate a soft mask dictionary and return its grayscale image
    # stream. A bare grayscale image stream is accepted directly.
    #
    #: (untyped) -> PDF::Reader::Stream
    def soft_mask_stream(smask)
      return smask if smask.is_a?(PDF::Reader::Stream)
      unless smask.is_a?(Hash)
        raise MalformedPDFError, "SMask must be a stream or dictionary"
      end
      validate_soft_mask_dict!(smask)
      soft_mask_group(smask[:G])
    end

    #: (Hash[Symbol, untyped]) -> void
    def validate_soft_mask_dict!(smask)
      validate_smask_subtype!(smask[:S])
      validate_smask_backdrop!(smask[:BC])
      raise UnsupportedFeatureError, matte_message if smask.key?(:Matte)
    end

    #: (untyped) -> void
    def validate_smask_subtype!(subtype)
      return if subtype == :Luminosity || subtype == :Alpha

      raise UnsupportedFeatureError,
        "SMask subtype #{subtype.inspect} is not supported"
    end

    #: (untyped) -> void
    def validate_smask_backdrop!(backdrop)
      return unless backdrop
      return unless Array(backdrop).any? { |value| value.to_f != 0.0 }

      raise UnsupportedFeatureError,
        "non-default SMask backdrop colour is not supported"
    end

    #: () -> String
    def matte_message
      "SMask groups with a Matte entry are not supported"
    end

    #: (untyped) -> PDF::Reader::Stream
    def soft_mask_group(group_ref)
      group = @objects.deref(group_ref)
      unless group.is_a?(PDF::Reader::Stream) && group.hash[:Subtype] == :Image
        raise UnsupportedFeatureError,
          "SMask groups stored as form XObjects are not supported"
      end

      group
    end

    #: (PDF::Reader::Stream) -> ImageMaskGrid
    def decode_soft_mask(stream)
      dict = stream.hash
      bpc = @objects.deref_integer(dict[:BitsPerComponent])
      mask_width = integer_from!(dict, :Width)
      mask_height = integer_from!(dict, :Height)
      validate_soft_mask_stream!(dict, bpc, mask_width, mask_height)
      soft_grid_from(stream, mask_width, mask_height, bpc)
    end

    #: (PDF::Reader::Stream, Integer, Integer, Integer) -> ImageMaskGrid
    def soft_grid_from(stream, mask_width, mask_height, bpc)
      data = decode_stream(stream)
      expected = row_bytes(mask_width, 1, bpc) * mask_height
      data = expected_sample_data(data, expected)
      pairs = soft_decode_pairs(stream)
      samples = unpack_components(data, mask_width, mask_height, 1, bpc)
      values = samples.map { |sample| soft_coverage(sample, pairs[0], bpc) }
      ImageMaskGrid.new(mask_width, mask_height, values)
    end

    #: (Hash[Symbol, untyped], Symbol) -> Integer
    def integer_from!(dict, key)
      value = @objects.deref_integer(dict[key])
      raise MalformedPDFError, "mask is missing #{key}" if value.nil?

      value
    end

    #: (Integer, [Float, Float], Integer) -> Integer
    def soft_coverage(sample, pair, bpc)
      to_byte(normalise(sample, pair, bpc))
    end

    #: (Hash[Symbol, untyped], Integer?, Integer, Integer) -> void
    def validate_soft_mask_stream!(dict, bpc, mask_width, mask_height)
      if dict[:Subtype] != :Image || bpc.nil? || mask_width < 1 || mask_height < 1 ||
          !VALID_BITS.include?(bpc)
        raise MalformedPDFError,
          "SMask must be a valid grayscale Image XObject"
      end
      validate_soft_mask_contents!(dict)
    end

    #: (Hash[Symbol, untyped]) -> void
    def validate_soft_mask_contents!(dict)
      unless soft_mask_color_space(dict) == :DeviceGray
        raise UnsupportedFeatureError,
          "only DeviceGray SMask images are supported"
      end
      if dict.key?(:SMask) || dict[:ImageMask] == true
        raise UnsupportedFeatureError,
          "nested SMask or stencil soft masks are not supported"
      end
    end

    #: (Hash[Symbol, untyped]) -> Symbol?
    def soft_mask_color_space(dict)
      space = @objects.deref_name(dict[:ColorSpace])
      space
    end

    #: (PDF::Reader::Stream) -> [[Float, Float]]
    def soft_decode_pairs(stream)
      decoded = @objects.deref_array_of_numbers(stream.hash[:Decode])
      return [[0.0, 1.0]] if decoded.nil?

      [[decoded[0].to_f, decoded[1].to_f]]
    end

    # Resample a mask in its own dimensions onto the parent image grid
    # with nearest neighbour interpolation. PDF aligns the corners of the
    # mask and the image and samples at the centre of each image pixel.
    #
    #: (ImageMaskGrid) -> Array[Integer]
    def resample(grid)
      (height * width).times.map do |pixel|
        column = pixel % width
        row = (pixel / width)
        source_column = (((column + 0.5) * grid.width) / width).to_i
        source_row = (((row + 0.5) * grid.height) / height).to_i
        grid[source_column, source_row]
      end
    end
  end
end

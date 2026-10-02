# coding: utf-8
# typed: strict
# frozen_string_literal: true

################################################################################
#
# Copyright (C) 2008 James Healy (jimmy@deefa.com)
#
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the
# "Software"), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to
# the following conditions:
#
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
# LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
# OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
# WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
#
################################################################################

require 'pdf/reader/width_calculator'


class PDF::Reader
  # Represents a single font PDF object and provides some useful methods
  # for extracting info. Mainly used for converting text to UTF-8.
  #
  class Font
    #: type widthCalculator = (
    #|   PDF::Reader::WidthCalculator::TypeZero |
    #|   PDF::Reader::WidthCalculator::BuiltIn |
    #|   PDF::Reader::WidthCalculator::TypeOneOrThree |
    #|   PDF::Reader::WidthCalculator::TrueType |
    #|   PDF::Reader::WidthCalculator::Composite
    #| )

    #: Symbol?
    attr_accessor :subtype

    #: PDF::Reader::Encoding
    attr_accessor :encoding

    #: Array[PDF::Reader::Font]
    attr_accessor :descendantfonts

    #: PDF::Reader::CMap | nil
    attr_accessor :tounicode

    #: Array[Numeric]
    attr_reader :widths

    #: Integer?
    attr_reader :first_char

    #: Integer?
    attr_reader :last_char

    #: Symbol?
    attr_reader :basefont

    #: PDF::Reader::FontDescriptor?
    attr_reader :font_descriptor

    #: Array[Numeric]
    attr_reader :cid_widths

    #: Numeric
    attr_reader :cid_default_width

    # 0 = horizontal writing, 1 = vertical writing
    #
    #: Integer
    attr_reader :wmode

    # The WMode explicitly declared in this font dictionary, or nil when absent.
    #
    #: Integer?
    attr_reader :explicit_wmode

    #: Array[Numeric]
    attr_reader :cid_vertical_default

    #: (PDF::Reader::ObjectHash, Hash[Symbol, untyped]) -> void
    def initialize(ohash, obj)
      @ohash = ohash
      @tounicode = nil #: PDF::Reader::CMap | nil
      @descendantfonts = [] #: Array[PDF::Reader::Font]
      @widths = [] #: Array[Numeric]
      @first_char = nil #: Integer?
      @last_char = nil #: Integer?
      @basefont = nil #: Symbol?
      @font_descriptor = nil #: PDF::Reader::FontDescriptor?
      @cid_widths = [] #: Array[Numeric]
      @cid_default_width = 0 #: Numeric
      @cid_vertical_widths = [] #: Array[Numeric]
      @cid_vertical_default = PDF::Reader::CidVerticalWidths::DEFAULT_METRICS.dup #: Array[Numeric]
      @wmode = 0 #: Integer
      @explicit_wmode = nil #: Integer?
      @encoding = PDF::Reader::Encoding.new(:StandardEncoding) #: PDF::Reader::Encoding
      @cached_widths = {} #: Hash[Integer, Numeric]
      @cached_vertical_metrics = {} #: Hash[Integer, Array[Numeric]]
      @font_matrix = nil #: Array[Numeric] | nil

      extract_base_info(obj)
      extract_type3_info(obj)
      extract_descriptor(obj)
      extract_descendants(obj)
      resolve_wmode(obj)
      @width_calc = build_width_calculator #: widthCalculator
      @vertical_widths = build_vertical_widths #: PDF::Reader::CidVerticalWidths | nil
      @utf8_cache = {} #: Hash[Integer, String]
    end

    #: (Integer | String | Array[Integer | String]) -> String
    def to_utf8(params)
      if @tounicode
        if params.is_a?(Integer)
          cached = @utf8_cache[params]
          return cached unless cached.nil?
          result = to_utf8_via_cmap(params, @tounicode)
          @utf8_cache[params] = result
          result
        else
          to_utf8_via_cmap(params, @tounicode)
        end
      else
        to_utf8_via_encoding(params)
      end
    end

    #: (String) -> (Array[Integer | Float | String | nil] | nil)
    def unpack(data)
      data.unpack(encoding.unpack)
    end

    # looks up the specified codepoint and returns a value that is in (pdf)
    # glyph space, which is 1000 glyph units = 1 text space unit
    #: (Integer | String) -> Numeric
    def glyph_width(code_point)
      if code_point.is_a?(String)
        code_point = unpack_string_to_array_of_ints(code_point, encoding.unpack).first
        raise MalformedPDFError, "code point missing" if code_point.nil?
      end

      @cached_widths[code_point] ||= @width_calc.glyph_width(code_point)
    end

    # In most cases glyph width is converted into text space with a simple divide by 1000.
    #
    # However, Type3 fonts provide their own FontMatrix that's used for the transformation.
    #
    #: (Integer | String) -> Numeric
    def glyph_width_in_text_space(code_point)
      glyph_width_in_glyph_space = glyph_width(code_point)

      if @subtype == :Type3
        pt1 = font_matrix_transform(Point::ZERO_ZERO)
        pt2 = font_matrix_transform(Point.new(glyph_width_in_glyph_space, 0))
        (pt2.x - pt1.x).abs.round(2)
      else
        glyph_width_in_glyph_space / 1000.0
      end
    end

    # True when this font lays glyphs out vertically (CIDFont WMode = 1).
    #
    #: () -> bool
    def vertical?
      @wmode == 1
    end

    # Looks up the vertical metrics for the specified codepoint and returns
    # them in (pdf) glyph space, where 1000 glyph units = 1 text space unit.
    #
    # Only valid for CID fonts with WMode 1. Returns an array of:
    #
    #   [position_x, displacement_y, displacement_x]
    #
    # position_x is the x component of the position vector (the glyph's left
    # offset), displacement_y is the y component of the displacement vector
    # (the vertical advance) and displacement_x is the x component of the
    # displacement vector (normally 0).
    #
    #: (Integer | String) -> Array[Numeric]
    def glyph_vertical_metrics(code_point)
      if code_point.is_a?(String)
        code_point = unpack_string_to_array_of_ints(code_point, encoding.unpack).first
        raise MalformedPDFError, "code point missing" if code_point.nil?
      end

      @cached_vertical_metrics[code_point] ||= begin
        if @vertical_widths
          @vertical_widths[code_point]
        elsif @subtype == :Type0
          descendant = @descendantfonts.first
          descendant ? descendant.glyph_vertical_metrics(code_point) : nil
        else
          nil
        end
      end
    end

    # The vertical metrics for +code_point+ converted into text space.
    #
    # Returns [position_x, displacement_y, displacement_x], see
    # glyph_vertical_metrics().
    #
    #: (Integer | String) -> Array[Numeric]
    def glyph_vertical_metrics_in_text_space(code_point)
      glyph_vertical_metrics(code_point).map { |metric| metric / 1000.0 }
    end

    private

    # Only valid for Type3 fonts
    #
    # transforming (0,0) is a really common case, so optimise for it to
    # avoid unnecessary object allocations
    #
    #: (PDF::Reader::Point) -> PDF::Reader::Point
    def font_matrix_transform(pt)
      return pt if @font_matrix.nil?

      matrix = TransformationMatrix.new(
        @font_matrix[0] || 0, @font_matrix[1] || 0,
        @font_matrix[2] || 0, @font_matrix[3] || 0,
        @font_matrix[4] || 0, @font_matrix[5] || 0,
      )

      if pt.x == 0 && pt.y == 0
        Point.new(matrix.e, matrix.f)
      else
        Point.new(
          (matrix.a * pt.x) + (matrix.c * pt.y) + (matrix.e),
          (matrix.b * pt.x) + (matrix.d * pt.y) + (matrix.f)
        )
      end
    end

    #: (Symbol | String | nil) -> PDF::Reader::Encoding
    def default_encoding(font_name)
      case font_name.to_s
      when "Symbol" then
        PDF::Reader::Encoding.new(:SymbolEncoding)
      when "ZapfDingbats" then
        PDF::Reader::Encoding.new(:ZapfDingbatsEncoding)
      else
        PDF::Reader::Encoding.new(:StandardEncoding)
      end
    end

    #: () -> widthCalculator
    def build_width_calculator
      if @subtype == :Type0
        PDF::Reader::WidthCalculator::TypeZero.new(self)
      elsif @subtype == :Type1
        if @font_descriptor.nil?
          PDF::Reader::WidthCalculator::BuiltIn.new(self)
        else
          PDF::Reader::WidthCalculator::TypeOneOrThree .new(self)
        end
      elsif @subtype == :Type3
        PDF::Reader::WidthCalculator::TypeOneOrThree.new(self)
      elsif @subtype == :TrueType
        if @font_descriptor
          PDF::Reader::WidthCalculator::TrueType.new(self)
        else
          # A TrueType font that isn't embedded. Most readers look for a version on the
          # local system and fallback to a substitute. For now, we go straight to a substitute
          PDF::Reader::WidthCalculator::BuiltIn.new(self)
        end
      elsif @subtype == :CIDFontType0 || @subtype == :CIDFontType2
        PDF::Reader::WidthCalculator::Composite.new(self)
      else
        PDF::Reader::WidthCalculator::TypeOneOrThree.new(self)
      end
    end

    #: () -> PDF::Reader::CidVerticalWidths | nil
    def build_vertical_widths
      if @subtype == :CIDFontType0 || @subtype == :CIDFontType2
        PDF::Reader::CidVerticalWidths.new(@cid_vertical_default, @cid_vertical_widths)
      else
        nil
      end
    end

    #: (Hash[Symbol, untyped]) -> PDF::Reader::Encoding
    def build_encoding(obj)
      if obj[:Encoding].is_a?(Symbol)
        # one of the standard encodings, referenced by name
        # TODO pass in a standard shape, always a Hash
        PDF::Reader::Encoding.new(obj[:Encoding])
      elsif obj[:Encoding].is_a?(Hash) || obj[:Encoding].is_a?(PDF::Reader::Stream)
        PDF::Reader::Encoding.new(obj[:Encoding])
      elsif obj[:Encoding].nil?
        default_encoding(@basefont)
      else
        raise MalformedPDFError, "Unexpected type for Encoding (#{obj[:Encoding].class})"
      end
    end

    #: (Hash[Symbol, untyped]) -> void
    def extract_base_info(obj)
      @subtype  = @ohash.deref_name(obj[:Subtype])
      @basefont = @ohash.deref_name(obj[:BaseFont])
      @encoding = build_encoding(obj)
      @widths   = @ohash.deref_array_of_numbers(obj[:Widths]) || []
      @first_char = @ohash.deref_integer(obj[:FirstChar])
      @last_char = @ohash.deref_integer(obj[:LastChar])

      # CID Fonts are not required to have a W or DW entry, if they don't exist,
      # the default cid width = 1000, see Section 9.7.4.1 PDF 32000-1:2008 pp 269
      @cid_widths         = @ohash.deref_array(obj[:W])  || []
      @cid_default_width  = @ohash.deref_number(obj[:DW]) || 1000

      # WMode and vertical metrics only apply to CID fonts, see
      # Section 9.7.4.3 PDF 32000-1:2008 pp 271-272. They're extracted for
      # every font but are only consulted for CIDFont/Type0 combinations.
      @explicit_wmode     = @ohash.deref_integer(obj[:WMode])
      @wmode              = @explicit_wmode || 0
      @cid_vertical_widths = @ohash.deref_array(obj[:W2]) || []
      dw2 = @ohash.deref_array(obj[:DW2])
      @cid_vertical_default = PDF::Reader::CidVerticalWidths.default_metrics(dw2)

      if obj[:ToUnicode]
        # ToUnicode is optional for Type1 and Type3
        begin
          stream = @ohash.deref_stream(obj[:ToUnicode])
          if stream
            @tounicode = PDF::Reader::CMap.new(stream.unfiltered_data)
          end
        rescue PDF::Reader::MalformedPDFError => e
          # If ToUnicode exists but isn't a stream, lets pretend it didn't exist. We
          # can't do anything with it unless it's a stream with a CMap
          unless e.message == "expected object to be a Stream or nil"
            raise e
          end
        end
      end
    end

    #: (Hash[Symbol, untyped]) -> void
    def extract_type3_info(obj)
      if @subtype == :Type3
        @font_matrix = @ohash.deref_array_of_numbers(obj[:FontMatrix]) || [
          0.001, 0, 0, 0.001, 0, 0
        ]
      end
    end

    #: (Hash[Symbol, untyped]) -> void
    def extract_descriptor(obj)
      if obj[:FontDescriptor]
        # create a font descriptor object if we can, in other words, unless this is
        # a CID Font
        fd = @ohash.deref_hash(obj[:FontDescriptor]) || {}
        @font_descriptor = PDF::Reader::FontDescriptor.new(@ohash, fd)
      else
        @font_descriptor = nil
      end
    end

    #: (Hash[Symbol, untyped]) -> void
    def extract_descendants(obj)
      # per PDF 32000-1:2008 pp. 280 :DescendentFonts is:
      # A one-element array specifying the CIDFont dictionary that is the
      # descendant of this Type 0 font.
      if obj[:DescendantFonts]
        descendants = @ohash.deref_array(obj[:DescendantFonts]) || []
        @descendantfonts = descendants.map { |desc|
          PDF::Reader::Font.new(@ohash, @ohash.deref_hash(desc) || {})
        }
      else
        @descendantfonts = []
      end
    end

    # The writing mode of a Type0 font comes from its CIDFont descendant;
    # the descendant's WMode entry overrides any WMode in the Type0's
    # Encoding CMap. See Table 114/119, PDF 32000-1:2008.
    #
    # Identity-H and Identity-V are the only predefined CMaps we support
    # directly. A vertical CMap supplied as a stream is parsed for its WMode.
    #
    #: (Hash[Symbol, untyped]) -> void
    def resolve_wmode(obj)
      return unless @subtype == :Type0

      descendant = @descendantfonts.first

      if descendant
        # The CIDFont's WMode (default 0 when the key is absent) takes
        # precedence over the Type0 Encoding CMap's writing direction.
        @wmode = descendant.explicit_wmode || 0
      else
        @wmode = extract_encoding_cmap_wmode(obj) || 0
      end

      if @wmode == 1 && @descendantfonts.first.nil?
        raise UnsupportedFeatureError, "vertical Type0 font without a CIDFont descendant is unsupported"
      end
    end

    #: (Hash[Symbol, untyped]) -> Integer?
    def extract_encoding_cmap_wmode(obj)
      encoding = obj[:Encoding]
      case @ohash.deref(encoding)
      when :"Identity-H"
        0
      when :"Identity-V"
        1
      when Symbol
        # named CMaps other than Identity-H/V may be either horizontal or
        # vertical; we don't bundle their metrics, so refuse rather than
        # silently assuming horizontal layout
        raise UnsupportedFeatureError, "unsupported CMap #{@ohash.deref(encoding).inspect} for Type0 font"
      when PDF::Reader::Stream
        stream = @ohash.deref(encoding)
        PDF::Reader::CMap.new(stream.unfiltered_data).wmode
      end
    end

    #: (Integer | String | Array[Integer | String], PDF::Reader::CMap) -> String
    def to_utf8_via_cmap(params, cmap)
      case params
      when Integer
        cmap.decode(params).pack("U*")
      when String
        unpack_string_to_array_of_ints(params, encoding.unpack).flat_map { |code_point|
          cmap.decode(code_point)
        }.pack("U*")
      when Array
        params.collect { |param| to_utf8_via_cmap(param, cmap) }.join("")
      end
    end

    #: (Integer | String | Array[Integer | String]) -> String
    def to_utf8_via_encoding(params)
      if encoding.kind_of?(String)
        raise UnsupportedFeatureError, "font encoding '#{encoding}' currently unsupported"
      end

      case params
      when Integer
        encoding.int_to_utf8_string(params)
      when String
        encoding.to_utf8(params)
      when Array
        params.collect { |param| to_utf8_via_encoding(param) }.join("")
      end
    end

    #: (String, String) -> Array[Integer]
    def unpack_string_to_array_of_ints(unpack_me, unpack_arg)
      unpack_me.unpack(unpack_arg).map { |code_point|
        code_point = TypeCheck.cast_to_int!(code_point)
      }
    end
  end
end

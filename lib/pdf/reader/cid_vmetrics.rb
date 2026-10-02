# coding: utf-8
# typed: strict
# frozen_string_literal: true

class PDF::Reader
  # A Hash-like object that wraps the vertical metrics of a CID font (the DW2
  # and W2 entries) and gives us a nice way to query the metrics for specific
  # glyphs. Only relevant when the font is used with a CMap that specifies a
  # writing mode of 1 (vertical).
  #
  # Each metrics triple is [w1y, v1x, v1y]:
  #
  #   w1y - the vertical component of the displacement vector w1. The
  #         horizontal component is always 0
  #   v1x - the horizontal component of the position vector v. nil means
  #         "half the glyph width", which the consumer must fill in because
  #         it depends on the width of each individual glyph
  #   v1y - the vertical component of the position vector v
  #
  # DW2 holds the default metrics as [v1y, w1y] and defaults to [880, -1000].
  # W2 holds per-glyph overrides in the same two forms as the W array,
  # except each width is replaced by a [w1y v1x v1y] triple.
  #
  # See Section 9.7.4.3, PDF 32000-1:2008, pp 271
  class CidVMetrics

    DEFAULT_VY = 880 #: Integer
    DEFAULT_W1Y = -1000 #: Integer

    #: (Array[Numeric], Array[Numeric]) -> void
    def initialize(default, array)
      @default_vy  = default[0] || DEFAULT_VY   #: Numeric
      @default_w1y = default[1] || DEFAULT_W1Y  #: Numeric
      @metrics = parse_array(array.dup) #: Hash[Integer, Array[Numeric]]
    end

    # Returns the metrics triple for a cid, falling back to the default
    # metrics when the W2 array has no entry for it.
    #
    #: (Integer) -> Array[Numeric?]
    def [](cid)
      @metrics.fetch(cid) { [@default_w1y, nil, @default_vy] }
    end

    private

    #: (Array[untyped]) -> Hash[Integer, Array[Numeric]]
    def parse_array(array)
      metrics = {}
      params = []
      while array.size > 0
        params << array.shift

        if params.size == 2 && params.last.is_a?(Array)
          metrics.merge! parse_first_form(params.first.to_i, Array(params.last))
          params = []
        elsif params.size == 3
          metrics.merge! parse_second_form(params[0].to_i, params[1].to_i, params[2])
          params = []
        end
      end
      metrics
    end

    # this is the form 10 [[w1y v1x v1y] [w1y v1x v1y]] where the metrics of
    # index 10 are in the first triple, index 11 in the second, etc
    #
    #: (Integer, Array[Numeric]) -> Hash[Integer, Array[Numeric]]
    def parse_first_form(first, values)
      values.each_slice(3).with_index.inject({}) { |accum, (triple, idx)|
        accum[first + idx] = triple if triple.size == 3
        accum
      }
    end

    # this is the form 10 20 [w1y v1x v1y] where all indexes between 10 and
    # 20 share the same metrics
    #
    #: (Integer, Integer, untyped) -> Hash[Integer, Array[Numeric]]
    def parse_second_form(first, final, triple)
      if first > final
        raise MalformedPDFError, "CidVMetrics: #{first} must be less than #{final}"
      end

      return {} unless triple.is_a?(Array) && triple.size == 3

      (first..final).inject({}) { |accum, index|
        accum[index] = triple
        accum
      }
    end

  end
end

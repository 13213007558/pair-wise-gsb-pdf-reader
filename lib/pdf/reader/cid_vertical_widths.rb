# coding: utf-8
# typed: strict
# frozen_string_literal: true

class PDF::Reader
  # Wraps the W2 array of a vertical (WMode 1) CIDFont and provides lookup of
  # per-CID vertical metrics.
  #
  # The W2 array (Section 9.7.4.3, PDF 32000-1:2008, pp 272) has two forms:
  #
  #   c_first [ w_1y w_1x w_1w  w_2y w_2x w_2w ... ]
  #
  #   c_first c_last w_1y w_1x w_1w
  #
  # Each entry gives three glyph-space values:
  #
  # * w_y: the y component of the displacement vector (the vertical advance)
  # * w_x: the x component of the position vector (the glyph's left/right
  #        offset relative to the current text position)
  # * w_w: the x component of the displacement vector (a horizontal advance,
  #        normally 0 for ordinary vertical text)
  #
class CidVerticalWidths

  # The spec mandated default for DW2 is [880 -1000], meaning a position
  # vector of (w10, 0) = (880, 0) and a displacement vector of
  # (0, w11) = (0, -1000).
  DEFAULT_POSITION_X     = 880 #: Integer
  DEFAULT_DISPLACEMENT_Y = -1000 #: Integer

  # A single set of metrics in glyph space units: [position_x,
  # displacement_y, displacement_x]
  DEFAULT_METRICS = [DEFAULT_POSITION_X, DEFAULT_DISPLACEMENT_Y, 0].freeze #: Array[Integer]

  #: (Array[Numeric] | nil) -> Array[Numeric]
  def self.default_metrics(dw2)
    if dw2
      unless dw2.size == 2
        raise MalformedPDFError, "DW2 must contain exactly two numbers"
      end
      [dw2[0].to_f, dw2[1].to_f, 0]
    else
      DEFAULT_METRICS.dup
    end
  end

  # NOTE: default is an Array so lookup always returns an array of metrics,
  # even for CIDs with no explicit W2 entry.
  #
  #: (Array[Numeric], Array[Numeric]) -> void
  def initialize(default, array)
    @default = default #: Array[Numeric]
    @metrics = parse_array(default, array.dup) #: Hash[Integer, Array[Numeric]]
  end

  # Return the [position_x, displacement_y, displacement_x] metrics for the
  # requested CID, falling back to the DW2-derived defaults.
  #
  #: (Numeric) -> Array[Numeric]
  def [](cid)
    @metrics[cid.to_i]
  end

  private

  #: (Array[Numeric], Array[Numeric]) -> Hash[Integer, Array[Numeric]]
  def parse_array(default, array)
    metrics = Hash.new { |hash, cid| hash[cid] = default }
    params = []
    while array.size > 0
      params << array.shift

      if params.size == 2 && params.last.is_a?(Array)
        merge_first_form(metrics, params.first.to_i, Array(params.last))
        params = []
      elsif params.size == 5
        merge_second_form(
          metrics,
          params[0].to_i, params[1].to_i,
          params[2], params[3], params[4]
        )
        params = []
      end
    end
    metrics
  end

  # form: c_first [ w_1y w_1x w_1w  w_2y w_2x w_2w ... ]
  #
  #: (Hash[Integer, Array[Numeric]], Integer, Array[Numeric]) -> void
  def merge_first_form(metrics, first, values)
    unless values.size % 3 == 0
      raise MalformedPDFError, "W2 glyph metrics array must contain triples"
    end
    values.each_slice(3).with_index do |triple, index|
      metrics[first + index] = [triple[1], triple[0], triple[2]].map(&:to_f)
    end
  end

  # form: c_first c_last w_1y w_1x w_1w
  #
  #: (Hash[Integer, Array[Numeric]], Integer, Integer, Numeric, Numeric, Numeric) -> void
  def merge_second_form(metrics, first, final, displacement_y, position_x, displacement_x)
    if first > final
      raise MalformedPDFError, "CidVerticalWidths: #{first} must be less than #{final}"
    end

    entry = [position_x.to_f, displacement_y.to_f, displacement_x.to_f]
    (first..final).each do |cid|
      metrics[cid] = entry
    end
  end

end
end

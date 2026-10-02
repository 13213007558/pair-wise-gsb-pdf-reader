# coding: utf-8
# typed: strict
# frozen_string_literal: true

class PDF::Reader
  # There's no point rendering zero-width characters
  class ZeroWidthRunsFilter

    #: (Array[PDF::Reader::TextRun]) -> Array[PDF::Reader::TextRun]
    def self.exclude_zero_width_runs(runs)
      runs.reject do |run|
        if run.vertical?
          # vertical runs use width for the horizontal ink extent and
          # advance for the vertical movement; skip only invisible glyphs
          run.width == 0 && run.advance == 0
        else
          run.width == 0
        end
      end
    end
  end
end

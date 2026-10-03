# coding: utf-8
# typed: false
# frozen_string_literal: true

require "pdf/reader"

# Verified CCITT Group 3 / Group 4 encoded bit streams. The encoded constants
# are fixed T.4/T.6 fax codeword sequences and decode purely in Ruby; they
# were cross checked against a reference Group 3/Group 4 implementation for
# every run length 0..1728 in both colours. Pixel arrays below use 0 for
# white and 1 for black (the scanline convention before BlackIs1 handling).
describe PDF::Reader::Filter::CcittFax do
  let(:filter_class) { PDF::Reader::Filter::CcittFax }

  VECTORS = [
    ["group 3 all white row",
     { Columns: 8, Rows: 1, K: 0 }, "001980", ["00000000"]],
    ["group 3 seven white then black",
     { Columns: 8, Rows: 1, K: 0 }, "001f40", ["00000001"]],
    ["group 3 mixed multi run, two rows",
     { Columns: 16, Rows: 2, K: 0 }, "001c11c006a0",
     ["0000011111111100", "0000000000000000"]],
    ["group 3 long white run (128 columns)",
     { Columns: 128, Rows: 1, K: 0 }, "00191a80", ["0" * 128]],
    ["group 3 long black run (128 columns)",
     { Columns: 128, Rows: 1, K: 0 }, "001350c80dc0", ["1" * 128]],
    ["group 4 all white, three rows (vertical 0 then EOFB)",
     { Columns: 16, Rows: 3, K: -1 }, "e0020020",
     ["0" * 16, "0" * 16, "0" * 16]],
    ["group 4 horizontal and vertical over changing rows",
     { Columns: 8, Rows: 2, K: -1 }, "98a0020020",
     ["00000000", "00011100"]]
  ].freeze

  def bytes_from_hex(hex)
    [hex].pack("H*")
  end

  # Default output (BlackIs1 false) stores 1 for white and 0 for black.
  def default_bits(rows)
    rows.map { |line| line.chars.map { |c| c == "0" ? "1" : "0" }.join }
  end

  VECTORS.each do |name, options, hex, rows|
    describe name do
      let(:data) { bytes_from_hex(hex) }

      it "decodes to the expected packed sample bytes" do
        output = filter_class.new(options).filter(data)
        expect(output).to eql([default_bits(rows).join].pack("B*"))
      end

      it "produces one sample per column per row" do
        output = filter_class.new(options).filter(data)
        bits = output.unpack1("B*")
        width = options[:Columns]
        rows.each_with_index do |expected, index|
          samples = bits[(index * width), width].chars.map { |c| c == "1" ? 0 : 1 }
          expect(samples.join).to eql(expected)
        end
      end
    end
  end

  describe "BlackIs1" do
    let(:data) { bytes_from_hex("001f40") }

    it "defaults to 1 for white and 0 for black" do
      output = filter_class.new(Columns: 8, Rows: 1, K: 0).filter(data)
      expect(output.unpack1("B*")).to eql("11111110")
    end

    it "emits 1 for black when BlackIs1 is true" do
      output = filter_class.new(Columns: 8, Rows: 1, K: 0, BlackIs1: true).filter(data)
      expect(output.unpack1("B*")).to eql("00000001")
    end
  end

  describe "error reporting" do
    it "includes the 1 based row number when a run exceeds the line width" do
      data = bytes_from_hex("001f40")
      expect {
        filter_class.new(Columns: 1, Rows: 1, K: 0).filter(data)
      }.to raise_error(PDF::Reader::MalformedPDFError, /row 1\b/i)
    end

    it "raises MalformedPDFError when the data ends before a codeword completes" do
      data = bytes_from_hex("00000000000100")
      expect {
        filter_class.new(Columns: 8, Rows: 1, K: 0, EndOfBlock: false).filter(data)
      }.to raise_error(PDF::Reader::MalformedPDFError)
    end

    it "raises on an unrecognised run codeword with its bit location" do
      data = bytes_from_hex("000000000001")
      expect {
        filter_class.new(Columns: 8, Rows: 1, K: 0, EndOfBlock: false).filter(data)
      }.to raise_error(PDF::Reader::MalformedPDFError, /bit \d+/)
    end

    it "does not loop or read past the end on truncated 2D data" do
      # Group 4 stream that starts a vertical code but is cut short.
      data = bytes_from_hex("001")
      expect {
        Timeout.timeout(2) do
          filter_class.new(Columns: 8, Rows: 1, K: -1).filter(data)
        end
      }.to raise_error(PDF::Reader::MalformedPDFError)
    end
  end

  describe "parameters" do
    it "defaults Columns to 1728" do
      filter = filter_class.new({})
      expect(filter.default_columns).to eql(1728)
    end

    it "honours a custom Columns value independently of K" do
      data = bytes_from_hex("00191a80")
      output = filter_class.new(Columns: 128, Rows: 1, K: 0).filter(data)
      expect(output.unpack1("B*").length).to eql(128)
    end
  end
end

# coding: utf-8
# typed: strict
# frozen_string_literal: true

class PDF::Reader
  module Filter # :nodoc:
    # Pure Ruby decoder for the CCITTFaxDecode stream filter. Supports ITU-T T.4
    # Group 3 data (K = 0 is one dimensional, K > 0 mixes 1D and 2D rows) and
    # T.6 Group 4 data (K < 0, all two dimensional).
    class CcittFax
      # Mode independent two dimensional codewords.
      PASS = "0001"
      HORIZONTAL = "001"
      VERTICAL = {
        0  => "1",
        -1 => "010", 1 => "011",
        -2 => "00101", 2 => "00111",
        -3 => "0000100", 3 => "0000101",
      }.freeze
      VERTICAL_BY_CODE = VERTICAL.invert.freeze

      # : (?Hash[untyped, untyped]) -> void
      def initialize(options = {})
        @options = options
        @columns   = option(:Columns, 1728).to_i
        @rows      = option(:Rows, 0).to_i
        @k         = option(:K, 0).to_i
        @eol       = bool(:EndOfLine, false)
        @aligned   = bool(:EncodedByteAlign, false)
        @eob       = bool(:EndOfBlock, @k < 0 ? false : true)
        @black_is_1 = bool(:BlackIs1, false)
      end

      # Exposed for tests/diagnostics.
      # : () -> Integer
      def default_columns
        1728
      end

      # : (String) -> String
      def filter(data)
        # T.4 Group 3 data is bit stuffed; T.6 Group 4 data is not.
        reader = BitReader.new(data, @k != -1)
        reference = nil
        output_rows = []
        row_number = 0

        loop do
          break if @rows.positive? && row_number >= @rows

          unless reader.data_left?
            if @eob
              raise error(row_number, reader, "data is truncated before the end of block marker")
            end
            break
          end

          row, _two_dimensional =
            if @k == -1
              reader.align_to_byte! if @aligned
              if reader.starts_with?(BitReader::EOFB)
                reader.skip(BitReader::EOFB.length)
                reader.align_to_byte! if @aligned
                break
              end
              [decode_two_d_row(reader, reference, row_number), true]
            else
              decode_group3_row(reader, reference, row_number)
            end
          break if row.nil?

          output_rows << row
          reference = row
          row_number += 1
        end

        pack(output_rows)
      end

      private

      # Decode one Group 3 row, handling its leading marker (EOL plus the 1/0
      # dimension tag for K>0 data) and trailing fill/EOL.
      # : (BitReader, T::Array[Integer] | nil, Integer) -> [T::Array[Integer], T::Boolean]
      def decode_group3_row(reader, reference, row_number)
        two_dimensional = false

        # EncodedByteAlign: rows (including their leading marker) begin on a
        # raw byte boundary.
        reader.align_to_byte! if @aligned

        # Optional leading EOL marker. The first row of an unmarked K=0 stream
        # has none; EOL marked streams and every K>0 row after the initial 1D
        # row start with one.
        if reader.starts_with?(BitReader::EOL)
          reader.skip(BitReader::EOL.length)
          if reader.starts_with?(BitReader::EOL)
            # Return to control (RTC): signal end of the image by returning nil.
            return [nil, false]
          end
          two_dimensional = reader.next_bit! == 1 if @k.positive?
        elsif @eol
          raise error(row_number, reader, "expected an end-of-line marker")
        end

        row = if two_dimensional
                decode_two_d_row(reader, reference, row_number)
              else
                decode_one_d_row(reader, row_number)
              end

        # Trailing fill bits and EOL marker. Unmarked K=0 streams may omit the
        # marker entirely; consume it when present.
        had = has_eol_markers?(reader, row_number)
        reader.consume_fill_and_eol! if had

        [row, two_dimensional]
      end

      # : (BitReader, Integer) -> T::Boolean
      def has_eol_markers?(reader, row_number)
        @eol || @k.positive? || reader.fill_before_eol?
      end

      # : (Symbol, untyped) -> untyped
      def option(name, default)
        @options.key?(name) ? @options[name] : default
      end

      # : (Symbol, untyped) -> T::Boolean
      def bool(name, default)
        value = option(name, default)
        value == true || value == "true"
      end

      # : (Integer, BitReader, String) -> MalformedPDFError
      def error(row_number, reader, message)
        MalformedPDFError.new(
          "CCITT fax decoding error on row #{row_number + 1} at bit #{reader.raw_bit_pos}: #{message}"
        )
      end

      ##########################################################################
      # One dimensional row (T.4 modified Huffman)
      ##########################################################################

      #: (BitReader, Integer) -> T::Array[Integer]
      def decode_one_d_row(reader, row_number)
        row = []
        color = 0
        while row.length < @columns
          run = 0
          loop do
            kind, run_length = longest_code(reader,
              color.zero? ? WHITE_MAKEUP : BLACK_MAKEUP,
              color.zero? ? WHITE_TERMINATING_HASH : BLACK_TERMINATING_HASH) ||
              raise(error(row_number, reader,
                          "illegal #{color_name(color)} run code (not a valid T.4 Huffman code)"))
            run += run_length
            if kind == :terminating
              break
            end
          end
          if row.length + run > @columns
            raise error(row_number, reader,
                         "#{color_name(color)} run of #{run} pixels makes the row longer than #{@columns} columns")
          end
          run.times { row << color }
          color = 1 - color
        end
        row
      end

      #: (BitReader, Integer, Integer) -> Integer
      def read_run(reader, color, row_number)
        terminating = color.zero? ? WHITE_TERMINATING_HASH : BLACK_TERMINATING_HASH
        makeup      = color.zero? ? WHITE_MAKEUP      : BLACK_MAKEUP
        length = 0
        loop do
          kind, run_length = longest_code(reader, makeup, terminating) ||
            raise(error(row_number, reader,
                        "illegal #{color_name(color)} run code (not a valid T.4 Huffman code)"))
          length += run_length
          return length if kind == :terminating
        end
      end

      # Terminating and makeup codes share one prefix tree (a makeup code can be
      # a longer prefix of a terminating code), so the longest match wins.
      #: (BitReader, T::Hash[Integer, String], T::Hash[Integer, String]) -> [Symbol, Integer]?
      def longest_code(reader, makeup, terminating)
        best = nil
        [[makeup, :makeup], [terminating, :terminating]].each do |table, kind|
          table.each do |length, bits|
            # On an exact tie in code length a terminating code wins, since a
            # makeup code must always be followed by its own terminating code.
            if reader.starts_with?(bits)
              better = best.nil? || bits.length > best[2].length ||
                (bits.length == best[2].length && kind == :terminating)
              best = [kind, length, bits] if better
            end
          end
        end
        return nil unless best
        reader.skip(best[2].length)
        [best[0], best[1]]
      end

      ##########################################################################
      # Two dimensional row (T.4 K>0 and T.6 Group 4)
      ##########################################################################

      #: (BitReader, T::Array[Integer] | nil, Integer) -> T::Array[Integer]
      def decode_two_d_row(reader, reference, row_number)
        reference ||= Array.new(@columns, 0)
        row = Array.new(@columns)

        # Canonical T.4/T.6 two dimensional decoding. a0 is the reference
        # changing element on the coding line (start position of the run whose
        # colour is +color+); it begins at -1 (imaginary white pixel left of
        # the row). b1/b2 are changing elements on the reference line.
        a0 = -1
        color = 0

        while a0 < @columns
          b1 = find_b1(reference, a0, color)
          b2 = find_b2(reference, b1, color)

          if reader.starts_with?(PASS)
            reader.skip(PASS.length)
            if b2.nil?
              raise error(row_number, reader, "pass mode with no b2 reference edge")
            end
            place(row, a0 + 1, b2 - 1, color, reader, row_number)
            a0 = b2
          elsif reader.starts_with?(HORIZONTAL)
            reader.skip(HORIZONTAL.length)
            first  = read_run(reader, color, row_number)
            second = read_run(reader, 1 - color, row_number)
            # a1 is the edge after the first run, a2 the edge after the
            # second run (both are positions of the following pixel).
            a1 = a0 + 1 + first
            a2 = a1 + second
            placed = first + second
            if placed > @columns - (a0 + 1)
              raise error(row_number, reader,
                           "horizontal runs #{first}/#{second} overflow a #{@columns} column row")
            end
            place(row, a0 + 1, a1 - 1, color, reader, row_number)
            place(row, a1, a2 - 1, 1 - color, reader, row_number)
            a0 = a2
          else
            d = vertical_offset(reader, row_number)
            raise error(row_number, reader, "vertical offset without b1") if b1.nil?
            a1 = b1 + d
            if a1 < 0 || a1 > @columns || (a1 == @columns && !d.zero?)
              raise error(row_number, reader, "vertical edge at column #{a1} is outside the row")
            end
            place(row, a0 + 1, a1 - 1, color, reader, row_number) if a1 > a0
            place(row, a0 + 1, @columns - 1, color, reader, row_number) if a1 == @columns
            a0 = a1
            color = 1 - color
          end

          break if a0 >= @columns
        end

        row
      end

      # Fill coding-line columns +from+..+to+ (inclusive) with +color+.
      #: (T::Array[Integer], Integer, Integer, Integer, BitReader, Integer) -> void
      def place(row, from, to, color, reader, row_number)
        return if to < from
        if from < 0 || to >= @columns
          raise error(row_number, reader,
                       "2D run spans columns #{from}..#{to} outside a #{@columns} column row")
        end
        (from..to).each { |column| row[column] = color }
      end

      # b1: first reference changing element whose colour differs from the
      # coding run colour and whose position is strictly right of a0. Uses the
      # imaginary elements beyond the right edge of the line.
      #: (T::Array[Integer], Integer, Integer) -> Integer?
      def find_b1(reference, a0, color)
        wanted = 1 - color
        ((a0 + 1)...@columns).each do |column|
          previous = column.zero? ? 0 : reference[column - 1]
          return column if reference[column] == wanted && previous != wanted
        end
        # When no physical edge exists, T.6 defines imaginary changing
        # elements just past the right edge, one white and one black. The one
        # of the wanted colour is b1 (at column @columns).
        @columns
      end

      # b2: first reference changing element after b1 whose colour equals the
      # coding run colour (the next edge of the same colour as a0's run).
      #: (T::Array[Integer], Integer, Integer) -> Integer?
      def find_b2(reference, b1, color)
        return nil if b1.nil?
        ((b1 + 1)...@columns).each do |column|
          previous = reference[column - 1]
          return column if reference[column] == color && previous != color
        end
        # If b1 started the last run of the reference line and that run has the
        # opposite colour to the coding run, the imaginary edge at @columns is b2.
        b1_ends_run = (b1...@columns).all? { |c| reference[c] != color }
        b1_ends_run ? @columns : nil
      end

      #: (BitReader, Integer) -> Integer
      def vertical_offset(reader, row_number)
        VERTICAL_BY_CODE.each do |bits, offset|
          if reader.starts_with?(bits)
            reader.skip(bits.length)
            return offset
          end
        end
        raise error(row_number, reader,
                     "illegal 2D code (expected pass, horizontal or vertical mode)")
      end

      #: (Integer) -> String
      def color_name(color)
        color.zero? ? "white" : "black"
      end

      ##########################################################################
      # Pack samples, MSB first, one byte per 8 columns, rows byte aligned.
      ##########################################################################

      #: (T::Array[T::Array[Integer]]) -> String
      def pack(rows)
        stride = (@columns + 7) / 8
        bytes = String.new(encoding: ::Encoding::BINARY, capacity: rows.length * stride)
        rows.each do |row|
          byte = 0
          @columns.times do |column|
            pixel = row[column].to_i
            pixel = 1 - pixel unless @black_is_1
            byte |= pixel << (7 - (column % 8))
            if (column % 8) == 7 || column == @columns - 1
              bytes << byte.chr(::Encoding::BINARY)
              byte = 0
            end
          end
        end
        bytes
      end
    end
  end
end

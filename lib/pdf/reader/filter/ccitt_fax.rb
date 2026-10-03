# coding: utf-8
# typed: strict
# frozen_string_literal: true

class PDF::Reader
  module Filter # :nodoc:
    # Pure Ruby decoder for the PDF CCITTFaxDecode stream filter.
    #
    # Implements ITU-T T.4 one dimensional (G3, K == 0), T.4 two dimensional
    # (G3 2D, K > 0) and T.6 modified modified READ (G4, K < 0) decoding. The
    # PDF DecodeParms entries Columns, Rows, K, EndOfLine, EncodedByteAlign,
    # EndOfBlock and BlackIs1 are all honoured. Decoded samples are packed MSB
    # first with the final byte of every scan line zero padded.
    class CcittFax
      ########################################################################
      # Raised for every malformed bitstream. +row+ is the 1 based scan line,
      # +bit_position+ is the absolute 0 based offset into the encoded data and
      # +column+ is the pel position within the line when one is known.
      class MalformedFaxError < MalformedPDFError
        attr_reader :row, :bit_position, :column

        def initialize(message, row, bit_position, column = nil)
          @row = row
          @bit_position = bit_position
          @column = column
          location = "row #{row}, bit #{bit_position}"
          location << ", column #{column}" unless column.nil?
          super("Invalid CCITT fax data (#{location}): #{message}")
        end
      end

      EOL = '000000000001'  # T.4 end of line
      EOL_BITS = 12
      RTC = EOL * 6        # T.4 return to control
      EOFB = EOL * 2       # T.6 end of facsimile block

      # T.4 Table 2a, white run terminating codes
      WHITE_TERMINAL = {
        0 => "00110101",
        1 => "000111",
        2 => "0111",
        3 => "1000",
        4 => "1011",
        5 => "1100",
        6 => "1110",
        7 => "1111",
        8 => "10011",
        9 => "10100",
        10 => "00111",
        11 => "01000",
        12 => "001000",
        13 => "000011",
        14 => "110100",
        15 => "110101",
        16 => "101010",
        17 => "101011",
        18 => "0100111",
        19 => "0001100",
        20 => "0001000",
        21 => "0010111",
        22 => "0000011",
        23 => "0000100",
        24 => "0101000",
        25 => "0101011",
        26 => "0010011",
        27 => "0100100",
        28 => "0011000",
        29 => "00000010",
        30 => "00000011",
        31 => "00011010",
        32 => "00011011",
        33 => "00010010",
        34 => "00010011",
        35 => "00010100",
        36 => "00010101",
        37 => "00010110",
        38 => "00010111",
        39 => "00101000",
        40 => "00101001",
        41 => "00101010",
        42 => "00101011",
        43 => "00101100",
        44 => "00101101",
        45 => "00000100",
        46 => "00000101",
        47 => "00001010",
        48 => "00001011",
        49 => "01010010",
        50 => "01010011",
        51 => "01010100",
        52 => "01010101",
        53 => "00100100",
        54 => "00100101",
        55 => "01011000",
        56 => "01011001",
        57 => "01011010",
        58 => "01011011",
        59 => "01001010",
        60 => "01001011",
        61 => "00110010",
        62 => "00110011",
        63 => "00110100",
      }
      # T.4 Table 2b, black run terminating codes
      BLACK_TERMINAL = {
        0 => "0000110111",
        1 => "010",
        2 => "11",
        3 => "10",
        4 => "011",
        5 => "0011",
        6 => "0010",
        7 => "00011",
        8 => "000101",
        9 => "000100",
        10 => "0000100",
        11 => "0000101",
        12 => "0000111",
        13 => "00000100",
        14 => "00000111",
        15 => "000011000",
        16 => "0000010111",
        17 => "0000011000",
        18 => "0000001000",
        19 => "00001100111",
        20 => "00001101000",
        21 => "00001101100",
        22 => "00000110111",
        23 => "00000101000",
        24 => "00000010111",
        25 => "00000011000",
        26 => "000011001010",
        27 => "000011001011",
        28 => "000011001100",
        29 => "000011001101",
        30 => "000001101000",
        31 => "000001101001",
        32 => "000001101010",
        33 => "000001101011",
        34 => "000011010010",
        35 => "000011010011",
        36 => "000011010100",
        37 => "000011010101",
        38 => "000011010110",
        39 => "000011010111",
        40 => "000001101100",
        41 => "000001101101",
        42 => "000011011010",
        43 => "000011011011",
        44 => "000001010100",
        45 => "000001010101",
        46 => "000001010110",
        47 => "000001010111",
        48 => "000001100100",
        49 => "000001100101",
        50 => "000001010010",
        51 => "000001010011",
        52 => "000000100100",
        53 => "000000110111",
        54 => "000000111000",
        55 => "000000100111",
        56 => "000000101000",
        57 => "000001011000",
        58 => "000001011001",
        59 => "000000101011",
        60 => "000000101100",
        61 => "000001011010",
        62 => "000001100110",
        63 => "000001100111",
      }
      # T.4 make-up codes for 64..1728 pels
      WHITE_MAKEUP = {
        64 => "11011",
        128 => "10010",
        192 => "010111",
        256 => "0110111",
        320 => "00110110",
        384 => "00110111",
        448 => "01100100",
        512 => "01100101",
        576 => "01101000",
        640 => "01100111",
        704 => "011001100",
        768 => "011001101",
        832 => "011010010",
        896 => "011010011",
        960 => "011010100",
        1024 => "011010101",
        1088 => "011010110",
        1152 => "011010111",
        1216 => "011011000",
        1280 => "011011001",
        1344 => "011011010",
        1408 => "011011011",
        1472 => "010011000",
        1536 => "010011001",
        1600 => "010011010",
        1664 => "011000",
        1728 => "010011011",
      }
      BLACK_MAKEUP = {
        64 => "0000001111",
        128 => "000011001000",
        192 => "000011001001",
        256 => "000001011011",
        320 => "000000110011",
        384 => "000000110100",
        448 => "000000110101",
        512 => "0000001101100",
        576 => "0000001101101",
        640 => "0000001001010",
        704 => "0000001001011",
        768 => "0000001001100",
        832 => "0000001001101",
        896 => "0000001110010",
        960 => "0000001110011",
        1024 => "0000001110100",
        1088 => "0000001110101",
        1152 => "0000001110110",
        1216 => "0000001110111",
        1280 => "0000001010010",
        1344 => "0000001010011",
        1408 => "0000001010100",
        1472 => "0000001010101",
        1536 => "0000001011010",
        1600 => "0000001011011",
        1664 => "0000001100100",
        1728 => "0000001100101",
      }
      # T.4 Table 3a / T.6 common make-up codes for 1792..2560 pels
      COMMON_MAKEUP = {
        1792 => "00000001000",
        1856 => "00000001100",
        1920 => "00000001101",
        1984 => "000000010010",
        2048 => "000000010011",
        2112 => "000000010100",
        2176 => "000000010101",
        2240 => "000000010110",
        2304 => "000000010111",
        2368 => "000000011100",
        2432 => "000000011101",
        2496 => "000000011110",
        2560 => "000000011111",
      }

      # T.4 Table 3 / T.6 Table 1 two dimensional codes
      PASS_CODE       = '0001'
      HORIZONTAL_CODE = '001'
      VERTICAL = {
        '1'      => 0,
        '011'    => 1,
        '010'    => -1,
        '00011'  => 2,
        '00010'  => -2,
        '000011' => 3,
        '000010' => -3,
      }
      TWO_D_MAX_BITS = 7
      RUN_MAX_BITS   = 13

      def self.build_trie(hash)
        root = {}
        hash.each do |value, code|
          node = root
          code.each_char { |bit| node = (node[bit.to_i] ||= {}) }
          raise "duplicate CCITT code #{code}" if node.key?(:value)
          node[:value] = value
        end
        root
      end

      def self.run_trie(terminal, makeup)
        hash = {}
        terminal.each { |length, code| hash[[:terminal, length]] = code }
        makeup.each   { |length, code| hash[[:makeup, length]]   = code }
        COMMON_MAKEUP.each { |length, code| hash[[:makeup, length]] = code }
        build_trie(hash)
      end

      WHITE_RUN_CODES = run_trie(WHITE_TERMINAL, WHITE_MAKEUP)
      BLACK_RUN_CODES = run_trie(BLACK_TERMINAL, BLACK_MAKEUP)
      TWO_D_CODES     = build_trie(
        VERTICAL.invert.merge(:pass => PASS_CODE, :horizontal => HORIZONTAL_CODE)
      )

      # MSB-first cursor over the encoded bit string.
      class BitCursor
        attr_accessor :pos

        attr_reader :total_bits

        def initialize(data)
          @bytes = data.to_s.b
          @end = @bytes.bytesize * 8
          @total_bits = @end
          @pos = 0
        end

        def eof?
          @pos >= @end
        end

        def remaining
          [@end - @pos, 0].max
        end

        def at?(bits)
          return false if @pos + bits.length > @end
          bits.each_char.with_index do |ch, idx|
            byte = @bytes.getbyte((@pos + idx) >> 3)
            bit = (byte >> (7 - ((@pos + idx) & 7))) & 1
            return false unless bit == ch.to_i
          end
          true
        end

        def consume!(bits)
          @pos += bits.length
        end

        def read_bit!
          return nil if @pos >= @end
          byte = @bytes.getbyte(@pos >> 3)
          bit = (byte >> (7 - (@pos & 7))) & 1
          @pos += 1
          bit
        end

        def bit_at(absolute)
          return nil if absolute < 0 || absolute >= @end
          byte = @bytes.getbyte(absolute >> 3)
          (byte >> (7 - (absolute & 7))) & 1
        end

        # Walk a prefix trie. Returns [value, start_offset]; value is nil when
        # no complete code matches. Reading never runs past max_bits bits.
        def read_code!(trie, max_bits, _longest = false)
          # Prefix trie decode. All code sets are prefix free (the 2D codes
          # 001/H and 00010..00011/V(+-2) do not overlap), so a leaf is the
          # complete code and is returned immediately.
          start = @pos
          node = trie
          max_bits.times do
            bit = read_bit!
            return [nil, start] if bit.nil?
            node = node[bit]
            return [nil, start] if node.nil?
            return [node[:value], start] if node.key?(:value)
          end
          [nil, start]
        end
      end

      # Builds one decoded scan line, black pels stored as 1 internally.
      class ScanLine
        attr_reader :column

        def initialize(columns)
          @columns = columns
          @bytes = Array.new((columns + 7) / 8, 0)
          @column = 0
        end

        def write_run!(length, color, row_number, bit_position)
          finish = @column + length
          if finish > @columns
            color_name = color == 1 ? 'black' : 'white'
            raise MalformedFaxError.new("#{color_name} run of #{length} pels exceeds #{@columns} columns",
                                       row_number, bit_position, @column)
          end
          if color == 1
            while @column < finish
              @bytes[@column >> 3] |= (0x80 >> (@column & 7))
              @column += 1
            end
          else
            @column = finish
          end
        end

        def to_bytes
          @bytes.pack('C*')
        end

        # Changing element positions, always ending with a sentinel at the
        # right edge so the 2D decoder can find b1/b2 for every a0.
        def changes
          positions = []
          previous = 0
          @columns.times do |column|
            bit = (@bytes[column >> 3] >> (7 - (column & 7))) & 1
            positions << column if column.zero? ? bit == 1 : bit != previous
            previous = bit
          end
          positions << @columns unless positions.last == @columns
          positions
        end
      end

      #: (?Hash[untyped, untyped]) -> void
      def initialize(options = {})
        @options = options
        @columns   = int_option(:Columns, 1728)
        @rows      = int_option(:Rows, 0)
        @k         = int_option(:K, 0)
        @eol       = bool_option(:EndOfLine, false)
        @aligned   = bool_option(:EncodedByteAlign, false)
        @end_block = bool_option(:EndOfBlock, true)
        @black_is1 = bool_option(:BlackIs1, false)
        raise MalformedPDFError, 'CCITTFaxDecode Columns must be positive' unless @columns.positive?
        raise MalformedPDFError, 'CCITTFaxDecode Rows cannot be negative' if @rows.negative?
      end

      #: (String) -> String
      def filter(data)
        @bits = BitCursor.new(data)
        @row_number = 0
        @reference_changes = [@columns] # imaginary all-white reference line
        output = []

        loop do
          break if @rows.positive? && @row_number >= @rows

          dimension = begin_line!
          break if dimension == :end_of_block

          line = ScanLine.new(@columns)
          if dimension == :one_d
            decode_one_d!(line)
          else
            decode_two_d!(line)
          end
          output << line.to_bytes
          @reference_changes = line.changes
          @row_number += 1
        end

        pack(output)
      end

      private

      def int_option(name, default)
        value = @options.key?(name) ? @options[name] : default
        value.nil? ? default : Integer(value)
      end

      def bool_option(name, default)
        value = @options.key?(name) ? @options[name] : default
        value == true || value == 1
      end

      def group4?
        @k.negative?
      end

      def malformed(message, column = nil)
        MalformedFaxError.new(message, @row_number + 1, @bits.pos, column)
      end

      def raise_malformed(message, column = nil)
        raise malformed(message, column)
      end

      # Consume anything that precedes a scan line (fill, byte alignment,
      # EOL markers and tag bits) and report the kind of line that follows.
      def begin_line!
        return begin_group4_line! if group4?
        return begin_g3_2d_line!  if @k.positive?
        begin_g3_1d_line!
      end

      def begin_group4_line!
        # Group 4 has no per-line EOL; EOFB is the only marker. EncodedByteAlign
        # does not apply to T.6, so only the two-EOL end marker is recognised.
        if @bits.at?(EOFB)
          @bits.consume!(EOFB)
          return :end_of_block
        end
        if @bits.eof?
          return :end_of_block unless @end_block && @rows.positive? && @row_number < @rows
          raise malformed('truncated stream before 2D scan line')
        end
        :two_d
      end

      def begin_g3_1d_line!
        align_to_byte! if @aligned && @row_number.positive?
        skip_fill_to_eol!
        eols = consume_eols!
        return :end_of_block if eols >= 6

        if @bits.eof?
          # Ending on a fill/EOL boundary with no remaining row data is only
          # legal when the stream does not promise an explicit block marker or
          # when every expected row has already been decoded.
          if eols.positive? || !@end_block || @rows.zero? || @row_number >= @rows
            return :end_of_block
          end
          raise malformed('truncated stream before scan line data')
        end

        if eols.zero? && @row_number.positive? && @eol
          raise malformed('missing EndOfLine marker')
        end
        :one_d
      end

      def begin_g3_2d_line!
        align_to_byte! if @aligned && @row_number.positive?
        skip_fill_to_eol!
        eols = consume_eols!
        return :end_of_block if eols >= 6

        if eols.zero?
          if @row_number.zero?
            # T.4 2D streams may begin directly with the mandatory first 1D line.
            return :one_d
          end
          raise malformed('missing EOL marker before scan line')
        end

        if @bits.eof?
          return :end_of_block unless @end_block && @rows.positive? && @row_number < @rows
          raise malformed('truncated stream before 2D tag bit')
        end

        tag = @bits.read_bit!
        if tag.nil?
          raise malformed('truncated stream before 2D tag bit')
        end
        dimension = tag == 1 ? :one_d : :two_d
        align_to_byte! if @aligned && dimension == :two_d
        dimension
      end

      # T.4 fill: a run of zero bits (maximum 11) immediately preceding an EOL.
      # Without an EOL following, no bit is consumed so white run codes remain
      # intact.
      def skip_fill_to_eol!
        return if @bits.at?(EOL)
        # The scan line is fully decoded at this point. What follows is either
        # a run of T.4 fill zeros ending in an EOL, the EOL itself, or (in
        # tightly packed streams) the next line's Huffman data. Probe ahead by
        # walking the zero run: each suffix is tested for an EOL. The nearest
        # valid boundary wins; fill may be zero bits long. EOL's fixed bit
        # pattern cannot occur inside legal Huffman data.
        start = @bits.pos
        probe = start
        limit = start + 256
        while probe < limit && probe < @bits.total_bits
          if @bits.bit_at(probe) == 1
            @bits.pos = probe
            return if @bits.at?(EOL)
            break
          end
          probe += 1
          @bits.pos = probe
          return if @bits.at?(EOL)
        end
        @bits.pos = start
      end


      def align_to_byte!
        skipped = 0
        while (@bits.pos & 7) != 0
          start = @bits.pos
          bit = @bits.read_bit!
          if bit.nil?
            raise MalformedFaxError.new('truncated stream while aligning to a byte boundary',
                                        @row_number + 1, start)
          end
          unless bit.zero?
            raise MalformedFaxError.new('non-zero fill bit while aligning to a byte boundary',
                                        @row_number + 1, start)
          end
          skipped += 1
          raise malformed('too many EncodedByteAlign fill bits') if skipped > 7
        end
      end

      def consume_eols!
        count = 0
        while @bits.at?(EOL)
          @bits.consume!(EOL)
          count += 1
        end
        count
      end

      ########################################################################
      # T.4 section 3.2 modified Huffman (one dimensional) scan line.
      def decode_one_d!(line)
        color = 0 # a MH line always opens with a white run
        until line.column == @columns
          length, start = read_run_length!(color, line)
          line.write_run!(length, color, @row_number + 1, start)
          color ^= 1
        end
        # The line finished exactly at the right edge; any trailing bits belong
        # to fill/EOL handled by begin_line!.
      end

      # Read zero or more make-up codes followed by exactly one terminating
      # code for a run of the given color.
      def read_run_length!(color, line)
        trie = color.zero? ? WHITE_RUN_CODES : BLACK_RUN_CODES
        total = 0
        start = @bits.pos
        terminator = nil
        loop do
          value, code_start = @bits.read_code!(trie, RUN_MAX_BITS)
          if value.nil?
            if @bits.eof?
              raise MalformedFaxError.new("truncated stream while reading #{color.zero? ? 'white' : 'black'} run",
                                         @row_number + 1, code_start, line.column)
            end
            raise MalformedFaxError.new("invalid #{color.zero? ? 'white' : 'black'} run code",
                                       @row_number + 1, code_start, line.column)
          end
          kind, length = value
          total += length
          if kind == :terminal
            terminator = length
            break
          end
        end
        [total, start]
      end

      ########################################################################
      # T.4 annex 2 / T.6 section 2 two dimensional decoding.
      #
      # State:
      #   a0       - reference changing element on the coding line, -1 for
      #              the imaginary white pel before the line starts
      #   a0_color - color of the run beginning at a0 (0 white, 1 black)
      # Emitted pels form the run [a0..a1) in a0_color; pass and vertical
      # modes move a0 to a new changing element while horizontal mode emits
      # two complete runs.
      def decode_two_d!(line)
        # ITU-T T.6 (and T.4 2D) coding. State:
        #   a0        - current coding changing element; -1 is the imaginary
        #               white element one position before the strip;
        #   run_color - color of the a0a1 run immediately to the RIGHT of a0,
        #               the run that is painted next (0 white, 1 black).
        a0 = -1
        run_color = 0
        virtual_pending = false
        ref_floor = 0

        loop do
          mode, mode_start = @bits.read_code!(TWO_D_CODES, TWO_D_MAX_BITS)
          if mode.nil?
            raise MalformedFaxError.new(
              @bits.eof? ? 'truncated stream while reading 2D mode code' : 'invalid 2D mode code',
              @row_number + 1, mode_start, line.column)
          end

          case mode
          when :pass
            _b1, b2 = reference_pair(@reference_changes, a0, run_color, ref_floor)
            target = b2.nil? ? @columns : b2
            paint_2d(line, a0, run_color, target, mode_start)
            a0 = target
            # Pass preserves the a0a1 run color.
          when :horizontal
            first_length, first_start = read_run_length!(run_color, line)
            other_color = run_color ^ 1
            second_length, second_start = read_run_length!(other_color, line)
            paint_2d(line, a0, run_color, first_length, first_start)
            if line.column < @columns
              paint_2d(line, line.column, other_color, line.column + second_length, second_start)
            end
            a0 = line.column
            # Two runs were emitted; the next a0a1 run keeps run_color.
          else
            b1, = reference_pair(@reference_changes, a0, run_color, ref_floor)
            if b1.nil?
              raise MalformedFaxError.new('vertical mode references a changing element beyond the line',
                                         @row_number + 1, mode_start, line.column)
            end
            target = b1 + mode
            if target < 0 && a0 < 0
              # a1 lands on an imaginary element left of the strip.
              a0 = target
              virtual_pending = true
              ref_floor = b1 + 1
            else
              # A vertical code landing on the right edge once the line is
              # already full is the closing code and emits no more pels.
              unless line.column == @columns && target >= @columns
                paint_2d(line, a0, run_color, target, mode_start)
                if virtual_pending && target.zero? && line.column.zero?
                  line.write_run!(1, run_color, @row_number + 1, mode_start)
                end
              end
              a0 = target
              run_color ^= 1
              virtual_pending = false
              ref_floor = 0
            end
          end

          break if line.column == @columns
        end
      end

      # Paint +color+ pels from the current coding position up to column
      # +target+. A run that begins at the imaginary a0 (-1) starts painting at
      # column 0; runs that cross the right edge are clipped to the strip.
      def paint_2d(line, a0, color, target, bit_position)
        # Pels are emitted from the current fill column (line.column), never
        # from the abstract a0 position; a0 may sit at a virtual/edge element
        # while the buffer still starts at column 0.
        origin = line.column
        length = target - origin
        length = [length, @columns - origin].min
        line.write_run!(length, color, @row_number + 1, bit_position) if length.positive?
      end

      def reference_pair(changes, a0, run_color, floor = 0)
        # T.6, with colors of runs STARTING at changing elements:
        #   b1 is the first reference change right of a0 whose run has the
        #   color OPPOSITE to the coding run currently being emitted
        #   (run_color);
        #   b2 is the next change whose run has run_color again.
        # The reference conceptually extends past the right edge with an
        # imaginary run of the missing color, represented by the edge
        # sentinel at @columns.
        # When a0 sits on a virtual element left of the strip (negative), the
        # search still starts at column 0 but reference elements already
        # crossed by earlier virtual vertical codes must be skipped.
        first_pos = [a0 < 0 ? 0 : a0 + 1, floor].max
        after = changes.drop_while { |change| change < first_pos }
        b1_index = after.index do |change|
          change == @columns || color_starting_at(changes, change) != run_color
        end
        return [nil, nil] if b1_index.nil?
        b1 = after[b1_index]
        b2 = nil
        unless b1 == @columns
          b2 = after[(b1_index + 1)..].find do |change|
            change == @columns || color_starting_at(changes, change) == run_color
          end
        end
        [b1, b2]
      end

      # Color of the run that starts at a changing element position. The edge
      # sentinel starts an imaginary run of the color opposite the final real
      # run, which keeps T.6 b1/b2 searches well defined at line ends.
      def color_starting_at(changes, position)
        real = changes.reject { |change| change == @columns }
        if position == @columns
          return (real.length & 1) ^ 1
        end
        real.count { |change| change <= position } & 1
      end

      def pack(rows)
        data = rows.join
        data = data.each_byte.map { |byte| (byte ^ 0xFF).chr }.join unless @black_is1
        data
      end
    end
  end
end

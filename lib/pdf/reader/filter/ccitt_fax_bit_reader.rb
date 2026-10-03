# coding: utf-8
# typed: strict
# frozen_string_literal: true

class PDF::Reader
  module Filter # :nodoc:
    class CcittFax
      # Cursor over a pre-de-stuffed logical bit stream.
      #
      # Group 3 (T.4) inserts a zero after every five consecutive 1s within row
      # data; this zero is removed on read. The all-1 fill that precedes an EOL,
      # and the EOL/EOFB marker bits themselves, must never participate in that
      # run counting, so markers are recognised while building the logical
      # stream and the counter reset around them. Group 4 (T.6) is not stuffed.
      class BitReader
        EOL = "000000000001"
        EOFB = "000000000001000000000001"

        # : (String, T::Boolean) -> void
        def initialize(data, stuffed)
          raw = data.b.bytes
          @bits = []
          @raw_pos_of = []
          i = 0
          ones = 0
          while i < raw.size * 8
            # A T.3/T.4 EOL (or EOFB) can appear here, optionally preceded by
            # fill 1s. Copy the marker (and any preceding fill) verbatim and do
            # not let its bits affect the stuffing counter.
          marker = marker_at(raw, i)
          if marker
            length = marker
            length.times do |k|
                bit = raw_bit(raw, i + k)
                @bits << bit
                @raw_pos_of << i + k
              end
              i += length
              ones = 0
              next
            end

            bit = raw_bit(raw, i)
            if stuffed && bit.zero? && ones >= 5
              # Inserted T.4 stuffing zero: drop it.
              ones = 0
            else
              @bits << bit
              @raw_pos_of << i
              ones = bit == 1 ? ones + 1 : 0
            end
            i += 1
          end
          @pos = 0
        end

        # Raw encoded bit position of the next logical bit (for error messages).
        # : () -> Integer
        def raw_bit_pos
          if @pos >= @raw_pos_of.length
            @raw_pos_of.empty? ? 0 : @raw_pos_of[-1] + 1
          else
            @raw_pos_of[@pos]
          end
        end

        # De-stuffed logical bit position.
        # : () -> Integer
        attr_reader :pos

        # : () -> T::Boolean
        def data_left?
          @pos < @bits.length
        end

        # : () -> Integer
        def next_bit!
          raise MalformedPDFError, "CCITT data is truncated (ran out of encoded bits)" unless @pos < @bits.length
          bit = @bits[@pos]
          @pos += 1
          bit
        end

        # : (Integer) -> String?
        def peek(count)
          return nil if @pos + count > @bits.length
          @bits[@pos, count].join
        end

        # : (Integer) -> void
        def skip(count)
          if @pos + count > @bits.length
            raise MalformedPDFError, "CCITT data is truncated (ran out of encoded bits)"
          end
          @pos += count
        end

        # : (String) -> T::Boolean
        def starts_with?(pattern)
          peek(pattern.length) == pattern
        end

        # Consume an EOL positioned exactly at the cursor.
        # : () -> T::Boolean
        def consume_eol!
          return false unless starts_with?(EOL)
          @pos += EOL.length
          true
        end

        # Consume an optional fill run (1s) followed by an EOL. Fill length
        # zero is accepted first; otherwise a bounded run of fill 1s must lead
        # directly to the EOL. Returns false without moving for streams with
        # no EOL delimiters (K=0, EndOfLine false).
        # : () -> T::Boolean
        def consume_fill_and_eol!
          if starts_with?(EOL)
            @pos += EOL.length
            return true
          end
          fill = 0
          while fill < 13 && @pos + fill < @bits.length && @bits[@pos + fill] == 1
            fill += 1
            candidate = @pos + fill
            if candidate + EOL.length <= @bits.length &&
               @bits[candidate, EOL.length].join == EOL
              @pos = candidate + EOL.length
              return true
            end
          end
          false
        end

        # True when a fill run plus EOL begins at (or within 13 logical bits
        # after) the cursor. Does not move it.
        # : () -> T::Boolean
        def fill_before_eol?
          save = @pos
          found = starts_with?(EOL)
          unless found
            fill = 0
            while fill < 13 && @pos + fill < @bits.length && @bits[@pos + fill] == 1
              fill += 1
              candidate = @pos + fill
              if candidate + EOL.length <= @bits.length &&
                 @bits[candidate, EOL.length].join == EOL
                found = true
                break
              end
            end
          end
          @pos = save
          found
        end

        # : () -> T::Boolean
        def eofb?
          peek(24) == EOFB
        end

        # : () -> void
        def consume_eofb!
          @pos += 24
        end

        # Advance to the next raw byte boundary in the encoded data.
        # : () -> void
        def align_to_byte!
          while @pos < @raw_pos_of.length && (@raw_pos_of[@pos] % 8) != 0
            @pos += 1
          end
        end

        private

        # Raw bit at an absolute bit index.
        # : (Array, Integer) -> Integer
        def raw_bit(raw, index)
          byte = raw[index / 8]
          (byte >> (7 - (index % 8))) & 1
        end

        # Return the total length (including any leading all-1 fill) of an EOL
        # or EOFB marker beginning at +index+, or nil if none is present.
        # : (Array, Integer) -> Integer?
        def marker_at(raw, index)
          fill = 0
          while fill < 13 && index + fill < raw.size * 8 && raw_bit(raw, index + fill) == 1
            fill += 1
          end
          start = index + fill
          return nil if start >= raw.size * 8
          return nil unless raw_bit(raw, start).zero?
          if start + 24 <= raw.size * 8 && bits_equal?(raw, start, EOFB)
            return fill + 24
          end
          if start + 12 <= raw.size * 8 && bits_equal?(raw, start, EOL)
            return fill + 12
          end
          nil
        end

        # : (Array, Integer, String) -> T::Boolean
        def bits_equal?(raw, start, pattern)
          pattern.each_char.with_index.all? do |char, offset|
            raw_bit(raw, start + offset) == char.to_i
          end
        end
      end
    end
  end
end

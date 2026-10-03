# frozen_string_literal: true

require_relative '../../support/fax_fixtures'

describe PDF::Reader::Filter::CcittFax do
  include FaxFixtures

  def decode(bits, options)
    PDF::Reader::Filter::CcittFax.new(options).filter(pack(bits))
  end

  describe 'one dimensional Group 3 (K=0) modified Huffman' do
    it 'decodes a hand computed black and white scan line' do
      columns = 22
      pels = '0011000000000000001100'
      result = decode(mh_line(pels),
                      Columns: columns, Rows: 1, K: 0,
                      EndOfLine: false, EndOfBlock: false, BlackIs1: true)
      expect(result).to eql([pels].pack('B*'))
    end

    it 'decodes a fully white line through the W0 terminating code' do
      columns = 72
      result = decode(mh_line('0' * columns),
                      Columns: columns, Rows: 1, K: 0,
                      EndOfLine: false, EndOfBlock: false, BlackIs1: true)
      expect(result).to eql(("\x00" * 9).dup.force_encoding("ASCII-8BIT"))
    end

    it 'decodes a fully black line using make up plus B0' do
      columns = 72
      result = decode(mh_line('1' * columns),
                      Columns: columns, Rows: 1, K: 0,
                      EndOfLine: false, EndOfBlock: false, BlackIs1: true)
      expect(result).to eql(("\xFF" * 9).dup.force_encoding("ASCII-8BIT"))
    end

    it 'decodes a run longer than 64 pels with a make up code' do
      columns = 200
      pels = '0' * 100 + '1' * 100
      result = decode(mh_line(pels),
                      Columns: columns, Rows: 1, K: 0,
                      EndOfLine: false, EndOfBlock: false, BlackIs1: true)
      expect(result).to eql([pels].pack('B*'))
    end

    it 'decodes several tightly packed lines without FaxFixtures::EOL markers' do
      rows = ['00100000', '00110000', '00000000']
      bits = rows.map { |row| mh_line(row) }.join
      result = decode(bits,
                      Columns: 8, Rows: rows.length, K: 0,
                      EndOfLine: false, EndOfBlock: false, BlackIs1: true)
      expect(result.bytes).to eql(rows.map { |row| pels_to_byte(row).ord })
    end

    it 'does not treat FaxFixtures::EOL markers as data' do
      rows = ['00100000', '11111111', '00000000']
      bits = rows.map { |row| FaxFixtures::EOL + mh_line(row) }.join + (FaxFixtures::EOL * 6)
      result = decode(bits,
                      Columns: 8, Rows: rows.length, K: 0,
                      EndOfLine: true, EndOfBlock: true, BlackIs1: true)
      expect(result.bytes).to eql(rows.map { |row| pels_to_byte(row).ord })
    end

    it 'honours EncodedByteAlign fill between FaxFixtures::EOL and the next line' do
      first = mh_line('00100000')
      second = mh_line('00000000')
      # Fill zeros come before the EOL so that the EOL starts on a byte
      # boundary; EncodedByteAlign tells the decoder to skip the padding.
      prefix = FaxFixtures::EOL + first
      fill = (8 - ((prefix.length + 5) % 8)) % 8
      bits = prefix + ('0' * 5) + ('0' * fill) + FaxFixtures::EOL + second
      result = decode(bits,
                      Columns: 8, Rows: 2, K: 0,
                      EndOfLine: true, EncodedByteAlign: true,
                      EndOfBlock: true, BlackIs1: true)
      expect(result.bytes).to eql([pels_to_byte('00100000').ord, 0])
    end

    it 'inverts samples when BlackIs1 is false' do
      result = decode(mh_line('11111111'),
                      Columns: 8, Rows: 1, K: 0,
                      EndOfLine: false, EndOfBlock: false, BlackIs1: false)
      expect(result).to eql([0].pack("C"))
    end
  end

  describe 'error reporting' do
    it 'reports the 1 based row and bit position for an invalid white run' do
      expect {
        decode('111111111111',
               Columns: 8, Rows: 1, K: 0,
               EndOfLine: false, EndOfBlock: false, BlackIs1: true)
      }.to raise_error(PDF::Reader::Filter::CcittFax::MalformedFaxError) { |e|
        expect(e.row).to eql(1)
        expect(e.bit_position).to be_a(Integer)
        expect(e.message).to include('row 1')
        expect(e.message).to include('bit')
      }
    end

    it 'reports the column when a run exceeds the line width' do
      expect {
        decode(FaxFixtures::WHITE_TERMINAL[7] + FaxFixtures::BLACK_TERMINAL[2],
               Columns: 8, Rows: 1, K: 0,
               EndOfLine: false, EndOfBlock: false, BlackIs1: true)
      }.to raise_error(PDF::Reader::Filter::CcittFax::MalformedFaxError) { |e|
        expect(e.column).to eql(7)
        expect(e.message).to include('column')
      }
    end

    it 'raises a truncated data error when the stream ends mid codeword' do
      expect {
        decode('1001',
               Columns: 8, Rows: 1, K: 0,
               EndOfLine: false, EndOfBlock: true, BlackIs1: true)
      }.to raise_error(PDF::Reader::Filter::CcittFax::MalformedFaxError)
    end

    it 'does not loop reading past the end while searching for markers' do
      short = FaxFixtures::EOL + mh_line('00000000')
      result = decode(short,
                      Columns: 8, Rows: 1, K: 0,
                      EndOfLine: true, EndOfBlock: false, BlackIs1: true)
      expect(result).to eql([0].pack("C"))
    end
  end

  describe 'Group 4 two dimensional (K<0)' do
    pass_code = '0001'
    horizontal = '001'
    v0 = '1'
    vl1 = '010'
    vr1 = '011'
    let(:eofb) { FaxFixtures::EOL * 2 }

    it 'decodes a first coding line with horizontal mode' do
      bits = horizontal + FaxFixtures::WHITE_TERMINAL[2] + FaxFixtures::BLACK_TERMINAL[1] + v0 + eofb
      result = decode(bits,
                      Columns: 8, Rows: 1, K: -1,
                      EndOfBlock: true, BlackIs1: true)
      expect(result.bytes.first).to eql(pels_to_byte('00100000').ord)
    end

    it 'uses vertical V0 for unchanged changing elements' do
      first_row = horizontal + FaxFixtures::WHITE_TERMINAL[2] + FaxFixtures::BLACK_TERMINAL[1] + v0
      second_row = v0 + v0 + v0
      bits = first_row + second_row + eofb
      result = decode(bits,
                      Columns: 8, Rows: 2, K: -1,
                      EndOfBlock: true, BlackIs1: true)
      byte = pels_to_byte('00100000').ord
      expect(result.bytes).to eql([byte, byte])
    end

    it 'applies a vertical offset for a shifted changing element' do
      first_row = horizontal + FaxFixtures::WHITE_TERMINAL[2] + FaxFixtures::BLACK_TERMINAL[1] + v0
      second_row = vl1 + vl1 + v0
      bits = first_row + second_row + eofb
      result = decode(bits,
                      Columns: 8, Rows: 2, K: -1,
                      EndOfBlock: true, BlackIs1: true)
      expect(result.bytes[1]).to eql(pels_to_byte('01000000').ord)
    end

    it 'keeps an all white reference for the following line' do
      bits = v0 + v0 + eofb
      result = decode(bits,
                      Columns: 8, Rows: 2, K: -1,
                      EndOfBlock: true, BlackIs1: true)
      expect(result).to eql([0, 0].pack("C*"))
    end

    it 'decodes a pass mode that skips a reference black run' do
      first_row = horizontal + FaxFixtures::WHITE_TERMINAL[3] + FaxFixtures::BLACK_TERMINAL[1] + v0
      second_row = pass_code + v0
      bits = first_row + second_row + eofb
      result = decode(bits,
                      Columns: 8, Rows: 2, K: -1,
                      EndOfBlock: true, BlackIs1: true)
      expect(result.bytes).to eql([pels_to_byte('00010000').ord, 0])
    end
  end
end

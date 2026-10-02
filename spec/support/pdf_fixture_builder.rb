# typed: false
# coding: utf-8
# frozen_string_literal: true

require 'zlib'
require 'stringio'

# Minimal builder for in-memory PDFs used by the embedded files specs. Writes
# classic cross reference tables and supports arbitrary indirect objects.
class PdfFixtureBuilder
  HexString = Struct.new(:bytes) do
    def to_s
      "<#{bytes.unpack('H*').first}>"
    end
  end

  Raw = Struct.new(:content) do
    def to_s
      content
    end
  end

  attr_reader :objects

  def initialize(version: 1.6)
    @version = version
    @objects = {} # obj id => body string
  end

  # allocate and write an object with the next sequential id. Returns the new
  # object id.
  def add(body)
    id = (@objects.keys.max || 0) + 1
    @objects[id] = body
    id
  end

  def replace(id, body)
    @objects[id] = body
    id
  end

  def ref(id)
    PDF::Reader::Reference.new(id, 0)
  end

  # build a dictionary body from a Ruby Hash. Values are serialized with #pdf_value
  def dict(pairs)
    entries = pairs.map { |key, value| "/#{key} #{pdf_value(value)}" }.join(" ")
    "<< #{entries} >>"
  end

  def stream(pairs, data)
    if data.empty?
      "#{dict(pairs.merge(:Length => 0))}\nstream\nendstream"
    else
      "#{dict(pairs.merge(:Length => data.bytesize))}\nstream\n#{data}\nendstream"
    end
  end

  def flate_stream(pairs, data)
    compressed = Zlib.deflate(data)
    stream(pairs.merge(:Filter => :FlateDecode), compressed)
  end

  # a PDF text string encoded as UTF-16BE with BOM, as a hex string
  def utf16(text)
    HexString.new("\xFE\xFF".b + text.encode("UTF-16BE").b)
  end

  def hex(bytes)
    HexString.new(bytes.b)
  end

  def raw(content)
    Raw.new(content)
  end

  def pdf_value(value)
    case value
    when PDF::Reader::Reference then "#{value.id} #{value.gen} R"
    when Symbol                 then "/#{value}"
    when Integer, Float         then value.to_s
    when HexString, Raw         then value.to_s
    when Array                 then "[#{value.map { |item| pdf_value(item) }.join(' ')}]"
    when Hash                  then dict(value)
    when String                then literal_string(value)
    else
      raise ArgumentError, "can't serialize #{value.class}"
    end
  end

  def literal_string(str)
    escaped = str.b.gsub(/[\\()\r]/) do |char|
      case char
      when "\\" then "\\\\"
      when "("  then "\\("
      when ")"  then "\\)"
      when "\r" then "\\r"
      end
    end
    "(#{escaped})"
  end

  # assemble everything, with +root_id+ as the catalog. If +overrides+ is given
  # it maps object ids to replacement body strings (used to deliberately corrupt
  # a section of an otherwise valid PDF).
  def render(root_id, overrides: {})
    ids = @objects.keys.sort
    pdf = StringIO.new
    pdf.set_encoding(Encoding::BINARY)
    pdf << "%PDF-#{@version}\n"
    pdf << "%\xAA\xAB\xAC\xAD\n"
    offsets = {}

    ids.each do |id|
      offsets[id] = pdf.pos
      body = overrides.fetch(id, @objects[id])
      pdf << "#{id} 0 obj\n#{body}\nendobj\n"
    end

    xref_offset = pdf.pos
    total = ids.max + 1
    pdf << "xref\n"
    pdf << "0 #{total}\n"
    pdf << "0000000000 65535 f\n"
    (1..ids.max).each do |id|
      pdf << format("%010d 00000 n\n", offsets.fetch(id))
    end
    pdf << "trailer\n<< /Size #{total} /Root #{root_id} 0 R >>\n"
    pdf << "startxref\n#{xref_offset}\n%%EOF\n"
    pdf.string
  end

  def render_io(root_id, overrides: {})
    StringIO.new(render(root_id, overrides: overrides))
  end
end

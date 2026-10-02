# typed: false
# coding: utf-8

require "zlib"

module IncrementalPdfHelper
  OLD_PAGE = "BT /F1 12 Tf 0 0 Td (old page) Tj ET"
  REPLACED_PAGE = "BT /F1 12 Tf 0 0 Td (replaced page) Tj ET"
  OBJECT_STREAM_PAGE = "BT /F1 12 Tf 0 0 Td (object stream page) Tj ET"

  DIRECT_FONT = {
    :Type => :Font,
    :Subtype => :Type1,
    :BaseFont => :Helvetica
  }.freeze

  def incremental_pdf
    first, first_xref = classic_pdf(1)
    second, second_xref = append_classic_revision(first, first_xref)
    third, _third_xref = append_hybrid_revision(second, second_xref)
    [third, first, second, build_hybrid_standalone]
  end

  def broken_prev_pdf
    pdf, = classic_pdf(1)
    second, = append_classic_revision(pdf, pdf.rindex("xref"))
    second.sub(/\/Prev \d+/, "/Prev 999999")
  end

  def broken_xrefstm_pdf
    pdf, = incremental_pdf
    pdf.sub(/\/XRefStm \d+/, "/XRefStm 999999")
  end

  def classic_pdf(revision)
    io = StringIO.new
    io.set_encoding(Encoding::BINARY)
    write_header(io)

    if revision == 1
      write_object(io, 1, 0, "<< /Title (old info) >>")
      write_object(io, 2, 0, catalog(0))
      write_object(io, 3, 0, pages(0, 4, 0))
      write_object(io, 4, 0, page(0, 5, 0, direct_font_resources))
      write_stream(io, 5, 0, OLD_PAGE)
      offsets = object_offsets(io.string, [[1, 0], [2, 0], [3, 0], [4, 0], [5, 0]])
      xref = write_classic_xref(io, 6, offsets, classic_free_entries(1), :Root => [2, 0], :Info => [1, 0])
    else
      write_object(io, 2, 1, catalog(1))
      write_object(io, 3, 1, pages(1, 4, 1))
      write_object(io, 4, 1, page(1, 6, 0, direct_font_resources))
      write_stream(io, 6, 0, REPLACED_PAGE)
      offsets = object_offsets(io.string, [[2, 1], [3, 1], [4, 1], [6, 0]])
      xref = write_classic_xref(io, 7, offsets, classic_free_entries(2), :Root => [2, 1])
    end

    write_footer(io, xref)
    [io.string, xref]
  end

  def append_classic_revision(existing, previous_xref)
    io = StringIO.new(existing.dup)
    io.seek(0, IO::SEEK_END)
    write_object(io, 2, 1, catalog(1))
    write_object(io, 3, 1, pages(1, 4, 1))
    write_object(io, 4, 1, page(1, 6, 0, direct_font_resources))
    write_stream(io, 6, 0, REPLACED_PAGE)
    offsets = object_offsets(io.string, [[2, 1], [3, 1], [4, 1], [6, 0]])
    xref = write_classic_xref(
      io,
      7,
      offsets,
      classic_free_entries(2),
      :Root => [2, 1],
      :Prev => previous_xref
    )
    write_footer(io, xref)
    [io.string, xref]
  end

  def append_hybrid_revision(existing, previous_xref)
    io = StringIO.new(existing.dup)
    io.seek(0, IO::SEEK_END)
    write_hybrid_objects(io)
    xref_stream_offset = write_revision_xref_stream(io, nil)
    xref = write_hybrid_xref(io, xref_stream_offset, previous_xref)
    write_footer(io, xref)
    [io.string, xref]
  end

  def build_hybrid_standalone
    io = StringIO.new
    io.set_encoding(Encoding::BINARY)
    write_header(io)
    write_object(io, 2, 2, catalog(2))
    write_object(io, 3, 2, pages(2, 4, 2))
    write_object(io, 4, 2, page(2, 8, 0, compressed_font_resources))
    write_stream(io, 8, 0, OBJECT_STREAM_PAGE)
    write_object_stream(io, 9)
    xref_stream_offset = write_revision_xref_stream(io, nil)
    write_hybrid_xref(io, xref_stream_offset, nil)
    io.seek(0, IO::SEEK_END)
    io.write("startxref\n#{io.string.rindex("xref")}\n%%EOF\n")
    io.string
  end

  def write_hybrid_objects(io)
    write_object(io, 2, 2, catalog(2))
    write_object(io, 3, 2, pages(2, 4, 2))
    write_object(io, 4, 2, page(2, 8, 0, compressed_font_resources))
    write_stream(io, 8, 0, OBJECT_STREAM_PAGE)
    write_object_stream(io, 9)
  end

  def write_header(io)
    io.write("%PDF-1.5\n%\xAE\x9F\x93\x93\n")
  end

  def catalog(pages_generation)
    "<< /Type /Catalog /Pages 3 #{pages_generation} R >>"
  end

  def pages(generation, page_id, page_generation)
    "<< /Type /Pages /Kids [#{page_id} #{page_generation} R] /Count 1 >>"
  end

  def page(generation, content_id, content_generation, resources)
    "<< /Type /Page /Parent 3 #{generation} R /MediaBox [0 0 612 792] " \
      "/Contents #{content_id} #{content_generation} R /Resources #{resources} >>"
  end

  def direct_font_resources
    "<< /Font << /F1 #{pdf_dict(DIRECT_FONT)} >> >>"
  end

  def compressed_font_resources
    "<< /Font << /F1 7 0 R >> >>"
  end

  def pdf_dict(dict)
    entries = dict.map { |key, value| "/#{key} #{pdf_value(value)}" }.join(" ")
    "<< #{entries} >>"
  end

  def pdf_value(value)
    case value
    when Symbol then "/#{value}"
    when Array then "[#{value.map { |item| pdf_value(item) }.join(" ")}]"
    else value.inspect
    end
  end

  def write_object(io, id, generation, body)
    io.write("#{id} #{generation} obj\n#{body}\nendobj\n")
  end

  def write_stream(io, id, generation, data)
    body = "<< /Length #{data.bytesize} >>\nstream\n#{data}\nendstream"
    write_object(io, id, generation, body)
  end

  def write_object_stream(io, id)
    inner = "7 0 #{pdf_dict(DIRECT_FONT)}"
    compressed = Zlib.deflate(inner)
    body = "<< /Type /ObjStm /N 1 /First 4 /Length #{compressed.bytesize} " \
      "/Filter /FlateDecode >>\nstream\n#{compressed}\nendstream"
    write_object(io, id, 0, body)
  end

  def object_offsets(data, refs)
    refs.each_with_object({}) do |(id, generation), offsets|
      prefix = "#{id} #{generation} obj"
      offset = data.index(prefix)
      raise "missing object #{prefix}" if offset.nil?
      offsets[[id, generation]] = offset
    end
  end

  def classic_free_entries(revision)
    if revision == 1
      {[0, 0] => [0, 65535]}
    else
      {
        [0, 0] => [1, 65535],
        [1, 0] => [5, 1],
        [5, 0] => [0, 1]
      }
    end
  end

  def write_classic_xref(io, size, offsets, free_entries, trailer_entries)
    start = io.pos
    io.write("xref\n0 #{size}\n")
    size.times do |id|
      if free_entries.key?([id, 0])
        next_free, generation = free_entries[[id, 0]]
        io.write("%010d %05d f \n" % [next_free, generation])
      else
        reference = offsets.keys.find { |object_id, _generation| object_id == id }
        generation = reference ? reference.last : 0
        io.write("%010d %05d n \n" % [offsets[[id, generation]], generation])
      end
    end
    write_trailer(io, trailer_entries.merge(:Size => size))
    start
  end

  def write_hybrid_xref(io, xref_stream_offset, previous_xref)
    start = io.pos
    io.write("xref\n0 7\n")
    7.times do |id|
      if hybrid_free_entries.key?(id)
        next_free, generation = hybrid_free_entries[id]
        io.write("%010d %05d f \n" % [next_free, generation])
      else
        generation = [2, 3, 4].include?(id) ? 2 : 0
        offset = io.string.index("#{id} #{generation} obj")
        io.write("%010d %05d n \n" % [offset, generation])
      end
    end

    io.write("8 3\n")
    [8, 9, 10].each do |id|
      offset = io.string.index("#{id} 0 obj")
      io.write("%010d %05d n \n" % [offset, 0])
    end

    trailer = {:Size => 11, :Root => [2, 2], :XRefStm => xref_stream_offset}
    trailer[:Prev] = previous_xref unless previous_xref.nil?
    write_trailer(io, trailer)
    start
  end

  def hybrid_free_entries
    {
      0 => [1, 65535],
      1 => [5, 1],
      5 => [6, 1],
      6 => [0, 1]
    }
  end

  def write_revision_xref_stream(io, _previous_xref)
    offsets = {}
    [[2, 2], [3, 2], [4, 2], [8, 0], [9, 0]].each do |id, generation|
      offsets[[id, generation]] = io.string.index("#{id} #{generation} obj")
    end

    xref_stream_offset = io.pos
    offsets[[10, 0]] = xref_stream_offset
    entries = [
      [0, 1, 65535],
      [0, 5, 1],
      [1, offsets[[2, 2]], 2],
      [1, offsets[[3, 2]], 2],
      [1, offsets[[4, 2]], 2],
      [0, 6, 1],
      [0, 0, 1],
      [2, 9, 0],
      [1, offsets[[8, 0]], 0],
      [1, offsets[[9, 0]], 0],
      [1, offsets[[10, 0]], 0]
    ]
    data = entries.map { |type, field_two, field_three| [type, field_two, field_three].pack("CNn") }.join
    body = "<< /Type /XRef /Size 11 /W [1 4 2] /Root 2 2 R /Length #{data.bytesize} >>\n" \
      "stream\n#{data}\nendstream"
    write_object(io, 10, 0, body)
    xref_stream_offset
  end

  def write_trailer(io, entries)
    rendered = entries.map do |key, value|
      "/#{key} #{value.is_a?(Array) ? value.join(" ") + " R" : value}"
    end.join(" ")
    io.write("trailer\n<< #{rendered} >>\n")
  end

  def write_footer(io, xref_offset)
    io.write("startxref\n#{xref_offset}\n%%EOF\n")
  end
end

# typed: false
# coding: utf-8

# Builds a PDF that has been saved three times using incremental updates, plus
# three standalone files that each contain the complete state of one revision
# (as if "Save As" had been used at that point in time).
#
# revision 1: base file with a traditional xref table. Two pages, an Info dict
#             and a string object (8 0) that is deleted by revision 2.
# revision 2: hybrid save - a traditional xref table plus a supplementary xref
#             stream (/XRefStm). Deletes object 8 0 (free entry), replaces the
#             contents of page one (objects 3 and 10), updates the Info dict
#             (9 0) and adds object 11 0 via the hybrid xref stream.
# revision 3: xref stream only save. Updates the Info dict (9 0) again,
#             reincarnates object 8 as generation 1, and adds an object stream
#             (13 0) holding objects 14 and 15.
module IncrementalPdfFixtures
  REV1_PAGE_ONE  = "page one revision one"
  REV1_PAGE_TWO  = "page two revision one"
  REV2_PAGE_ONE  = "page one revision two"
  DELETED_OBJECT = "this object is deleted in revision two"
  HYBRID_OBJECT  = "added in revision two via a hybrid xref stream"
  OBJSTM_STRING  = "added in revision three inside an object stream"
  REINCARNATED   = "object 8 reincarnated as generation 1 in revision three"

  module_function

  # Returns a hash with:
  #   :full - the 3 revision incrementally saved PDF
  #   :rev1, :rev2, :rev3 - standalone full saves of each revision
  def build
    rev1, rev1_xref = build_rev1
    rev2, rev2_xref = build_rev2(rev1, rev1_xref)
    full, _rev3_xref = build_rev3(rev2, rev2_xref)

    {
      :full => full,
      :rev1 => rev1,
      :rev2 => standalone_rev2,
      :rev3 => standalone_rev3,
    }
  end

  # The incremental file with the /Prev pointer of the most recent revision
  # replaced by an offset well past the end of the file.
  def build_with_broken_prev
    full = build[:full]
    idx = full.rindex(%r{/Prev \d+})
    copy = full.dup
    copy[idx..] = copy[idx..].sub(%r{/Prev \d+}, "/Prev 99999999")
    copy
  end

  ########################################################################
  # object bodies
  ########################################################################

  def content_stream(text)
    stream = "BT /F1 12 Tf 72 720 Td (#{text}) Tj ET"
    "<< /Length #{stream.bytesize} >>\nstream\n#{stream}\nendstream"
  end

  def font
    "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
  end

  def page_obj(contents_id)
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] " \
      "/Resources << /Font << /F1 7 0 R >> >> /Contents #{contents_id} 0 R >>"
  end

  def info_rev1
    "<< /Producer (incremental fixture) >>"
  end

  def info_rev2
    "<< /Producer (incremental fixture) /Custom 11 0 R >>"
  end

  def info_rev3
    "<< /Producer (incremental fixture) /Custom 11 0 R /Custom2 14 0 R >>"
  end

  def objstm
    members = [[14, "(#{OBJSTM_STRING})"], [15, "[1 2 3]"]]
    header  = +""
    body    = +""
    members.each do |objid, str|
      header << "#{objid} #{body.bytesize} "
      body << str << "\n"
    end
    data = header + body
    "<< /Type /ObjStm /N #{members.size} /First #{header.bytesize} " \
      "/Length #{data.bytesize} >>\nstream\n#{data}\nendstream"
  end

  ########################################################################
  # serialisation helpers
  ########################################################################

  def obj(id, gen, body)
    "#{id} #{gen} obj\n#{body}\nendobj\n"
  end

  # subsections: [[start_id, [[offset, gen, "n"|"f"], ...]], ...]
  def xref_table(subsections)
    out = +"xref\n"
    subsections.each do |start, entries|
      out << "#{start} #{entries.size}\n"
      entries.each do |offset, gen, state|
        out << format("%010d %05d %s \n", offset, gen, state)
      end
    end
    out
  end

  def trailer(dict_body, xref_offset)
    "trailer\n<< #{dict_body} >>\nstartxref\n#{xref_offset}\n%%EOF\n"
  end

  # entries: {objid => [type, f2, f3]} where type is 0 (free), 1 (in-use) or
  # 2 (compressed in an object stream)
  def xref_stream_obj(id, size, index, entries, prev: nil, root: nil, info: nil)
    data = +""
    index.each_slice(2) do |start, count|
      (start...(start + count)).each do |objid|
        type, f2, f3 = entries.fetch(objid)
        data << [type, f2, f3].pack("CNn")
      end
    end
    dict = "<< /Type /XRef /Size #{size} /W [1 4 2] /Index [#{index.join(' ')}] " \
      "/Length #{data.bytesize}"
    dict << " /Prev #{prev}" if prev
    dict << " /Root #{root} 0 R" if root
    dict << " /Info #{info} 0 R" if info
    dict << " >>"
    obj(id, 0, "#{dict}\nstream\n#{data}\nendstream")
  end

  ########################################################################
  # revision 1 - base save, traditional xref table
  ########################################################################

  def build_rev1
    out = +"%PDF-1.5\n"
    offsets = {}
    {
      1 => "<< /Type /Catalog /Pages 2 0 R >>",
      2 => "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
      3 => page_obj(5),
      4 => page_obj(6),
      5 => content_stream(REV1_PAGE_ONE),
      6 => content_stream(REV1_PAGE_TWO),
      7 => font,
      8 => "(#{DELETED_OBJECT})",
      9 => info_rev1,
    }.each do |id, body|
      offsets[id] = out.bytesize
      out << obj(id, 0, body)
    end
    xref_offset = out.bytesize
    entries = (1..9).map { |id| [offsets[id], 0, "n"] }
    out << xref_table([[0, [[0, 65535, "f"]]], [1, entries]])
    out << trailer("/Size 10 /Root 1 0 R /Info 9 0 R", xref_offset)
    [out, xref_offset]
  end

  ########################################################################
  # revision 2 - hybrid save: traditional table + /XRefStm stream.
  # Deletes object 8, replaces page one, updates Info, adds object 11.
  ########################################################################

  def build_rev2(rev1, rev1_xref)
    out = rev1.dup
    offsets = {}
    {
      3  => page_obj(10),
      9  => info_rev2,
      10 => content_stream(REV2_PAGE_ONE),
      11 => "(#{HYBRID_OBJECT})",
    }.each do |id, body|
      offsets[id] = out.bytesize
      out << obj(id, 0, body)
    end

    # the supplementary xref stream holds the entries for objects 11 and 12
    xrefstm_offset = out.bytesize
    out << xref_stream_obj(12, 13, [11, 2],
                           {
                             11 => [1, offsets[11], 0],
                             12 => [1, xrefstm_offset, 0],
                           })

    xref_offset = out.bytesize
    out << xref_table([
      [0, [[0, 65535, "f"]]],
      [3, [[offsets[3], 0, "n"]]],
      [8, [[0, 1, "f"]]], # object 8 gen 0 deleted here
      [9, [[offsets[9], 0, "n"], [offsets[10], 0, "n"]]],
    ])
    out << trailer(
      "/Size 13 /Root 1 0 R /Info 9 0 R /Prev #{rev1_xref} /XRefStm #{xrefstm_offset}",
      xref_offset
    )
    [out, xref_offset]
  end

  ########################################################################
  # revision 3 - xref stream only save. Updates Info, reincarnates object 8
  # as generation 1, adds an object stream (13 0) holding objects 14 and 15.
  ########################################################################

  def build_rev3(rev2, rev2_xref)
    out = rev2.dup
    offsets = {}
    {
      8  => "(#{REINCARNATED})",
      9  => info_rev3,
      13 => objstm,
    }.each do |id, body|
      offsets[id] = out.bytesize
      out << obj(id, id == 8 ? 1 : 0, body)
    end

    stream_offset = out.bytesize
    out << xref_stream_obj(16, 17, [8, 2, 13, 4],
                           {
                             8  => [1, offsets[8], 1],
                             9  => [1, offsets[9], 0],
                             13 => [1, offsets[13], 0],
                             14 => [2, 13, 0],
                             15 => [2, 13, 1],
                             16 => [1, stream_offset, 0],
                           },
                           prev: rev2_xref, root: 1, info: 9)
    out << "startxref\n#{stream_offset}\n%%EOF\n"
    [out, stream_offset]
  end

  ########################################################################
  # standalone full save of the revision 2 state, traditional xref table
  ########################################################################

  def standalone_rev2
    out = +"%PDF-1.5\n"
    offsets = {}
    {
      1  => "<< /Type /Catalog /Pages 2 0 R >>",
      2  => "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
      3  => page_obj(10),
      4  => page_obj(6),
      5  => content_stream(REV1_PAGE_ONE),
      6  => content_stream(REV1_PAGE_TWO),
      7  => font,
      9  => info_rev2,
      10 => content_stream(REV2_PAGE_ONE),
      11 => "(#{HYBRID_OBJECT})",
    }.each do |id, body|
      offsets[id] = out.bytesize
      out << obj(id, 0, body)
    end
    xref_offset = out.bytesize
    entries = (1..11).map { |id|
      offsets[id] ? [offsets[id], 0, "n"] : [0, 1, "f"]
    }
    out << xref_table([[0, [[0, 65535, "f"]]], [1, entries]])
    out << trailer("/Size 12 /Root 1 0 R /Info 9 0 R", xref_offset)
    out
  end

  ########################################################################
  # standalone full save of the revision 3 state, single xref stream
  ########################################################################

  def standalone_rev3
    out = +"%PDF-1.5\n"
    offsets = {}
    {
      1  => "<< /Type /Catalog /Pages 2 0 R >>",
      2  => "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
      3  => page_obj(10),
      4  => page_obj(6),
      5  => content_stream(REV1_PAGE_ONE),
      6  => content_stream(REV1_PAGE_TWO),
      7  => font,
      8  => "(#{REINCARNATED})",
      9  => info_rev3,
      10 => content_stream(REV2_PAGE_ONE),
      11 => "(#{HYBRID_OBJECT})",
      13 => objstm,
    }.each do |id, body|
      offsets[id] = out.bytesize
      out << obj(id, id == 8 ? 1 : 0, body)
    end

    stream_offset = out.bytesize
    entries = { 0 => [0, 0, 65535], 12 => [0, 0, 1] }
    (1..11).each { |id| entries[id] = [1, offsets[id], 0] }
    entries[8]  = [1, offsets[8], 1]
    entries[13] = [1, offsets[13], 0]
    entries[14] = [2, 13, 0]
    entries[15] = [2, 13, 1]
    entries[16] = [1, stream_offset, 0]
    out << xref_stream_obj(16, 17, [0, 17], entries, root: 1, info: 9)
    out << "startxref\n#{stream_offset}\n%%EOF\n"
    out
  end
end

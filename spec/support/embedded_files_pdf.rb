# typed: false
# coding: utf-8
# frozen_string_literal: true

require 'digest/md5'

# Builds an in-memory PDF exercising every embedded file entry point.
module EmbeddedFilesPdf
  module_function

  # returns [PdfFixtureBuilder, catalog_object_id]
  def build
    pdf = PdfFixtureBuilder.new

    shared_payload = "shared content"
    stream_shared = pdf.add(pdf.stream(
      { :Type => :EmbeddedFile,
        :Params => { :Size => shared_payload.bytesize,
                     :CheckSum => pdf.hex(Digest::MD5.digest(shared_payload)),
                     :CreationDate => "D:20200101000000Z" } },
      shared_payload
    ))

    win_payload = "windows content"
    stream_win = pdf.add(pdf.stream(
      { :Type => :EmbeddedFile, :Params => { :Size => win_payload.bytesize } },
      win_payload
    ))

    mac_payload = "mac content"
    stream_mac = pdf.add(pdf.stream({ :Type => :EmbeddedFile }, mac_payload))

    compressed_payload = "compressed content is here"
    stream_compressed = pdf.add(pdf.flate_stream(
      { :Type => :EmbeddedFile, :Subtype => :"text#2Fplain",
        :Params => { :Size => compressed_payload.bytesize } },
      compressed_payload
    ))

    stream_unknown = pdf.add(pdf.stream(
      { :Type => :EmbeddedFile, :Filter => :FantasyDecode }, "mystery bytes"
    ))

    spec_first = pdf.add(pdf.dict(
      :Type => :Filespec, :F => "cafe-report.txt",
      :UF => pdf.utf16("café.txt"),
      :AFRelationship => :Alternative,
      :Desc => "first alias",
      :EF => { :F => pdf.ref(stream_shared), :UF => pdf.ref(stream_shared) }
    ))

    spec_duplicate = pdf.add(pdf.dict(
      :Type => :Filespec, :F => "report.txt",
      :AFRelationship => :Data,
      :EF => { :F => pdf.ref(stream_shared) }
    ))

    spec_platform = pdf.add(pdf.dict(
      :Type => :Filespec, :F => "generic.dat",
      :UF => pdf.utf16("uni.txt"),
      :DOS => "WIN.DAT", :Mac => "Mac Data", :Unix => "unix.dat",
      :EF => { :DOS => pdf.ref(stream_win), :Mac => pdf.ref(stream_mac) }
    ))

    spec_catalog = pdf.add(pdf.dict(
      :Type => :Filespec, :F => "catalog.csv", :AFRelationship => :Data,
      :EF => { :F => pdf.ref(stream_compressed) }
    ))

    spec_page = pdf.add(pdf.dict(
      :Type => :Filespec, :F => "page.bin", :AFRelationship => :Supplement,
      :EF => { :F => pdf.ref(stream_shared) }
    ))

    spec_annot = pdf.add(pdf.dict(
      :Type => :Filespec, :F => "note.txt", :AFRelationship => :Unspecified,
      :EF => { :F => pdf.ref(stream_compressed) }
    ))

    spec_xobj = pdf.add(pdf.dict(
      :Type => :Filespec, :F => "logo-source.svg", :AFRelationship => :Source,
      :EF => { :F => pdf.ref(stream_win) }
    ))

    spec_url = pdf.add(pdf.dict(
      :Type => :Filespec, :FS => :URL, :F => "https://example.com/evil.txt",
      :AFRelationship => :Data
    ))

    spec_path = pdf.add(pdf.dict(
      :Type => :Filespec, :F => "../../../../etc/passwd", :AFRelationship => :Data
    ))

    spec_unknown = pdf.add(pdf.dict(
      :Type => :Filespec, :F => "weird.bin",
      :EF => { :F => pdf.ref(stream_unknown) }
    ))

    form = pdf.add(pdf.stream(
      { :Type => :XObject, :Subtype => :Form,
        :BBox => [0, 0, 100, 100],
        :AF => [pdf.ref(spec_xobj)] },
      ""))

    annot = pdf.add(pdf.dict(
      :Type => :Annot, :Subtype => :FileAttachment,
      :Rect => [0, 0, 10, 10], :Contents => "attach me",
      :FS => pdf.ref(spec_annot)
    ))

    leaf_pairs = [
      pdf.utf16("café.txt"), pdf.ref(spec_first),
      "report.txt", pdf.ref(spec_duplicate),
      "report.txt", pdf.ref(spec_platform),
      "weird.bin", pdf.ref(spec_unknown)
    ]
    names_leaf = pdf.add(pdf.dict(:Names => leaf_pairs))
    name_root = pdf.add(pdf.dict(:Kids => [pdf.ref(names_leaf)]))
    names = pdf.add(pdf.dict(:EmbeddedFiles => pdf.ref(name_root)))

    content = pdf.add(pdf.stream({}, "BT /F1 12 Tf 50 700 Td (hi) Tj ET"))
    font = pdf.add(pdf.dict(:Type => :Font, :Subtype => :Type1, :BaseFont => :Helvetica))
    # reserve the page id so the pages tree can reference it, fill it after
    page = pdf.add("")
    pages = pdf.add(pdf.dict(
      :Type => :Pages, :Kids => [pdf.ref(page)], :Count => 1
    ))
    pdf.replace(page, pdf.dict(
      :Type => :Page, :Parent => pdf.ref(pages),
      :MediaBox => [0, 0, 612, 792],
      :Resources => { :XObject => { :Fm1 => pdf.ref(form) },
                      :Font => { :F1 => pdf.ref(font) } },
      :Annots => [pdf.ref(annot)],
      :AF => [pdf.ref(spec_page)],
      :Contents => pdf.ref(content)
    ))

    catalog = pdf.add(pdf.dict(
      :Type => :Catalog, :Pages => pdf.ref(pages), :Names => pdf.ref(names),
      :AF => [pdf.ref(spec_catalog), pdf.ref(spec_url), pdf.ref(spec_path)]
    ))

    [pdf, catalog, { :names_leaf => names_leaf, :spec_first => spec_first }]
  end

  def build_reader(overrides: {})
    pdf, root, _ids = build
    PDF::Reader.new(pdf.render_io(root, overrides: overrides))
  end

  def build_damaged_reader
    pdf, root, ids = build
    broken = pdf.dict(:Names => [pdf.ref(ids[:spec_first])])
    PDF::Reader.new(pdf.render_io(root, :overrides => { ids[:names_leaf] => broken }))
  end
end

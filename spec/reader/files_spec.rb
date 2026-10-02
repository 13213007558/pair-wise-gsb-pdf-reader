# coding: utf-8
# frozen_string_literal: true

require 'digest/md5'

RSpec.describe PDF::Reader, "embedded files" do
  include EmbeddedFilesPdf

  def reader
    build_reader
  end

  it "lists every entry with its scope, name and relationship" do
    entries = reader.files

    expect(entries.map(&:scope)).to eq([
      :name_tree, :name_tree, :name_tree, :name_tree,
      :document, :document, :document,
      :page, :annotation, :xobject
    ])

    expect(entries.first.name).to eq("café.txt")
    expect(entries.first.file_name).to eq("café.txt")
    expect(entries.first.relationship).to eq(:Alternative)
    expect(entries[1].name).to eq("report.txt")
    expect(entries[1].relationship).to eq(:Data)
    expect(entries[4].relationship).to eq(:Data)
    expect(entries[7].relationship).to eq(:Supplement)
    expect(entries[8].relationship).to eq(:Unspecified)
    expect(entries[9].relationship).to eq(:Source)
    expect(entries.map(&:page_number)).to eq(
      [nil, nil, nil, nil, nil, nil, nil, 1, 1, 1]
    )
  end

  it "keeps duplicate names and all aliases" do
    tree = reader.files.select { |e| e.scope == :name_tree }

    expect(tree.map(&:name)).to eq(["café.txt", "report.txt", "report.txt", "weird.bin"])
    expect(tree.map(&:reference)).to all(be_a(PDF::Reader::Reference))
    expect(tree[0].reference).not_to eq(tree[1].reference)
  end

  it "keeps distinct filespecs sharing one embedded stream" do
    entries = reader.files
    first = entries[0].filespec.embedded
    duplicate = entries[1].filespec.embedded

    expect(first.read.data).to eq("shared content")
    expect(duplicate.read.data).to eq("shared content")
    expect(first.reference).to eq(duplicate.reference)
  end

  it "prefers UF over F and exposes platform names/streams" do
    platform = reader.files[2].filespec

    expect(platform.name).to eq("uni.txt")
    expect(platform.names.keys).to contain_exactly(:F, :UF, :DOS, :Mac, :Unix)
    expect(platform.names[:DOS]).to eq("WIN.DAT")
    expect(platform.embedded_files.keys).to contain_exactly(:DOS, :Mac)
    expect(platform.embedded_files[:DOS].read.data).to eq("windows content")
    expect(platform.embedded_files[:Mac].read.data).to eq("mac content")
  end

  it "exposes Params Size and CheckSum for verification" do
    embedded = reader.files.first.filespec.embedded

    expect(embedded.size).to eq(14)
    expect(embedded.checksum).to eq(Digest::MD5.digest("shared content"))
    expect(embedded.checksum_hex).to eq(Digest::MD5.hexdigest("shared content").upcase)
    expect(embedded.creation_date).to eq("D:20200101000000Z")
  end

  it "decodes supported filters through the library's filters" do
    result = reader.files[4].read

    expect(result).to be_ok
    expect(result.data).to eq("compressed content is here")
    expect(result.data.encoding).to eq(Encoding::BINARY)
    expect(reader.files[4].filespec.embedded.subtype).to eq(:"text/plain")
  end

  it "reports unknown filters with an explicit status" do
    result = reader.files.find { |e| e.file_name == "weird.bin" }.read

    expect(result).to be_unsupported_filter
    expect(result.filter).to eq(:FantasyDecode)
    expect(result.data).to be_nil
    expect(result.message).to include("FantasyDecode")
  end

  it "does not follow URL or external-path specifications" do
    entries = reader.files
    url = entries.find { |e| e.file_name == "https://example.com/evil.txt" }
    path = entries.find { |e| e.file_name == "../../../../etc/passwd" }

    expect(url).to be_external
    expect(url.read).to be_external
    expect(path.read).to be_external
    expect(path.read.data).to be_nil
  end

  it "lets the caller read by filespec, stream and reference identity" do
    pdf = reader
    entry = pdf.files[4]

    expect(pdf.read_embedded_file(entry).data).to eq("compressed content is here")
    expect(pdf.read_embedded_file(entry.filespec).data).to eq("compressed content is here")
    expect(pdf.read_embedded_file(entry.filespec.embedded).data).to eq("compressed content is here")
    expect(pdf.read_embedded_file(entry.reference).data).to eq("compressed content is here")

    stream_ref = entry.filespec.dict[:EF][:F]
    expect(pdf.read_embedded_file(stream_ref).data).to eq("compressed content is here")
  end

  it "scopes page, annotation and xobject entries to the page" do
    page_entries = reader.page(1).files

    expect(page_entries.map(&:scope)).to eq([:page, :annotation, :xobject])
    expect(page_entries.map(&:page_number)).to all(eq(1))
    expect(page_entries.last.scope).to eq(:xobject)
    expect(page_entries.last.details[:label]).to eq(:Fm1)
    expect(page_entries.last.container_reference).to be_a(PDF::Reader::Reference)
    expect(page_entries[1].details[:subtype]).to eq(:FileAttachment)
  end

  it "still parses ordinary page text alongside the attachment walk" do
    expect(reader.page(1).text.gsub(/\s+/, " ").strip).to eq("hi")
  end

  it "exposes alias methods on the reader" do
    expect(reader.embedded_files.map(&:name)).to eq(reader.files.map(&:name))
    expect(reader.attachments.size).to eq(10)
  end

  describe "damaged name tree" do
    def damaged_reader
      EmbeddedFilesPdf.build_damaged_reader
    end

    it "does not raise and keeps the non-tree entries" do
      expect { damaged_reader.files }.not_to raise_error
      scopes = damaged_reader.files.map(&:scope).tally

      expect(scopes[:document]).to eq(3)
      expect(scopes[:page]).to eq(1)
      expect(scopes[:annotation]).to eq(1)
      expect(scopes[:xobject]).to eq(1)
      expect(scopes).not_to have_key(:name_tree)
    end
  end

  describe "resilience" do
    it "keeps healthy name tree branches when one intermediate kid is broken" do
      pdf = PdfFixtureBuilder.new
      payload = "good bytes"
      stream_good = pdf.add(pdf.stream({ :Type => :EmbeddedFile }, payload))
      spec_good = pdf.add(pdf.dict(
        :Type => :Filespec, :F => "good.txt", :EF => { :F => pdf.ref(stream_good) }
      ))
      leaf_good = pdf.add(pdf.dict(:Names => ["good.txt", pdf.ref(spec_good)]))
      # points at an object that isn't a name tree node at all
      bad_target = pdf.add("42")
      root_node = pdf.add(pdf.dict(:Kids => [pdf.ref(bad_target), pdf.ref(leaf_good)]))
      names = pdf.add(pdf.dict(:EmbeddedFiles => pdf.ref(root_node)))
      pages = pdf.add(pdf.dict(:Type => :Pages, :Kids => [], :Count => 0))
      catalog = pdf.add(pdf.dict(
        :Type => :Catalog, :Pages => pdf.ref(pages), :Names => pdf.ref(names)
      ))

      result = PDF::Reader.new(pdf.render_io(catalog)).files

      expect(result.map(&:name)).to eq(["good.txt"])
      expect(result.first.read.data).to eq("good bytes")
    end

    it "reports a dangling EF reference as missing instead of raising" do
      pdf = PdfFixtureBuilder.new
      spec = pdf.add(pdf.dict(
        :Type => :Filespec, :F => "dangling.bin",
        :EF => { :F => PDF::Reader::Reference.new(999, 0) }
      ))
      leaf = pdf.add(pdf.dict(:Names => ["dangling.bin", pdf.ref(spec)]))
      names = pdf.add(pdf.dict(:EmbeddedFiles => pdf.ref(leaf)))
      pages = pdf.add(pdf.dict(:Type => :Pages, :Kids => [], :Count => 0))
      catalog = pdf.add(pdf.dict(
        :Type => :Catalog, :Pages => pdf.ref(pages), :Names => pdf.ref(names)
      ))

      entry = PDF::Reader.new(pdf.render_io(catalog)).files.first

      expect(entry.read).to be_missing
    end

    it "returns a missing result for an identity without an embedded stream" do
      result = reader.read_embedded_file(PDF::Reader::Reference.new(99_999, 0))
      expect(result).to be_missing
    end

    it "falls back to the F stream when UF is advertised without an EF entry" do
      pdf = PdfFixtureBuilder.new
      payload = "only f has bytes"
      stream = pdf.add(pdf.stream({ :Type => :EmbeddedFile }, payload))
      spec_obj = pdf.add(pdf.dict(
        :Type => :Filespec, :F => "plain.txt", :UF => pdf.utf16("plain.txt"),
        :EF => { :F => pdf.ref(stream) }
      ))
      leaf = pdf.add(pdf.dict(:Names => ["plain.txt", pdf.ref(spec_obj)]))
      names = pdf.add(pdf.dict(:EmbeddedFiles => pdf.ref(leaf)))
      pages = pdf.add(pdf.dict(:Type => :Pages, :Kids => [], :Count => 0))
      catalog = pdf.add(pdf.dict(
        :Type => :Catalog, :Pages => pdf.ref(pages), :Names => pdf.ref(names)
      ))

      entry = PDF::Reader.new(pdf.render_io(catalog)).files.first

      expect(entry.read.data).to eq(payload)
    end

  it "works on a PDF with no embedded files at all" do
      pdf = PdfFixtureBuilder.new
      pages = pdf.add(pdf.dict(:Type => :Pages, :Kids => [], :Count => 0))
      catalog = pdf.add(pdf.dict(:Type => :Catalog, :Pages => pdf.ref(pages)))

      expect(PDF::Reader.new(pdf.render_io(catalog)).files).to eq([])
    end

    it "decodes an ASCIIHex stream and chooses a platform key stream" do
      pdf = PdfFixtureBuilder.new
      payload = "ascii hex payload"
      encoded = payload.unpack1("H*") + ">"
      stream = pdf.add(pdf.stream(
        { :Type => :EmbeddedFile, :Filter => :ASCIIHexDecode }, encoded
      ))
      spec_obj = pdf.add(pdf.dict(
        :Type => :Filespec, :Mac => "mac-only",
        :EF => { :Mac => pdf.ref(stream) }
      ))
      leaf = pdf.add(pdf.dict(:Names => ["mac-only", pdf.ref(spec_obj)]))
      names = pdf.add(pdf.dict(:EmbeddedFiles => pdf.ref(leaf)))
      pages = pdf.add(pdf.dict(:Type => :Pages, :Kids => [], :Count => 0))
      catalog = pdf.add(pdf.dict(
        :Type => :Catalog, :Pages => pdf.ref(pages), :Names => pdf.ref(names)
      ))

      entry = PDF::Reader.new(pdf.render_io(catalog)).files.first

      expect(entry.file_name).to eq("mac-only")
      expect(entry.read).to be_ok
      expect(entry.read.data).to eq(payload)
    end
  end
end

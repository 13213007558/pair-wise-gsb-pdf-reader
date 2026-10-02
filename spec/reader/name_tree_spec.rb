# coding: utf-8
# frozen_string_literal: true

RSpec.describe PDF::Reader::NameTree do
  def build_reader
    pdf = PdfFixtureBuilder.new

    good_spec = pdf.add(pdf.dict(:Type => :Filespec, :F => "good.txt"))
    other_spec = pdf.add(pdf.dict(:Type => :Filespec, :F => "other.txt"))
    good_leaf = pdf.add(pdf.dict(:Names => ["good.txt", pdf.ref(good_spec)]))
    other_leaf = pdf.add(pdf.dict(:Names => ["other.txt", pdf.ref(other_spec)]))
    broken_target = pdf.add("42")
    root_id = pdf.add(pdf.dict(:Kids => [
      pdf.ref(broken_target), pdf.ref(good_leaf), pdf.ref(other_leaf)
    ]))
    pages = pdf.add(pdf.dict(:Type => :Pages, :Kids => [], :Count => 0))
    catalog = pdf.add(pdf.dict(:Type => :Catalog, :Pages => pdf.ref(pages)))

    reader = PDF::Reader.new(pdf.render_io(catalog))
    [reader, PDF::Reader::Reference.new(root_id, 0)]
  end

  it "yields name/value pairs in tree order and tolerates broken kids" do
    reader, root = build_reader
    tree = PDF::Reader::NameTree.new(reader.objects, root)

    pairs = tree.map { |name, value| [name, value] }

    expect(pairs.map(&:first)).to eq(["good.txt", "other.txt"])
    expect(pairs.map { |_, value| value }).to all(be_a(PDF::Reader::Reference))
  end

  it "supports enumeration without a block" do
    reader, root = build_reader
    enum = PDF::Reader::NameTree.new(reader.objects, root).each

    expect(enum).to be_an(Enumerator)
    names = []
    enum.each { |name, _value| names << name }
    expect(names).to eq(["good.txt", "other.txt"])
  end

  it "returns nothing for a missing root" do
    reader, _root = build_reader
    pairs = PDF::Reader::NameTree.new(reader.objects, nil).to_a

    expect(pairs).to eq([])
  end
end

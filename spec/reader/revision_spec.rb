# typed: false
# coding: utf-8

describe PDF::Reader do
  include IncrementalPdfHelper

  let(:snapshots) { incremental_pdf }
  let(:incremental_data) { snapshots[0] }
  let(:standalone_data) { snapshots[1..3] }
  let(:reader) { PDF::Reader.new(StringIO.new(incremental_data)) }

  def snapshot(reader)
    [
      reader.page_count,
      reader.page(1).text,
      reader.objects.trailer[:Root].gen,
      reader.objects.trailer.key?(:Info),
      reader.objects[1].is_a?(Hash),
      reader.objects[7].is_a?(Hash) ? reader.objects[7][:BaseFont] : nil
    ]
  end

  it "keeps the default reader on the latest revision" do
    expect(reader.revision_number).to eq(3)
    expect(reader.page(1).text).to eq("object stream page")
  end

  it "exposes every incremental revision" do
    expect(reader.revisions.map(&:revision_number)).to eq([1, 2, 3])
    expect(reader.revisions.map { |revision| revision.page(1).text }).to eq([
      "old page",
      "replaced page",
      "object stream page"
    ])
  end

  it "supports selecting a revision with a negative index" do
    expect(reader.revision(-2).revision_number).to eq(2)
    expect(reader.revision(-1).page(1).text).to eq("object stream page")
  end

  it "rejects a revision outside the Prev chain" do
    expect { reader.revision(3) }.to raise_error(RangeError)
  end

  it "matches the data read from each independently saved file" do
    expected = standalone_data.map do |data|
      standalone = PDF::Reader.new(StringIO.new(data))
      snapshot(standalone)
    end

    actual = reader.revisions.map { |revision| snapshot(revision) }

    expect(actual).to eq(expected)
  end

  it "uses the trailer and effective object generation for each revision" do
    first = reader.revision(0)
    second = reader.revision(1)
    third = reader.revision(2)

    expect(first.objects.trailer[:Root]).to eq(PDF::Reader::Reference.new(2, 0))
    expect(second.objects.trailer[:Root]).to eq(PDF::Reader::Reference.new(2, 1))
    expect(third.objects.trailer[:Root]).to eq(PDF::Reader::Reference.new(2, 2))

    expect(first.objects[2][:Pages]).to eq(PDF::Reader::Reference.new(3, 0))
    expect(second.objects[2][:Pages]).to eq(PDF::Reader::Reference.new(3, 1))
    expect(third.objects[2][:Pages]).to eq(PDF::Reader::Reference.new(3, 2))
  end

  it "honours free entries and generation changes" do
    first = reader.revision(0)
    second = reader.revision(1)
    third = reader.revision(2)

    expect(first.objects[1][:Title]).to eq("old info")
    expect(first.objects[5]).to be_a(PDF::Reader::Stream)

    expect(second.objects[1]).to be_nil
    expect(second.objects[5]).to be_nil
    expect(second.objects[6]).to be_a(PDF::Reader::Stream)
    expect(second.objects.send(:xref).free?(1)).to eq(true)
    expect { second.objects.send(:xref)[PDF::Reader::Reference.new(1, 0)] }.to raise_error(
      PDF::Reader::InvalidObjectError
    )

    expect(third.objects[6]).to be_nil
    expect(third.objects.send(:xref).free?(6)).to eq(true)
    expect { third.objects.send(:xref)[PDF::Reader::Reference.new(6, 0)] }.to raise_error(
      PDF::Reader::InvalidObjectError
    )
  end

  it "reads compressed objects from a revision-scoped object stream via a hybrid xref" do
    third = reader.revision(2)

    expect(third.objects.send(:xref)[PDF::Reader::Reference.new(7, 0)]).to eq(
      PDF::Reader::Reference.new(9, 0)
    )
    expect(third.objects[7][:Type]).to eq(:Font)
    expect(third.objects[7][:BaseFont]).to eq(:Helvetica)
    expect(third.page(1).text).to eq("object stream page")
  end

  it "allows historical views to be interleaved without sharing object caches" do
    first = reader.revision(0)
    second = reader.revision(1)
    third = reader.revision(2)

    6.times do
      expect(first.page(1).text).to eq("old page")
      expect(third.page(1).text).to eq("object stream page")
      expect(second.page(1).text).to eq("replaced page")
      expect(first.objects[2][:Pages]).to eq(PDF::Reader::Reference.new(3, 0))
      expect(third.objects[2][:Pages]).to eq(PDF::Reader::Reference.new(3, 2))
    end

    expect(first.objects.cache).not_to equal(second.objects.cache)
    expect(second.objects.cache).not_to equal(third.objects.cache)
  end

  it "does not treat bytes left at an old offset as a valid current object" do
    first = reader.revision(0)
    third = reader.revision(2)
    old_offset = first.objects.send(:xref)[PDF::Reader::Reference.new(5, 0)]

    third.objects.io.seek(old_offset)
    expect(third.objects.io.read(7)).to eq("5 0 obj")
    expect(third.objects[5]).to be_nil
  end

  it "reports a malformed Prev chain with the broken xref offset" do
    io = StringIO.new(broken_prev_pdf)

    expect { PDF::Reader.new(io) }.to raise_error(
      PDF::Reader::MalformedPDFError,
      %r{invalid /Prev chain.*offset 999999}m
    )
  end

  it "reports a malformed XRefStm reference" do
    expect { PDF::Reader.new(StringIO.new(broken_xrefstm_pdf)) }.to raise_error(
      PDF::Reader::MalformedPDFError,
      %r{invalid /XRefStm reference.*offset 999999}m
    )
  end
end

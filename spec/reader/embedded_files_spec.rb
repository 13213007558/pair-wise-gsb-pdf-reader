# typed: false
# coding: utf-8

require File.dirname(__FILE__) + "/../spec_helper"

describe PDF::Reader, "embedded files" do
  context "with a document EmbeddedFiles name tree" do
    let(:reader) { PDF::Reader.new(pdf_spec_file("embedded_files_name_tree")) }
    let(:entries) { reader.embedded_files }

    it "lists every name tree entry, including duplicates and nested kids" do
      expect(entries.size).to eq(5)
      expect(entries.map(&:name)).to match_array(
        ["report.txt", "report.txt", "shared.txt", "alias.txt", "nested.txt"]
      )
      expect(entries.map(&:scope).uniq).to eq([:document])
      expect(entries.map(&:origin).uniq).to eq([:name_tree])
    end

    it "decodes UTF-16BE names" do
      expect(entries.map(&:name)).to include("nested.txt")
    end

    it "keeps duplicate names as distinct entries readable by identity" do
      reports = entries.select { |e| e.name == "report.txt" }
      expect(reports.size).to eq(2)
      expect(reports.map(&:filespec_ref).uniq.size).to eq(2)
      expect(reports.map(&:data)).to match_array(
        ["report one contents\n", "report two contents\n"]
      )
    end

    it "preserves aliases when filespecs share one embedded stream" do
      shared = entries.select { |e| ["shared.txt", "alias.txt"].include?(e.name) }
      expect(shared.size).to eq(2)
      expect(shared.map(&:data).uniq).to eq(["shared stream contents\n"])
    end

    it "exposes UF and F filenames and prefers the UF embedded stream" do
      report = entries.find { |e| e.name == "report.txt" && e.relationship == :Data }
      expect(report.uf).to eq("report.txt")
      expect(report.f).to eq("report.txt")
      expect(report.description).to eq("first report")
      expect(report.ef_keys).to eq([:UF, :F])
      expect(report.ef_key).to eq(:UF)
    end

    it "decodes streams with supported filters" do
      report = entries.find { |e| e.name == "report.txt" && e.relationship == :Data }
      expect(report.filters).to eq([:FlateDecode])
      expect(report.status).to eq(:ok)
      expect(report.data).to eq("report one contents\n")
    end

    it "verifies Params Size and CheckSum against the content" do
      entries.each do |entry|
        expect(entry.size).to eq(entry.data.bytesize)
        expect(entry.size_valid?).to eq(true)
        expect(entry.checksum).to match(/\A[0-9a-f]{32}\z/)
        expect(entry.checksum_valid?).to eq(true)
      end
    end
  end

  context "with filespecs only reachable via AF arrays" do
    let(:reader) { PDF::Reader.new(pdf_spec_file("embedded_files_af")) }
    let(:entries) { reader.embedded_files }

    it "unifies catalog, page and object AF associations in one list" do
      expect(entries.size).to eq(6)
      expect(entries.map(&:origin).uniq).to eq([:af])
    end

    it "records the association scope of each reference" do
      by_name = entries.map { |e| [e.name, e] }.to_h
      expect(by_name["catalog.txt"].scope).to eq(:document)
      expect(by_name["page.txt"].scope).to eq(:page)
      expect(by_name["page.txt"].page).to eq(1)
      expect(by_name["object.txt"].scope).to eq(:object)
    end

    it "records the AFRelationship of each reference" do
      by_name = entries.map { |e| [e.name, e] }.to_h
      expect(by_name["catalog.txt"].relationship).to eq(:Source)
      expect(by_name["page.txt"].relationship).to eq(:Data)
      expect(by_name["object.txt"].relationship).to eq(:Supplement)
    end

    it "exposes platform specific EF entries" do
      legacy = entries.find { |e| e.name == "legacy.txt" }
      expect(legacy.ef_keys).to eq([:DOS, :Mac, :Unix])
      expect(legacy.ef_key).to eq(:DOS)
      expect(legacy.data).to eq("platform specific contents\n")
    end

    it "never follows external file references" do
      external = entries.find { |e| e.name == "external.txt" }
      expect(external.external?).to eq(true)
      expect(external.embedded?).to eq(false)
      expect(external.status).to eq(:external)
      expect(external.data).to be_nil
    end

    it "reports unknown filters as a clear status instead of raising" do
      mystery = entries.find { |e| e.name == "mystery.bin" }
      expect(mystery.filters).to eq([:FrobDecode])
      expect(mystery.status).to eq(:unknown_filter)
      expect(mystery.data).to be_nil
    end
  end

  context "with a corrupted EmbeddedFiles name tree" do
    let(:reader) { PDF::Reader.new(pdf_spec_file("embedded_files_broken_name_tree")) }
    let(:entries) { reader.embedded_files }

    it "does not raise" do
      expect { entries }.not_to raise_error
    end

    it "keeps the listing complete and explainable" do
      expect(entries.size).to eq(2)

      reachable = entries.find { |e| e.name == "reachable.txt" }
      expect(reachable.origin).to eq(:name_tree)
      expect(reachable.scope).to eq(:document)
      expect(reachable.data).to eq("reachable before the corruption\n")

      orphan = entries.find { |e| e.name == "orphan.txt" }
      expect(orphan.origin).to eq(:object_scan)
      expect(orphan.scope).to eq(:unknown)
      expect(orphan.data).to eq("orphan filespec contents\n")
    end

    it "does not list filespecs twice when they are reachable and scannable" do
      names = entries.map(&:name)
      expect(names).to eq(names.uniq)
    end
  end

  context "extraction safety" do
    let(:reader) { PDF::Reader.new(pdf_spec_file("embedded_files_name_tree")) }

    it "lets the caller decide extraction paths instead of trusting PDF names" do
      # entries expose names and content, but the gem provides no API that
      # writes files or derives filesystem paths from them
      entry = reader.embedded_files.first
      expect(entry).not_to respond_to(:save)
      expect(entry).not_to respond_to(:extract)
      expect(entry).not_to respond_to(:path)
    end

    it "returns content as inert binary strings" do
      entry = reader.embedded_files.first
      expect(entry.data).to be_a(String)
      expect(entry.data.encoding).to eq(Encoding::BINARY)
    end
  end
end

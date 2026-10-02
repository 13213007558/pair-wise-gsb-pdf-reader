# typed: false
# coding: utf-8

describe PDF::Reader, "revisions" do
  let!(:fixtures) { IncrementalPdfFixtures.build }
  let!(:full_io)  { StringIO.new(fixtures[:full]) }
  let!(:reader)   { PDF::Reader.new(full_io) }

  def standalone(key)
    PDF::Reader.new(StringIO.new(fixtures[key]))
  end

  describe "revision discovery" do
    it "counts one revision per incremental save" do
      expect(reader.revision_count).to eql(3)
    end

    it "returns one reader per revision, oldest first" do
      expect(reader.revisions.size).to eql(3)
      expect(reader.revisions.map(&:revision_number)).to eql([0, 1, 2])
    end

    it "reports a single revision for a file with no incremental saves" do
      expect(standalone(:rev1).revision_count).to eql(1)
      expect(standalone(:rev1).revision_number).to eql(0)
    end

    it "defaults to the most recent revision" do
      expect(reader.revision_number).to eql(2)
    end

    it "supports negative revision numbers counting back from the latest" do
      expect(reader.revision(-1).revision_number).to eql(2)
      expect(reader.revision(-3).revision_number).to eql(0)
    end

    it "raises ArgumentError for a revision outside the valid range" do
      expect { reader.revision(3) }.to raise_error(ArgumentError, /revision 3/)
      expect { reader.revision(-4) }.to raise_error(ArgumentError, /revision -4/)
    end

    it "accepts a revision via the constructor" do
      rev = PDF::Reader.new(StringIO.new(fixtures[:full]), :revision => 0)
      expect(rev.revision_number).to eql(0)
      expect(rev.page(1).text).to include(IncrementalPdfFixtures::REV1_PAGE_ONE)
    end
  end

  describe "reading a historical revision" do
    it "reads page one as of revision 1, before it was replaced" do
      expect(reader.revision(0).page(1).text).to include(IncrementalPdfFixtures::REV1_PAGE_ONE)
    end

    it "reads the replaced page one as of revision 2" do
      expect(reader.revision(1).page(1).text).to include(IncrementalPdfFixtures::REV2_PAGE_ONE)
    end

    it "keeps the replaced page in the latest revision" do
      expect(reader.page(1).text).to include(IncrementalPdfFixtures::REV2_PAGE_ONE)
    end

    it "reads page two, unchanged across all revisions" do
      reader.revisions.each do |rev|
        expect(rev.page(2).text).to include(IncrementalPdfFixtures::REV1_PAGE_TWO)
      end
    end

    it "uses the trailer that was current at each revision" do
      expect(reader.revision(0).objects.trailer[:Prev]).to be_nil
      expect(reader.revision(1).objects.trailer[:XRefStm]).to be_a(Integer)
      expect(reader.revision(2).objects.trailer[:Prev]).to be_a(Integer)
    end

    it "reads the Info dict as of each revision" do
      expect(reader.revision(0).info).to eql(:Producer => "incremental fixture")
      expect(reader.revision(1).info.keys).to contain_exactly(:Producer, :Custom)
      expect(reader.revision(2).info.keys).to contain_exactly(:Producer, :Custom, :Custom2)
    end
  end

  describe "deleted objects and free entries" do
    it "reads object 8 in revision 1" do
      expect(reader.revision(0).objects[8]).to eql(IncrementalPdfFixtures::DELETED_OBJECT)
    end

    it "treats object 8 as deleted from revision 2 onwards" do
      expect(reader.revision(1).objects[8]).to be_nil
      expect(reader.revision(1).objects.has_key?(8)).to be false
      expect(reader.revision(2).objects[PDF::Reader::Reference.new(8, 0)]).to be_nil
    end

    it "does not let the latest revision see the deleted generation 0 object" do
      expect(reader.objects[8]).to be_nil
    end
  end

  describe "generation changes" do
    it "sees object 8 as generation 0 in revision 1" do
      rev = reader.revision(0)
      expect(rev.objects[PDF::Reader::Reference.new(8, 0)]).to eql(IncrementalPdfFixtures::DELETED_OBJECT)
    end

    it "sees the reincarnated generation 1 object in revision 3" do
      rev = reader.revision(2)
      expect(rev.objects[PDF::Reader::Reference.new(8, 1)]).to eql(IncrementalPdfFixtures::REINCARNATED)
    end

    it "does not leak the reincarnated object into earlier revisions" do
      expect(reader.revision(0).objects[PDF::Reader::Reference.new(8, 1)]).to be_nil
      expect(reader.revision(1).objects[PDF::Reader::Reference.new(8, 1)]).to be_nil
    end
  end

  describe "hybrid xref stream entries" do
    it "reads object 11, only reachable via the /XRefStm stream, from revision 2" do
      expect(reader.revision(1).objects[11]).to eql(IncrementalPdfFixtures::HYBRID_OBJECT)
    end

    it "does not leak object 11 into revision 1" do
      expect(reader.revision(0).objects[11]).to be_nil
    end
  end

  describe "object streams" do
    it "reads objects embedded in the object stream added by revision 3" do
      rev = reader.revision(2)
      expect(rev.objects[14]).to eql(IncrementalPdfFixtures::OBJSTM_STRING)
      expect(rev.objects[15]).to eql([1, 2, 3])
    end

    it "resolves Info entries that point into the object stream" do
      info = reader.revision(2).info
      expect(reader.revision(2).objects.deref(info[:Custom2])).to eql(IncrementalPdfFixtures::OBJSTM_STRING)
    end

    it "does not leak object stream objects into earlier revisions" do
      expect(reader.revision(0).objects[14]).to be_nil
      expect(reader.revision(1).objects[14]).to be_nil
    end
  end

  describe "comparison with standalone saves" do
    it "matches the standalone revision 1 file" do
      expect(reader.revision(0).pages.map(&:text)).to eql(standalone(:rev1).pages.map(&:text))
      expect(reader.revision(0).info).to eql(standalone(:rev1).info)
    end

    it "matches the standalone revision 2 file" do
      expect(reader.revision(1).pages.map(&:text)).to eql(standalone(:rev2).pages.map(&:text))
      expect(reader.revision(1).info).to eql(standalone(:rev2).info)
      expect(reader.revision(1).objects[11]).to eql(standalone(:rev2).objects[11])
    end

    it "matches the standalone revision 3 file" do
      expect(reader.revision(2).pages.map(&:text)).to eql(standalone(:rev3).pages.map(&:text))
      expect(reader.revision(2).info).to eql(standalone(:rev3).info)
      expect(reader.revision(2).objects[14]).to eql(standalone(:rev3).objects[14])
      expect(reader.revision(2).objects[PDF::Reader::Reference.new(8, 1)]).to(
        eql(standalone(:rev3).objects[PDF::Reader::Reference.new(8, 1)])
      )
    end

    it "contains every object of each standalone save with identical content" do
      reader.revisions.each_with_index do |rev, idx|
        solo = standalone([:rev1, :rev2, :rev3][idx])
        solo.objects.each do |ref, value|
          # xref stream objects are serialisation artifacts, not logical content
          next if value.is_a?(PDF::Reader::Stream) && value.hash[:Type] == :XRef

          actual = rev.objects[ref]
          if value.is_a?(PDF::Reader::Stream)
            expect(actual.unfiltered_data).to eql(value.unfiltered_data),
              "stream #{ref.id} #{ref.gen} differs between revision #{idx} and its standalone save"
          else
            expect(actual).to eql(value),
              "object #{ref.id} #{ref.gen} differs between revision #{idx} and its standalone save"
          end
        end
      end
    end
  end

  describe "interleaved access" do
    it "allows revision views to be used interchangeably" do
      revs = reader.revisions
      results = [0, 2, 1, 2, 0, 1].map { |idx| revs[idx].page(1).text }
      expect(results).to match([
        include(IncrementalPdfFixtures::REV1_PAGE_ONE),
        include(IncrementalPdfFixtures::REV2_PAGE_ONE),
        include(IncrementalPdfFixtures::REV2_PAGE_ONE),
        include(IncrementalPdfFixtures::REV2_PAGE_ONE),
        include(IncrementalPdfFixtures::REV1_PAGE_ONE),
        include(IncrementalPdfFixtures::REV2_PAGE_ONE),
      ])
    end

    it "keeps Info views consistent when accessed out of order" do
      revs = reader.revisions
      expect(revs[2].info.keys).to include(:Custom2)
      expect(revs[0].info.keys).not_to include(:Custom)
      expect(revs[1].info.keys).to include(:Custom)
      expect(revs[0].info.keys).not_to include(:Custom2)
    end
  end

  describe "cache isolation between revisions" do
    it "does not serve objects cached by the latest revision to older views" do
      latest = reader.revision(2)
      oldest = reader.revision(0)

      # warm the latest revision's caches, then read the oldest revision
      latest.page(1).text
      latest.info

      expect(oldest.page(1).text).to include(IncrementalPdfFixtures::REV1_PAGE_ONE)
      expect(oldest.objects[3][:Contents]).to eql(PDF::Reader::Reference.new(5, 0))
      expect(latest.objects[3][:Contents]).to eql(PDF::Reader::Reference.new(10, 0))
    end

    it "does not mistake identical byte offsets for the same logical version" do
      # object 5 sits at the same byte offset in every revision and must read
      # identically, while object 3 moved and must differ between revisions
      revs = reader.revisions
      expect(revs[0].objects[5].unfiltered_data).to include(IncrementalPdfFixtures::REV1_PAGE_ONE)
      expect(revs[2].objects[5].unfiltered_data).to include(IncrementalPdfFixtures::REV1_PAGE_ONE)
      expect(revs[0].objects[3]).not_to eql(revs[2].objects[3])
    end

    it "gives each revision view its own object cache" do
      caches = reader.revisions.map { |rev| rev.instance_variable_get(:@cache) }
      expect(caches.uniq.size).to eql(3)
    end
  end

  describe "broken /Prev chain" do
    it "raises a descriptive error" do
      broken = StringIO.new(IncrementalPdfFixtures.build_with_broken_prev)
      expect { PDF::Reader.new(broken) }.to raise_error(
        PDF::Reader::MalformedPDFError, %r{broken xref chain.*\/Prev}
      )
    end
  end
end

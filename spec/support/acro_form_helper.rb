# typed: false
# coding: utf-8

require "stringio"

module AcroFormHelper
  def acro_form_pdf(kind)
    AcroFormFixture.pdf(kind)
  end

  def acro_form_reader(kind)
    PDF::Reader.new(StringIO.new(acro_form_pdf(kind)))
  end

  class AcroFormFixture
    Stream = Struct.new(:dictionary, :data)

    def self.pdf(kind)
      builder = new
      builder.public_send("build_#{kind}")
      builder.to_pdf
    end

    def initialize
      @objects = {}
    end

    def ref(id)
      PDF::Reader::Reference.new(id, 0)
    end

    def object(id, value)
      @objects[id] = value
      ref(id)
    end

    def stream(id, data = "q\nQ\n")
      object(id, Stream.new({ :Length => data.bytesize }, data))
    end

    def build_merged
      page_one = object(3, {
        :Type => :Page,
        :Parent => ref(2),
        :MediaBox => [0, 0, 612, 792],
        :Annots => [ref(10), ref(11), ref(15), ref(17)],
      })
      page_two = object(4, {
        :Type => :Page,
        :Parent => ref(2),
        :MediaBox => [0, 0, 612, 792],
        :Annots => [],
      })
      pages = object(2, {
        :Type => :Pages,
        :Kids => [page_one, page_two],
        :Count => 2,
      })

      yes = stream(20, "yes appearance\n")
      off = stream(21, "off appearance\n")

      object(10, {
        :Type => :Annot,
        :Subtype => :Widget,
        :FT => :Tx,
        :T => "Name",
        :TU => "Full name",
        :V => "Ada",
        :DV => "",
        :Ff => 4096,
        :DA => "/Helv 12 Tf 0 g",
        :Q => 1,
        :Rect => [10, 700, 200, 720],
        :F => 4,
        :P => page_one,
        :AA => { :K => { :S => :JavaScript, :JS => "app.alert('never run')" } },
      })

      object(11, {
        :Type => :Annot,
        :Subtype => :Widget,
        :FT => :Btn,
        :T => "Agree",
        :V => :Yes,
        :AS => :Yes,
        :AP => { :N => { :Yes => yes, :Off => off } },
        :Rect => [10, 650, 30, 670],
        :F => 4,
        :P => page_one,
      })

      object(15, {
        :Type => :Annot,
        :Subtype => :Widget,
        :FT => :Ch,
        :T => "Tags",
        :Ff => 2_097_152,
        :Opt => [["ruby", "Ruby"], "pdf"],
        :V => ["ruby", "pdf"],
        :DA => "/Helv 10 Tf 0 g",
        :Rect => [10, 600, 220, 620],
        :F => 4,
        :P => page_one,
      })

      object(16, { :FT => :Tx, :T => "Contact", :Kids => [ref(17)] })
      object(17, {
        :Type => :Annot,
        :Subtype => :Widget,
        :Parent => ref(16),
        :T => "City",
        :V => "Shanghai",
        :Rect => [10, 550, 220, 570],
        :F => 4,
        :P => page_one,
      })

      form = object(5, {
        :Fields => [ref(10), ref(11), ref(15), ref(16)],
        :DA => "/Helv 0 Tf 0 g",
        :NeedAppearances => false,
      })
      object(1, { :Type => :Catalog, :Pages => pages, :AcroForm => form })
    end

    def build_separate
      page_one = object(3, {
        :Type => :Page,
        :Parent => ref(2),
        :MediaBox => [0, 0, 612, 792],
        :Annots => [ref(11), ref(21), ref(31), ref(41), ref(51)],
      })
      page_two = object(4, {
        :Type => :Page,
        :Parent => ref(2),
        :MediaBox => [0, 0, 612, 792],
        :Annots => [ref(12), ref(32)],
      })
      pages = object(2, {
        :Type => :Pages,
        :Kids => [page_one, page_two],
        :Count => 2,
      })

      on_red_one = stream(33)
      on_blue_two = stream(34)
      off_state = stream(35)

      object(10, {
        :FT => :Tx,
        :T => "Repeated",
        :V => "Ada",
        :DA => "/Helv 12 Tf 0 g",
        :Kids => [ref(11), ref(12)],
      })
      object(11, {
        :Type => :Annot,
        :Subtype => :Widget,
        :Parent => ref(10),
        :Rect => [10, 700, 200, 720],
        :F => 4,
        :P => page_one,
      })
      object(12, {
        :Type => :Annot,
        :Subtype => :Widget,
        :Parent => ref(10),
        :Rect => [10, 700, 200, 720],
        :F => 4,
        :P => page_two,
      })

      object(20, {
        :FT => :Btn,
        :T => "Agree",
        :V => :Off,
        :Kids => [ref(21)],
      })
      object(21, {
        :Type => :Annot,
        :Subtype => :Widget,
        :Parent => ref(20),
        :AS => :Yes,
        :AP => { :N => { :Yes => stream(22), :Off => stream(23) } },
        :Rect => [10, 650, 30, 670],
        :F => 4,
        :P => page_one,
      })

      object(30, {
        :FT => :Btn,
        :Ff => 32_768,
        :T => "Color",
        :V => :red,
        :Kids => [ref(31), ref(32)],
      })
      object(31, {
        :Type => :Annot,
        :Subtype => :Widget,
        :Parent => ref(30),
        :AS => :red,
        :AP => { :N => { :Off => off_state, :red => on_red_one } },
        :Rect => [10, 600, 30, 620],
        :F => 4,
        :P => page_one,
      })
      object(32, {
        :Type => :Annot,
        :Subtype => :Widget,
        :Parent => ref(30),
        :AS => :blue,
        :AP => { :N => { :Off => off_state, :blue => on_blue_two } },
        :Rect => [10, 600, 30, 620],
        :F => 4,
        :P => page_two,
      })

      object(40, {
        :FT => :Ch,
        :Ff => 2_097_152,
        :T => "Tags",
        :Opt => [["ruby", "Ruby"], ["pdf", "PDF"]],
        :V => ["ruby"],
        :Kids => [ref(41)],
      })
      object(41, {
        :Type => :Annot,
        :Subtype => :Widget,
        :Parent => ref(40),
        :Rect => [10, 550, 220, 570],
        :F => 4,
        :P => page_one,
      })

      object(50, {
        :FT => :Tx,
        :T => "Contact",
        :V => "Parent",
        :Kids => [ref(51)],
      })
      object(51, {
        :Type => :Annot,
        :Subtype => :Widget,
        :Parent => ref(50),
        :T => "Email",
        :V => "child@example.com",
        :Rect => [10, 500, 220, 520],
        :F => 4,
        :P => page_one,
      })

      form = object(5, {
        :Fields => [ref(10), ref(20), ref(30), ref(40), ref(50)],
        :DA => "/Helv 9 Tf 0 g",
        :NeedAppearances => false,
      })
      object(1, { :Type => :Catalog, :Pages => pages, :AcroForm => form })
    end

    def build_malformed
      page = object(3, {
        :Type => :Page,
        :Parent => ref(2),
        :MediaBox => [0, 0, 612, 792],
        :Annots => [ref(71), ref(81), ref(91), ref(96), ref(101)],
      })
      pages = object(2, { :Type => :Pages, :Kids => [page], :Count => 1 })

      object(50, { :FT => :Tx, :T => "Loop", :Kids => [ref(50)] })
      object(60, { :FT => :Tx, :T => "Duplicate", :Kids => [] })
      object(61, { :FT => :Tx, :T => "Duplicate", :Kids => [] })

      object(70, { :FT => :Tx, :T => "OrphanField", :Kids => [] })
      object(71, {
        :Type => :Annot,
        :Subtype => :Widget,
        :Rect => [1, 2, 3, 4],
        :P => page,
      })

      object(80, { :FT => :Tx, :T => "WrongParent", :Kids => [ref(81)] })
      object(81, {
        :Type => :Annot,
        :Subtype => :Widget,
        :Parent => ref(99),
        :Rect => [1, 2, 3, 4],
        :P => page,
      })

      object(90, { :FT => :Tx, :T => "MissingParent", :Kids => [ref(91)] })
      object(91, {
        :Type => :Annot,
        :Subtype => :Widget,
        :Rect => [1, 2, 3, 4],
        :P => page,
      })

      object(95, { :FT => :Btn, :T => "BadAppearance", :V => :Yes, :Kids => [ref(96)] })
      object(96, {
        :Type => :Annot,
        :Subtype => :Widget,
        :Parent => ref(95),
        :AS => :Maybe,
        :AP => { :N => { :Yes => stream(97), :Off => stream(98) } },
        :Rect => [1, 2, 3, 4],
        :P => page,
      })

      object(100, { :FT => :Btn, :T => "MissingState", :V => :Maybe, :Kids => [ref(101)] })
      object(101, {
        :Type => :Annot,
        :Subtype => :Widget,
        :Parent => ref(100),
        :AP => { :N => { :Yes => stream(102), :Off => stream(103) } },
        :Rect => [1, 2, 3, 4],
        :P => page,
      })

      form = object(5, {
        :Fields => [
          ref(50),
          ref(60),
          ref(61),
          ref(80),
          ref(90),
          ref(95),
          ref(100),
        ],
      })
      object(1, { :Type => :Catalog, :Pages => pages, :AcroForm => form })
    end

    def to_pdf
      output = +"%PDF-1.4\n"
      offsets = { 0 => 0 }

      @objects.keys.sort.each do |id|
        offsets[id] = output.bytesize
        output << "#{id} 0 obj\n"
        output << serialize(@objects[id])
        output << "\nendobj\n"
      end

      xref_offset = output.bytesize
      output << "xref\n0 #{@objects.keys.max + 1}\n"
      output << "0000000000 65535 f \n"
      (1..@objects.keys.max).each do |id|
        offset = offsets.fetch(id, 0)
        output << format("%010d 00000 n \n", offset)
      end
      output << "trailer\n"
      output << "<< /Size #{@objects.keys.max + 1} /Root 1 0 R >>\n"
      output << "startxref\n#{xref_offset}\n%%EOF\n"
      output
    end

    private

    def serialize(value)
      case value
      when PDF::Reader::Reference then "#{value.id} 0 R"
      when Symbol then "/#{value}"
      when String then "(#{escape(value)})"
      when Array then "[#{value.map { |item| serialize(item) }.join(" ")}]"
      when Hash
        entries = value.map { |key, item| "/#{key} #{serialize(item)}" }.join(" ")
        "<< #{entries} >>"
      when Stream
        entries = value.dictionary.map { |key, item| "/#{key} #{serialize(item)}" }.join(" ")
        "<< #{entries} >>\nstream\n#{value.data}endstream"
      when true then "true"
      when false then "false"
      when nil then "null"
      else value.to_s
      end
    end

    def escape(value)
      value.gsub("\\", "\\\\").gsub("(", "\\(").gsub(")", "\\)")
    end
  end
end

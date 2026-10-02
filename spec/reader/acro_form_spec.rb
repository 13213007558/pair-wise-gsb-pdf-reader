# typed: false
# coding: utf-8

describe PDF::Reader::AcroForm do
  include AcroFormHelper

  subject(:form) { reader.acroform }

  let(:reader) { acro_form_reader(:merged) }

  describe "merged field and widget dictionaries" do
    it "lists text fields by full name with inherited configuration" do
      field = form.field("Name")

      expect(field).to be_a(PDF::Reader::AcroForm::Field)
      expect(field.type).to eq(:text)
      expect(field.field_type).to eq(:Tx)
      expect(field.name).to eq("Name")
      expect(field.value).to eq("Ada")
      expect(field.default_value).to eq("")
      expect(field.config[:TU]).to eq("Full name")
      expect(field.config[:DA]).to eq("/Helv 12 Tf 0 g")
      expect(field.config[:Q]).to eq(1)
      expect(field.flags[:multiline]).to eq(true)
    end

    it "exposes inherited root-level form configuration" do
      expect(form.config[:DA]).to eq("/Helv 0 Tf 0 g")
      expect(form.field("Tags").config[:DA]).to eq("/Helv 10 Tf 0 g")
    end

    it "does not expose or execute form JavaScript" do
      field = form.field("Name")

      expect(field.config).not_to have_key(:AA)
      expect(field.widgets.first.config).not_to have_key(:AA)
      expect(acro_form_pdf(:merged)).to include("app.alert")
    end

    it "reads a merged checkbox value and appearance states" do
      field = form.field("Agree")
      widget = field.widgets.first

      expect(field.type).to eq(:checkbox)
      expect(field.value).to eq(true)
      expect(widget.state).to eq(:Yes)
      expect(widget.appearance_states).to eq([:Yes, :Off])
      expect(widget.appearances[:N][:Yes].data).to eq("yes appearance\n")
      expect(widget.page).to eq(1)
      expect(widget.rect).to eq([10, 650, 30, 670])
    end

    it "reads a multi-select choice field" do
      field = form.field("Tags")

      expect(field.type).to eq(:choice)
      expect(field.flags[:multi_select]).to eq(true)
      expect(field.value).to eq(["ruby", "pdf"])
      expect(field.selected_labels).to eq(["Ruby", "pdf"])
      expect(field.options).to eq([
        { :value => "ruby", :label => "Ruby" },
        { :value => "pdf", :label => "pdf" },
      ])
    end

    it "builds full names through parent fields" do
      field = form.field("Contact.City")

      expect(field.type).to eq(:text)
      expect(field.value).to eq("Shanghai")
      expect(field.config[:DA]).to eq("/Helv 0 Tf 0 g")
      expect(field.widgets.map(&:page)).to eq([1])
    end
  end

  describe "separate field and widget dictionaries" do
    let(:reader) { acro_form_reader(:separate) }

    it "keeps widgets across pages attached to one field" do
      field = form.field("Repeated")

      expect(form.fields.count { |item| item.name == "Repeated" }).to eq(1)
      expect(field.type).to eq(:text)
      expect(field.value).to eq("Ada")
      expect(field.widgets.size).to eq(2)
      expect(field.widgets.map(&:page)).to eq([1, 2])
      expect(field.widgets.map(&:rect)).to eq([
        [10, 700, 200, 720],
        [10, 700, 200, 720],
      ])
    end

    it "preserves a field V and widget AS conflict" do
      field = form.field("Agree")

      expect(field.type).to eq(:checkbox)
      expect(field.value).to be_nil
      expect(field.conflicts.map { |item| item[:code] }).to eq([
        :inconsistent_field_value,
      ])
      expect(field.value_sources.map { |item| item[:source] }).to include(:V, :AS, :AP)
      expect(field.widgets.first.state).to eq(:Yes)
      expect(field.widgets.first.appearance_states).to eq([:Yes, :Off])
    end

    it "reads radio groups and reports conflicting active widget states" do
      field = form.field("Color")

      expect(field.type).to eq(:radio)
      expect(field.flags[:radio]).to eq(true)
      expect(field.value).to be_nil
      expect(field.widgets.map { |widget| [widget.page, widget.state] }).to eq([
        [1, :red],
        [2, :blue],
      ])
      expect(field.conflicts.map { |item| item[:code] }).to include(
        :inconsistent_field_value,
        :multiple_radio_states,
      )
    end

    it "reads a separate multi-select choice field" do
      field = form.field("Tags")

      expect(field.flags[:multi_select]).to eq(true)
      expect(field.value).to eq(["ruby"])
      expect(field.selected_labels).to eq(["Ruby"])
      expect(field.widgets.map(&:page)).to eq([1])
    end

    it "keeps conflicting parent and child field values as separate evidence" do
      field = form.field("Contact.Email")

      expect(field.value).to be_nil
      expect(field.value_sources.select { |source| source[:source] == :V }).to eq([
        { :source => :V, :object => "50:0 R", :value => "Parent" },
        { :source => :V, :object => "51:0 R", :value => "child@example.com" },
      ])
      expect(field.conflicts.map { |item| item[:code] }).to include(
        :inconsistent_field_value
      )
    end
  end

  describe "diagnostics" do
    let(:reader) { acro_form_reader(:malformed) }

    it "diagnoses cycles, duplicate names, parent errors, and orphan widgets" do
      codes = form.diagnostics.map { |item| item[:code] }

      expect(codes).to include(:kid_cycle)
      expect(codes).to include(:duplicate_full_name)
      expect(codes).to include(:parent_mismatch)
      expect(codes).to include(:missing_parent)
      expect(codes).to include(:orphan_widget)
    end

    it "keeps duplicate field trees as distinct fields" do
      expect(form.fields.count { |field| field.name == "Duplicate" }).to eq(2)
      expect(form.field("Duplicate").diagnostics).to include(
        hash_including(:code => :duplicate_full_name)
      )
    end

    it "reports an AS state that is absent from AP" do
      field = form.field("BadAppearance")

      expect(field.value).to be_nil
      expect(field.conflicts.map { |item| item[:code] }).to include(
        :missing_appearance_state
      )
    end

    it "reports a field state absent from AP when no AS is present" do
      field = form.field("MissingState")

      expect(field.value).to be_nil
      expect(field.conflicts.map { |item| item[:code] }).to include(
        :missing_appearance_state
      )
    end

    it "preserves an orphan widget without crashing" do
      widget = form.widgets.find { |item|
        item.object_reference == "71:0 R" && item.diagnostics.any? {
          |diagnostic| diagnostic[:code] == :orphan_widget
        }
      }

      expect(widget).to be_a(PDF::Reader::AcroForm::Widget)
      expect(widget.page).to eq(1)
      expect(widget.rect).to eq([1, 2, 3, 4])
    end
  end

  describe "documents without AcroForm" do
    let(:reader) { PDF::Reader.new(pdf_spec_file("minimal")) }

    it "returns nil" do
      expect(form).to be_nil
    end
  end
end

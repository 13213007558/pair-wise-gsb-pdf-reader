# typed: false
# coding: utf-8

describe PDF::Reader::AcroForm do
  let(:merged) { PDF::Reader.new(pdf_spec_file("acroform/merged_dicts")) }
  let(:separated) { PDF::Reader.new(pdf_spec_file("acroform/separated_dicts")) }
  let(:malformed) { PDF::Reader.new(pdf_spec_file("acroform/malformed_fields")) }

  describe "merged field and widget dictionaries" do
    let(:form) { merged.acroform }

    it "lists terminal fields by their fully qualified names and types" do
      expect(form.fields.map(&:name)).to eql([
        "shared.text", "merged.checkbox", "merged.choices"
      ])
      expect(form.field_names).to eql([
        "shared.text", "merged.checkbox", "merged.choices"
      ])
      expect(form.fields.map(&:type)).to eql([:text, :checkbox, :choice])
    end

    it "exposes inherited AcroForm configuration" do
      expect(form.field("shared.text").config[:DA]).to eql("/Helv 0 Tf 0 g")
      expect(form.field("shared.text").config[:FT]).to eql(:Tx)
    end

    it "reads text fields and associates one widget with multiple pages" do
      field = form.field("shared.text")

      expect(field.logical_value).to eql("shared value")
      expect(field.widgets.size).to eql(1)
      expect(field.page_numbers).to eql([1, 2])
      expect(field.widgets.first.page_numbers).to eql([1, 2])
    end

    it "preserves checkbox V and AS conflicts instead of choosing one" do
      field = form.field("merged.checkbox")

      expect(field.raw_value).to eql(:Yes)
      expect(field.logical_value).to eql(true)
      expect(field.widgets.first.state).to eql(:off)
      expect(field.widgets.first.appearance_states).to eql([:Yes, :Off])
      expect(field.state.field_value).to eql(:Yes)
      expect(field).to be_conflict
      expect(field.conflicts.first[:code]).to eql(:value_conflict)
    end

    it "reads multi-select choice values" do
      field = form.field("merged.choices")

      expect(field).to be_multiple
      expect(field.logical_value).to eql([:red, :blue])
      expect(field.options.map { |option| option[:value] }).to eql([:red, :blue])
    end
  end

  describe "separated field and widget dictionaries" do
    let(:form) { separated.acroform }

    it "reads text, radio and multi-select choice fields" do
      expect(form.fields.map(&:name)).to eql([
        "separated.text", "separated.radio", "separated.choices", "group.nested"
      ])
      expect(form.fields.map(&:type)).to eql([:text, :radio, :choice, :text])
      expect(form.field("separated.text").logical_value).to eql("separate value")
      expect(form.field("separated.choices").logical_value).to eql([:alpha, :beta])
      expect(form.field("group.nested").logical_value).to eql("nested value")
    end

    it "keeps radio group widgets attached to one field" do
      field = form.field("separated.radio")

      expect(field).to be_radio
      expect(field.widgets.size).to eql(2)
      expect(field.widgets.map(&:page_numbers)).to eql([[1], [1]])
      expect(field.logical_value).to eql(:Yes)
      expect(field.state.appearance_value).to eql(:No)
      expect(field.state.conflicts.first[:field_value]).to eql(:Yes)
    end

    it "keeps widget annotations distinct from field configuration" do
      widget = form.field("separated.text").widgets.first

      expect(widget.reference).to eql(PDF::Reader::Reference.new(6, 0))
      expect(widget.page_number).to eql(1)
      expect(widget.page).to be_a(PDF::Reader::Page)
      expect(widget.page.number).to eql(1)
      expect(widget.rect).to eql([10, 10, 110, 40])
    end

    it "exposes inherited radio and multi-select flags" do
      expect(form.field("separated.radio").flags & (1 << 15)).not_to eql(0)
      expect(form.field("separated.choices").flags & (1 << 20)).not_to eql(0)
    end
  end

  describe "structural diagnostics" do
    let(:form) { malformed.acroform }

    it "does not raise for cyclic Kids, duplicate names or missing Parents" do
      expect { form.fields }.not_to raise_error
      expect(form.fields.map(&:name)).to eql([
        "same", "same", "bad.appearance"
      ])
    end

    it "reports the malformed relationships" do
      codes = form.diagnostics.map { |diagnostic| diagnostic[:code] }

      expect(codes).to include(:cyclic_kids)
      expect(codes).to include(:missing_parent)
      expect(codes).to include(:duplicate_field_name)
      expect(codes).to include(:invalid_appearance_state)
    end

    it "keeps duplicate full names queryable" do
      expect(form.fields_by_name["same"].size).to eql(2)
      expect(form["same"].name).to eql("same")
    end

    it "leaves orphan widgets outside the field collection" do
      assigned = form.fields.flat_map(&:widgets).map(&:reference)

      expect(assigned).not_to include(PDF::Reader::Reference.new(11, 0))
      expect(form.widgets.map(&:reference)).to include(PDF::Reader::Reference.new(11, 0))
    end
  end

  describe "documents without AcroForm" do
    it "returns an empty form" do
      form = PDF::Reader.new(pdf_spec_file("minimal")).acroform

      expect(form.fields).to eql([])
      expect(form.diagnostics).to eql([])
    end
  end

  describe PDF::Reader do
    it "supports form as a short alias for acroform" do
      reader = PDF::Reader.new(pdf_spec_file("acroform/merged_dicts"))

      expect(reader.form).to be(reader.acroform)
    end
  end
end

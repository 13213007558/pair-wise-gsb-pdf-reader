# typed: false
# coding: utf-8

require 'zlib'
require 'stringio'

# A minimal PDF writer for the image decoding specs. Every object is
# written in the order it is added and references are plain object ids, so
# hand calculated byte streams and masks can be placed exactly where the
# specs need them. No external PDF renderer is involved.
class PdfImageBuilder
  attr_reader :objects

  def initialize
    @bodies = {}
    @sequence = 0
    @root_id = nil
  end

  # Add an object body (a dictionary string, a stream body built with
  # .stream, etc) and return its object id.
  def add(body)
    @sequence += 1
    @bodies[@sequence] = body
    @sequence
  end

  # Reserve the next object id without writing a body yet. Useful when a
  # dictionary needs to reference an object that is added later.
  def reserve
    @sequence += 1
  end

  # Assign a body to an id returned by .reserve.
  def set(id, body)
    @bodies[id] = body
    id
  end

  def ref(id)
    "#{id} 0 R"
  end

  def dict(content)
    "<< #{content} >>"
  end

  # Build a stream object body. Data is Flate compressed by default so the
  # specs exercise the filter pipeline; pass :raw => true to embed bytes
  # verbatim (the caller must declare its own /Filter in the content).
  def stream(content, data, flate: true, raw: false, decode_parms: nil)
    encoded = raw ? data : (flate ? Zlib::Deflate.deflate(data) : data)
    entries = "#{content} /Length #{encoded.bytesize}"
    entries << " /Filter /FlateDecode" unless raw || !flate
    entries << " /DecodeParms #{decode_parms}" if decode_parms
    "<< #{entries} >>\nstream\n#{encoded}\nendstream"
  end

  # Wrap bytes as a PDF hex string, e.g. <FF0080>.
  def hex(bytes)
    "<#{bytes.bytes.map { |byte| '%02X' % byte }.join}>"
  end

  # Standard page that draws one or more named XObjects.
  def page(pages_id, resources, contents, extras = "")
    dict("/Type /Page /Parent #{ref(pages_id)} /MediaBox [0 0 100 100] " \
         "/Resources #{resources} /Contents #{ref(contents)} #{extras}")
  end

  def pages(page_ids)
    kids = page_ids.map { |id| ref(id) }.join(" ")
    dict("/Type /Pages /Kids [#{kids}] /Count #{page_ids.length}")
  end

  def catalog(pages_id)
    @root_id = @sequence + 1
    dict("/Type /Catalog /Pages #{ref(pages_id)}")
  end

  # Content stream that draws one or more XObject labels at 10pt.
  def draw_content(labels, flate: false)
    operations = labels.map { |label| "q 10 0 0 10 0 0 cm /#{label} Do Q" }.join("\n")
    add(stream("", operations, flate: flate))
  end

  # A form XObject that draws an image, optionally defining its own
  # XObject resources (used to test image reuse across forms).
  def form(image_refs, bbox: "0 0 10 10")
    resources = xobject_resources(image_refs)
    operations = image_refs.keys.map {
      |label| "q 10 0 0 10 0 0 cm /#{label} Do Q"
    }.join("\n")
    add(stream(
      "/Type /XObject /Subtype /Form /BBox [#{bbox}] /Resources #{resources}",
      operations,
      flate: false
    ))
  end

  def xobject_resources(image_refs)
    entries = image_refs.map { |label, id| "/#{label} #{ref(id)}" }.join(" ")
    dict("/XObject << #{entries} >>")
  end

  def page_resources(image_refs, extra = "")
    entries = image_refs.map { |label, id| "/#{label} #{ref(id)}" }.join(" ")
    dict("/XObject << #{entries} >> #{extra}")
  end

  # Serialise everything and return a valid PDF string.
  def to_pdf(root_id = @root_id || 1)
    pdf = "%PDF-1.4\n%\xCF\xCF\xCF\xCF\n".dup.force_encoding(Encoding::BINARY)
    offsets = {}

    (1..@sequence).each do |id|
      body = @bodies.fetch(id)
      offsets[id] = pdf.bytesize
      pdf << "#{id} 0 obj\n".b << body.to_s.dup.force_encoding(Encoding::BINARY) << "\nendobj\n"
    end

    xref_offset = pdf.bytesize
    pdf << "xref\n0 #{@sequence + 1}\n"
    pdf << "0000000000 65535 f \n"
    (1..@sequence).each do |id|
      pdf << "%010d 00000 n \n" % offsets.fetch(id)
    end
    pdf << "trailer\n<< /Size #{@sequence + 1} /Root #{ref(root_id)} >>\n"
    pdf << "startxref\n#{xref_offset}\n%%EOF\n"
    pdf
  end

  def to_io
    StringIO.new(to_pdf)
  end

  # Parse the PDF and return the first page for convenient spec access.
  def first_page
    PDF::Reader.new(to_io).page(1)
  end
end

# Convert a flat array of 0-255 RGBA integers into a binary string.
def rgba_bytes(*pixels)
  pixels.flatten.pack("C*")
end

# Expected RGBA bytes for pixels given as RGB triples, with a provided
# alpha per pixel (255 by default).
def expected_rgba(rgb_rows, alpha: nil)
  result = []
  rgb_rows.each_with_index do |row, row_index|
    row.each_with_index do |triple, column|
      value = alpha ? alpha[row_index][column] : 255
      result.concat(triple)
      result << value
    end
  end
  result.pack("C*")
end

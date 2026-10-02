# frozen_string_literal: true

# Generates the PDF fixtures used by spec/reader/embedded_files_spec.rb
#
#   ruby tools/generate_embedded_files_fixtures.rb
#
# The fixtures are hand-built so they can include things real writers
# rarely produce: duplicate name tree keys, embedded streams shared by
# multiple filespecs, a corrupted name tree, platform specific EF entries
# and an unknown stream filter.

require "zlib"
require "digest/md5"
require "fileutils"

class PdfBuilder
  def initialize
    @objects = []
  end

  # body is the raw PDF syntax for the object, without the "N 0 obj" wrapper
  def add(body)
    @objects << body
    @objects.size # object number
  end

  def object_count
    @objects.size
  end

  # reserve an object number now, fill in the body later
  def reserve
    @objects << nil
    @objects.size
  end

  def set(num, body)
    @objects[num - 1] = body
  end

  def ref(num)
    "#{num} 0 R"
  end

  def stream(dict, data)
    "<< #{dict} /Length #{data.bytesize} >>\nstream\n#{data}\nendstream"
  end

  def utf16_hex(str)
    "<#{str.encode("UTF-16").unpack1("H*")}>"
  end

  def build(path, root_num:)
    out = +"%PDF-1.7\n%\xE2\xE3\xCF\xD3\n".b
    offsets = []
    @objects.each_with_index do |body, idx|
      offsets << out.bytesize
      out << "#{idx + 1} 0 obj\n#{body}\nendobj\n"
    end
    xref_pos = out.bytesize
    out << "xref\n0 #{@objects.size + 1}\n"
    out << "0000000000 65535 f \n"
    offsets.each { |off| out << format("%010d 00000 n \n", off) }
    out << "trailer\n<< /Size #{@objects.size + 1} /Root #{ref(root_num)} >>\n"
    out << "startxref\n#{xref_pos}\n%%EOF\n"
    File.binwrite(path, out)
  end
end

def params_for(data)
  "/Params << /Size #{data.bytesize} /CheckSum <#{Digest::MD5.hexdigest(data)}> >>"
end

DATA_DIR = File.expand_path("../spec/data", __dir__)
FileUtils.mkdir_p(DATA_DIR)

################################################################################
# 1. embedded_files_name_tree.pdf
#
# Document EmbeddedFiles name tree with:
#   - duplicate keys ("report.txt" twice, different content)
#   - two filespecs sharing one embedded stream (aliases)
#   - a nested Kids level
#   - UF preferred over F, a UTF-16BE name, Params with Size/CheckSum
################################################################################
def generate_name_tree_fixture(path)
  pdf = PdfBuilder.new

  report_one = "report one contents\n"
  report_two = "report two contents\n"
  shared     = "shared stream contents\n"
  nested     = "nested kid contents\n"

  report_one_stream = pdf.add(pdf.stream("/Filter /FlateDecode #{params_for(report_one)}", Zlib::Deflate.deflate(report_one)))
  report_two_stream = pdf.add(pdf.stream(params_for(report_two), report_two))
  shared_stream     = pdf.add(pdf.stream(params_for(shared), shared))
  nested_stream     = pdf.add(pdf.stream(params_for(nested), nested))

  # filespec with both UF and F, plus a description and relationship
  fs_report_one = pdf.add(
    "<< /Type /Filespec /F (report.txt) /UF (report.txt) " \
    "/Desc (first report) /AFRelationship /Data " \
    "/EF << /UF #{pdf.ref(report_one_stream)} /F #{pdf.ref(report_one_stream)} >> >>"
  )
  # duplicate name, different file
  fs_report_two = pdf.add(
    "<< /Type /Filespec /F (report.txt) " \
    "/EF << /F #{pdf.ref(report_two_stream)} >> >>"
  )
  # two filespecs sharing the same embedded stream
  fs_shared_a = pdf.add(
    "<< /Type /Filespec /F (shared.txt) /UF (shared.txt) " \
    "/EF << /F #{pdf.ref(shared_stream)} >> >>"
  )
  fs_shared_b = pdf.add(
    "<< /Type /Filespec /F (alias.txt) /UF (alias.txt) " \
    "/EF << /F #{pdf.ref(shared_stream)} >> >>"
  )
  # reachable only through a nested Kids node, name stored as UTF-16BE hex
  fs_nested = pdf.add(
    "<< /Type /Filespec /F (nested.txt) /UF #{pdf.utf16_hex("nested.txt")} " \
    "/EF << /UF #{pdf.ref(nested_stream)} >> >>"
  )

  kid_node = pdf.add(
    "<< /Limits [#{pdf.utf16_hex("nested.txt")} #{pdf.utf16_hex("nested.txt")}] " \
    "/Names [#{pdf.utf16_hex("nested.txt")} #{pdf.ref(fs_nested)}] >>"
  )
  names_root = pdf.add(
    "<< /Limits [(alias.txt) (shared.txt)] " \
    "/Names [(alias.txt) #{pdf.ref(fs_shared_b)} " \
    "(report.txt) #{pdf.ref(fs_report_one)} " \
    "(report.txt) #{pdf.ref(fs_report_two)} " \
    "(shared.txt) #{pdf.ref(fs_shared_a)}] " \
    "/Kids [#{pdf.ref(kid_node)}] >>"
  )
  names_dict = pdf.add("<< /EmbeddedFiles #{pdf.ref(names_root)} >>")
  pages = pdf.add("<< /Type /Pages /Count 0 /Kids [] >>")
  catalog = pdf.add("<< /Type /Catalog /Pages #{pdf.ref(pages)} /Names #{pdf.ref(names_dict)} >>")

  pdf.build(path, root_num: catalog)
end

################################################################################
# 2. embedded_files_af.pdf
#
# No name tree at all. Filespecs are reachable only via AF arrays on the
# catalog, a page and another object. Also covers platform specific EF
# entries, an external filespec (no EF) and an unknown stream filter.
################################################################################
def generate_af_fixture(path)
  pdf = PdfBuilder.new

  catalog_data  = "catalog attachment\n"
  page_data     = "page attachment\n"
  object_data   = "object attachment\n"
  platform_data = "platform specific contents\n"
  unknown_data  = "mystery contents\n"

  catalog_stream  = pdf.add(pdf.stream(params_for(catalog_data), catalog_data))
  page_stream     = pdf.add(pdf.stream("/Filter /FlateDecode #{params_for(page_data)}", Zlib::Deflate.deflate(page_data)))
  object_stream   = pdf.add(pdf.stream(params_for(object_data), object_data))
  platform_stream = pdf.add(pdf.stream(params_for(platform_data), platform_data))
  unknown_stream  = pdf.add(pdf.stream("/Filter /FrobDecode", unknown_data))

  fs_catalog = pdf.add(
    "<< /Type /Filespec /F (catalog.txt) /UF (catalog.txt) " \
    "/AFRelationship /Source /EF << /F #{pdf.ref(catalog_stream)} >> >>"
  )
  fs_page = pdf.add(
    "<< /Type /Filespec /F (page.txt) /UF (page.txt) " \
    "/AFRelationship /Data /EF << /F #{pdf.ref(page_stream)} >> >>"
  )
  fs_object = pdf.add(
    "<< /Type /Filespec /F (object.txt) /UF (object.txt) " \
    "/AFRelationship /Supplement /EF << /F #{pdf.ref(object_stream)} >> >>"
  )
  # platform specific EF entries only (legacy DOS/Mac/Unix keys)
  fs_platform = pdf.add(
    "<< /Type /Filespec /F (legacy.txt) /UF (legacy.txt) " \
    "/AFRelationship /Data " \
    "/EF << /DOS #{pdf.ref(platform_stream)} /Mac #{pdf.ref(platform_stream)} " \
    "/Unix #{pdf.ref(platform_stream)} >> >>"
  )
  # external filespec: no EF dict, must never be read from the filesystem
  fs_external = pdf.add(
    "<< /Type /Filespec /F (external.txt) /UF (external.txt) " \
    "/AFRelationship /Data >>"
  )
  # embedded stream with a filter pdf-reader does not know
  fs_unknown_filter = pdf.add(
    "<< /Type /Filespec /F (mystery.bin) /UF (mystery.bin) " \
    "/AFRelationship /Data /EF << /F #{pdf.ref(unknown_stream)} >> >>"
  )

  # an arbitrary non-page, non-catalog object carrying an AF array
  widget_holder = pdf.add(
    "<< /Type /Annot /Subtype /Widget /AF [#{pdf.ref(fs_object)} #{pdf.ref(fs_platform)}] >>"
  )
  pages_num = pdf.reserve
  page = pdf.add(
    "<< /Type /Page /Parent #{pages_num} 0 R /MediaBox [0 0 100 100] " \
    "/AF [#{pdf.ref(fs_page)}] /Annots [#{pdf.ref(widget_holder)}] >>"
  )
  pdf.set(pages_num, "<< /Type /Pages /Count 1 /Kids [#{pdf.ref(page)}] >>")
  catalog = pdf.add(
    "<< /Type /Catalog /Pages #{pages_num} 0 R " \
    "/AF [#{pdf.ref(fs_catalog)} #{pdf.ref(fs_external)} #{pdf.ref(fs_unknown_filter)}] >>"
  )

  pdf.build(path, root_num: catalog)
end

################################################################################
# 3. embedded_files_broken_name_tree.pdf
#
# The EmbeddedFiles name tree is corrupted: the /Names array has an odd
# number of entries and the /Kids array points at an object that does not
# exist. One filespec is still reachable through the tree, the other only
# by scanning every object in the file.
################################################################################
def generate_broken_name_tree_fixture(path)
  pdf = PdfBuilder.new

  reachable_data = "reachable before the corruption\n"
  orphan_data    = "orphan filespec contents\n"

  reachable_stream = pdf.add(pdf.stream(params_for(reachable_data), reachable_data))
  orphan_stream    = pdf.add(pdf.stream(params_for(orphan_data), orphan_data))

  fs_reachable = pdf.add(
    "<< /Type /Filespec /F (reachable.txt) /UF (reachable.txt) " \
    "/EF << /F #{pdf.ref(reachable_stream)} >> >>"
  )
  # never referenced by any name tree or AF array
  fs_orphan = pdf.add(
    "<< /Type /Filespec /F (orphan.txt) /UF (orphan.txt) " \
    "/EF << /F #{pdf.ref(orphan_stream)} >> >>"
  )

  # corrupted: odd /Names array (dangling key with no value) and a /Kids
  # reference to an object number that does not exist in the file
  names_root = pdf.add(
    "<< /Names [(reachable.txt) #{pdf.ref(fs_reachable)} (dangling.txt)] " \
    "/Kids [#{pdf.object_count + 100} 0 R] >>"
  )
  names_dict = pdf.add("<< /EmbeddedFiles #{pdf.ref(names_root)} >>")
  pages = pdf.add("<< /Type /Pages /Count 0 /Kids [] >>")
  catalog = pdf.add("<< /Type /Catalog /Pages #{pdf.ref(pages)} /Names #{pdf.ref(names_dict)} >>")

  pdf.build(path, root_num: catalog)
end

generate_name_tree_fixture(File.join(DATA_DIR, "embedded_files_name_tree.pdf"))
generate_af_fixture(File.join(DATA_DIR, "embedded_files_af.pdf"))
generate_broken_name_tree_fixture(File.join(DATA_DIR, "embedded_files_broken_name_tree.pdf"))

puts "fixtures written to #{DATA_DIR}"

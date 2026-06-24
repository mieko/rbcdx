require_relative "test_helper"

class RbCDXManifestTest < Minitest::Test
  def test_builds_file_level_manifest_for_rbcdx_files
    Dir.mktmpdir do |dir|
      first = repack_fixture(dir, "cdx-00001.rbcdx", first_cdxj)
      second = repack_fixture(dir, "cdx-00000.rbcdx", second_cdxj)

      manifest = CDX::Backends::RbCDX::Manifest.build([first, second], root: dir, created_at: 123)

      assert_equal "rbcdx-manifest", manifest.to_h.fetch("format")
      assert_equal 1, manifest.to_h.fetch("version")
      assert_equal 123, manifest.to_h.fetch("created_at")
      refute manifest.to_h.key?("root")

      files = manifest.to_h.fetch("files")
      assert_equal ["cdx-00000.rbcdx", "cdx-00001.rbcdx"], files.map { |entry| entry.fetch("path") }
      assert_equal ["com,alpha)/", "com,zeta)/"], files.map { |entry| entry.fetch("first_urlkey") }
      assert_equal ["com,alpha)/page", "com,zeta)/page"], files.map { |entry| entry.fetch("last_urlkey") }
      assert_equal [2, 2], files.map { |entry| entry.fetch("record_count") }
      assert_equal [2, 2], files.map { |entry| entry.fetch("block_count") }
      assert_equal [CDX::Backends::RbCDX::Format::VERSION, CDX::Backends::RbCDX::Format::VERSION], files.map { |entry| entry.fetch("version") }
      assert_equal [CDX::Backends::RbCDX::Format::VARIANT, CDX::Backends::RbCDX::Format::VARIANT], files.map { |entry| entry.fetch("variant") }
      assert files.all? { |entry| entry.fetch("bytes").positive? }
      refute files.any? { |entry| entry.key?("mtime") }
    end
  end

  def test_write_uses_visible_manifest_filename
    refute_match(/\A\./, CDX::Backends::RbCDX::Manifest::FILENAME)

    Dir.mktmpdir do |dir|
      input = repack_fixture(dir, "cdx-00000.rbcdx", first_cdxj)
      output = File.join(dir, CDX::Backends::RbCDX::Manifest::FILENAME)

      manifest = CDX::Backends::RbCDX::Manifest.write([input], output, created_at: 456)
      parsed = JSON.parse(File.read(output))

      assert_instance_of CDX::Backends::RbCDX::Manifest, manifest
      assert_equal "rbcdx-manifest", parsed.fetch("format")
      assert_equal 456, parsed.fetch("created_at")
      assert_equal ["cdx-00000.rbcdx"], parsed.fetch("files").map { |entry| entry.fetch("path") }
    end
  end

  def test_build_expands_directories_and_ignores_non_rbcdx_files
    Dir.mktmpdir do |dir|
      repack_fixture(dir, "cdx-00000.rbcdx", first_cdxj)
      File.write(File.join(dir, "notes.txt"), "not an index\n")

      manifest = CDX::Backends::RbCDX::Manifest.build(dir, created_at: 789)

      assert_equal ["cdx-00000.rbcdx"], manifest.to_h.fetch("files").map { |entry| File.basename(entry.fetch("path")) }
    end
  end

  def test_read_resolves_relative_paths_from_manifest_location
    Dir.mktmpdir do |dir|
      input = repack_fixture(dir, "cdx-00000.rbcdx", first_cdxj)
      output = File.join(dir, CDX::Backends::RbCDX::Manifest::FILENAME)
      CDX::Backends::RbCDX::Manifest.write([input], output, created_at: 456)

      manifest = CDX::Backends::RbCDX::Manifest.read(output, paths: [input])

      assert_equal [input], manifest.paths
      assert_equal [input], manifest.candidate_paths("com,zeta)/", prefix: true)
      assert_empty manifest.candidate_paths("com,alpha)/", prefix: true)
    end
  end

  def test_read_keeps_current_absolute_path_manifest_entry
    Dir.mktmpdir do |dir|
      input = repack_fixture(dir, "cdx-00000.rbcdx", first_cdxj)
      output = File.join(dir, CDX::Backends::RbCDX::Manifest::FILENAME)
      CDX::Backends::RbCDX::Manifest.build([input], root: nil, created_at: 456).write(output)

      manifest = CDX::Backends::RbCDX::Manifest.read(output, paths: [input])

      assert_equal [input], manifest.paths
      assert_equal [input], manifest.candidate_paths("com,zeta)/", prefix: true)
    end
  end

  def test_read_keeps_entry_when_mtime_changes
    Dir.mktmpdir do |dir|
      input = repack_fixture(dir, "cdx-00000.rbcdx", first_cdxj)
      output = File.join(dir, CDX::Backends::RbCDX::Manifest::FILENAME)
      CDX::Backends::RbCDX::Manifest.write([input], output, created_at: 456)
      File.utime(Time.now + 60, Time.now + 60, input)

      manifest = CDX::Backends::RbCDX::Manifest.read(output, paths: [input])

      assert_equal [input], manifest.paths
    end
  end

  def test_read_drops_entry_when_size_changes
    Dir.mktmpdir do |dir|
      input = repack_fixture(dir, "cdx-00000.rbcdx", first_cdxj)
      output = File.join(dir, CDX::Backends::RbCDX::Manifest::FILENAME)
      CDX::Backends::RbCDX::Manifest.write([input], output, created_at: 456)
      File.binwrite(input, File.binread(input) + "x")

      manifest = CDX::Backends::RbCDX::Manifest.read(output, paths: [input])

      assert_empty manifest.paths
    end
  end

  def test_read_drops_entry_when_current_bounds_change_at_same_size
    Dir.mktmpdir do |dir|
      input = repack_fixture(dir, "cdx-00000.rbcdx", first_cdxj)
      output = File.join(dir, CDX::Backends::RbCDX::Manifest::FILENAME)
      CDX::Backends::RbCDX::Manifest.write([input], output, created_at: 456)

      replacement_dir = File.join(dir, "replacement")
      FileUtils.mkdir_p(replacement_dir)
      replacement = repack_fixture(replacement_dir, "cdx-00000.rbcdx", second_cdxj)
      FileUtils.cp(replacement, input)
      manifest_data = JSON.parse(File.read(output))
      manifest_data.fetch("files").first["bytes"] = File.size(input)
      File.write(output, "#{JSON.pretty_generate(manifest_data)}\n")

      manifest = CDX::Backends::RbCDX::Manifest.read(output, paths: [input])

      assert_empty manifest.paths
      assert_equal ["https://alpha.com/"], CDX::Index.open(input).captures("alpha.com/").map(&:url)
    end
  end

  def test_read_keeps_entry_when_current_file_has_invalid_directory_bounds
    Dir.mktmpdir do |dir|
      input = repack_fixture(dir, "cdx-00000.rbcdx", first_cdxj)
      output = File.join(dir, CDX::Backends::RbCDX::Manifest::FILENAME)
      CDX::Backends::RbCDX::Manifest.write([input], output, created_at: 456)
      rewrite_rbcdx_header(input) { |header| header["directory_offset"] = -1 }

      manifest = CDX::Backends::RbCDX::Manifest.read(output, paths: [input])

      assert_equal [input], manifest.paths
    end
  end

  def test_build_rejects_non_rbcdx_explicit_file
    Dir.mktmpdir do |dir|
      path = File.join(dir, "cdx-00000.gz")
      File.write(path, "not rbcdx")

      error = assert_raises(ArgumentError) do
        CDX::Backends::RbCDX::Manifest.build(path)
      end

      assert_match(/not an rbcdx file/, error.message)
    end
  end

  private

  def repack_fixture(dir, basename, cdxj)
    input = File.join(dir, "#{basename}.cdxj")
    output = File.join(dir, basename)
    File.write(input, cdxj)
    CDX::Repacker.repack(input, output, max_records: 1)
    output
  end

  def rewrite_rbcdx_header(path)
    File.open(path, "r+b") do |file|
      magic = file.read(CDX::Backends::RbCDX::Format::MAGIC.bytesize)
      raise "invalid test rbcdx magic" unless magic == CDX::Backends::RbCDX::Format::MAGIC

      header_length = file.read(4).unpack1("L<")
      header_offset = file.pos
      header = JSON.parse(file.read(header_length))
      yield header
      replacement = JSON.generate(header)
      raise "test header grew unexpectedly" unless replacement.bytesize <= header_length

      file.seek(header_offset)
      file.write(replacement)
      file.write(" " * (header_length - replacement.bytesize))
    end
  end

  def first_cdxj
    <<~CDXJ
      com,zeta)/ 20240101010101 {"url":"https://zeta.com/","mime":"text/html","status":"200","length":"10","offset":"1","filename":"crawl-data/CC-MAIN-2025-43/segments/123.45/warc/CC-MAIN-20250101000000-20250101030000-00001.warc.gz"}
      com,zeta)/page 20240202020202 {"url":"https://zeta.com/page","mime":"text/html","status":"200","length":"20","offset":"11","filename":"crawl-data/CC-MAIN-2025-43/segments/123.45/warc/CC-MAIN-20250101000000-20250101030000-00001.warc.gz"}
    CDXJ
  end

  def second_cdxj
    <<~CDXJ
      com,alpha)/ 20240101010101 {"url":"https://alpha.com/","mime":"text/html","status":"200","length":"10","offset":"1","filename":"crawl-data/CC-MAIN-2025-43/segments/123.45/warc/CC-MAIN-20250101000000-20250101030000-00002.warc.gz"}
      com,alpha)/page 20240202020202 {"url":"https://alpha.com/page","mime":"text/html","status":"200","length":"20","offset":"11","filename":"crawl-data/CC-MAIN-2025-43/segments/123.45/warc/CC-MAIN-20250101000000-20250101030000-00002.warc.gz"}
    CDXJ
  end
end

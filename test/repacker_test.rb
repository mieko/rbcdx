require_relative "test_helper"

class RepackerTest < Minitest::Test
  def test_repack_writes_rbcdx_readable_by_index
    Dir.mktmpdir do |dir|
      input = File.join(dir, "sample.cdxj")
      output = File.join(dir, "sample.rbcdx")
      File.write(input, sorted_cdxj)

      result = CDX::Repacker.repack(input, output, block_bytes: 180)

      assert_equal output, result.path
      assert_equal 3, result.record_count
      assert File.size(output) > 0

      index = CDX::Index.open(output)
      assert_equal 3, index.count
      assert_equal ["http://example.com/", "https://example.com/about"], index.captures("example.com/*").map(&:url)
      assert_equal ["http://example.com/", "https://example.com/about", "https://blog.example.com/post"], index.captures("*.example.com").map(&:url)

      capture = index.captures("https://example.com/about").first
      assert_equal "com,example)/about", capture.urlkey
      assert_equal "20240202020202", capture.timestamp
      assert_equal "text/html", capture.mime
      assert_equal "text/html", capture.mime_detected
      assert_equal "200", capture.status
      assert_equal "IFUIEFR56GZBO3ZK43VEKSLQ5QOFXDOI", capture.digest
      assert_equal "20", capture.length
      assert_equal "15", capture.offset
      assert_equal 15..34, capture.byte_range
      assert_equal "crawl-data/CC-MAIN-2025-43/segments/123.45/warc/CC-MAIN-20250101000000-20250101030000-00001.warc.gz", capture.filename
      assert_equal "UTF-8", capture.charset
      assert_equal "eng,spa", capture.languages
    end
  end

  def test_rbcdx_queries_match_cdx_queries
    Dir.mktmpdir do |dir|
      input = File.join(dir, "sample.cdxj")
      output = File.join(dir, "sample.rbcdx")
      File.write(input, sorted_cdxj)
      CDX::Repacker.repack(input, output, block_bytes: 180)

      cdx = CDX::Index.open(input)
      rbcdx = CDX::Index.open(output)
      queries = [
        ["example.com/about", {}],
        ["https://example.com/about", {}],
        ["example.com/*", {}],
        ["*.example.com", {}],
        ["example.com", {match: :host}],
        ["blog.example.com", {match: :host}],
        ["*.example.com", {filters: "=status:200"}],
        ["*.example.com", {from: "202402", to: "202404"}],
        ["*.example.com", {closest: "20240201000000", limit: 2}],
        ["*.example.com", {sort: :reverse_timestamp}]
      ]

      queries.each do |url, options|
        assert_equal(
          cdx.captures(url, **options).map(&:to_h),
          rbcdx.captures(url, **options).map(&:to_h),
          "expected rbcdx query #{url.inspect} #{options.inspect} to match CDXJ"
        )
      end
    end
  end

  def test_duplicate_urlkeys_split_across_blocks_match_cdx_queries
    Dir.mktmpdir do |dir|
      input = File.join(dir, "duplicates.cdxj")
      output = File.join(dir, "duplicates.rbcdx")
      File.write(input, duplicate_urlkey_cdxj)
      CDX::Repacker.repack(input, output, max_records: 1)

      cdx = CDX::Index.open(input)
      rbcdx = CDX::Index.open(output)

      assert_equal(
        %w[20240101010101 20240202020202 20240303030303],
        cdx.captures("example.com/repeat").map(&:timestamp)
      )
      assert_equal(
        cdx.captures("example.com/repeat").map(&:to_h),
        rbcdx.captures("example.com/repeat").map(&:to_h)
      )
      assert_equal(
        cdx.captures("example.com/*").map(&:to_h),
        rbcdx.captures("example.com/*").map(&:to_h)
      )
    end
  end

  def test_repack_collapse_urlkey_writes_latest_per_urlkey_and_metadata
    Dir.mktmpdir do |dir|
      input = File.join(dir, "collapse.cdxj")
      output = File.join(dir, "collapse.rbcdx")
      File.write(input, collapse_repack_cdxj)

      result = CDX::Repacker.repack(input, output, collapse: :urlkey)

      assert_equal 2, result.record_count
      assert_equal [
        "https://collapse.example/a",
        "https://collapse.example/b"
      ], CDX::Index.open(output).map(&:url)
      assert_equal %w[20250103000000 20250104000000], CDX::Index.open(output).map(&:timestamp)
      assert_equal(
        {"field" => "urlkey", "order" => "latest"},
        CDX::Repacker.read_header(output).fetch("repack").fetch("collapse_signature")
      )
    end
  end

  def test_repack_reads_gzip_input
    Dir.mktmpdir do |dir|
      input = File.join(dir, "cdx-00000.gz")
      output = File.join(dir, "cdx-00000.rbcdx")
      Zlib::GzipWriter.open(input) { |gzip| gzip.write(sorted_cdxj) }

      CDX::Backends::RbCDX.write(input, output, block_bytes: 180)

      assert_equal ["https://example.com/about"], CDX::Index.open(output).captures("example.com/about").map(&:url)
    end
  end

  def test_rbcdx_backend_write_always_writes_rbcdx
    Dir.mktmpdir do |dir|
      input = File.join(dir, "sample.cdxj")
      output = File.join(dir, "sample.data")
      File.write(input, sorted_cdxj)

      CDX::Backends::RbCDX.write(input, output, output_format: "cdxj")

      assert_equal CDX::Backends::RbCDX::Format::MAGIC, File.binread(output, CDX::Backends::RbCDX::Format::MAGIC.bytesize)
    end
  end

  def test_repack_spools_hot_and_cold_sections_to_format_writer
    writer_sections = []
    original_write_file = CDX::Backends::RbCDX::Format.method(:write_file)
    replacement_write_file = lambda do |output_path, dict_data:, directory_data:, hot_data:, cold_data:, header:|
      writer_sections << [hot_data, cold_data]
      original_write_file.call(
        output_path,
        dict_data: dict_data,
        directory_data: directory_data,
        hot_data: hot_data,
        cold_data: cold_data,
        header: header
      )
    end

    with_singleton_replacement(CDX::Backends::RbCDX::Format, :write_file, replacement_write_file) do
      Dir.mktmpdir do |dir|
        input = File.join(dir, "sample.cdxj")
        output = File.join(dir, "sample.rbcdx")
        File.write(input, sorted_cdxj)

        result = CDX::Repacker.repack(input, output, max_records: 1)

        assert_equal 3, result.block_count
        assert_equal 3, CDX::Index.open(output).count
        refute_respond_to result, :hot_data
        refute_respond_to result, :cold_data

        assert_equal 1, writer_sections.length
        hot_section, cold_section = writer_sections.first
        refute_instance_of String, hot_section
        refute_instance_of String, cold_section
        assert_respond_to hot_section, :copy_to
        assert_respond_to cold_section, :copy_to
        assert_equal result.hot_bytes, hot_section.bytesize
        assert_equal result.cold_bytes, cold_section.bytesize
      end
    end
  end

  def test_repack_rejects_non_decimal_numeric_options
    Dir.mktmpdir do |dir|
      input = File.join(dir, "sample.cdxj")
      output = File.join(dir, "sample.rbcdx")
      File.write(input, sorted_cdxj)

      error = assert_raises(ArgumentError) do
        CDX::Repacker.repack(input, output, max_records: "1junk")
      end

      assert_match(/max_records must be a decimal integer/, error.message)
    end
  end

  def test_repack_many_rejects_non_decimal_numeric_options
    Dir.mktmpdir do |dir|
      input = File.join(dir, "sample.cdxj")
      output_dir = File.join(dir, "rbcdx")
      File.write(input, sorted_cdxj)

      error = assert_raises(ArgumentError) do
        CDX::Repacker.repack_many([input], output_dir: output_dir, block_bytes: "1024junk")
      end

      assert_match(/block_bytes must be a decimal integer/, error.message)
    end
  end

  def test_repack_verification_rejects_section_offset_that_does_not_follow_header
    Dir.mktmpdir do |dir|
      input = File.join(dir, "sample.cdxj")
      output = File.join(dir, "sample.rbcdx")
      File.write(input, sorted_cdxj)
      CDX::Repacker.repack(input, output)
      rewrite_header(output) { |header| header["dict_offset"] = 0 }

      error = assert_raises(CDX::Error) do
        CDX::Repacker.verify_output(output, 3)
      end

      assert_match(/first section offset/, error.message)
    end
  end

  def test_repack_accepts_custom_named_filters
    Dir.mktmpdir do |dir|
      input = File.join(dir, "sample.cdxj")
      output = File.join(dir, "sample.rbcdx")
      File.write(input, sorted_cdxj)

      result = CDX::Repacker.repack(
        input,
        output,
        filters: ["about"],
        filter_registry: {
          "about" => ->(record) { record.url.to_s.end_with?("/about") }
        }
      )

      assert_equal 1, result.record_count
      assert_equal ["https://example.com/about"], CDX::Index.open(output).map(&:url)
      assert_equal(
        {"filters" => ["about"], "where" => []},
        CDX::Repacker.read_header(output).fetch("repack").fetch("filter_signature")
      )
    end
  end

  def test_repack_combines_positive_and_negative_named_filters
    Dir.mktmpdir do |dir|
      input = File.join(dir, "sample.cdxj")
      output = File.join(dir, "sample.rbcdx")
      File.write(input, sorted_cdxj)

      result = CDX::Repacker.repack(
        input,
        output,
        filters: ["+ok,-about"],
        filter_registry: {
          "ok" => ->(record) { record.status.to_s == "200" },
          "about" => ->(record) { record.url.to_s.end_with?("/about") }
        }
      )

      assert_equal 1, result.record_count
      assert_equal ["https://blog.example.com/post"], CDX::Index.open(output).map(&:url)
    end
  end

  def test_repack_extractable_text_filter_keeps_human_text_captures
    Dir.mktmpdir do |dir|
      input = File.join(dir, "extractable.cdxj")
      output = File.join(dir, "extractable.rbcdx")
      File.write(input, extractable_text_cdxj)

      result = CDX::Repacker.repack(input, output, filters: ["extractable_text"])

      assert_equal 7, result.record_count
      assert_equal(
        {
          "filters" => ["extractable_text"],
          "named_filter_version" => CDX::CaptureFilters::VOCABULARY_VERSION,
          "where" => []
        },
        CDX::Repacker.read_header(output).fetch("repack").fetch("filter_signature")
      )
      assert_equal [
        "https://example.com/",
        "https://example.com/about.txt",
        "https://example.com/feed.xml",
        "https://example.com/octet-html",
        "https://example.com/README.md",
        "https://example.com/sitemap-guide",
        "https://example.org/xhtml"
      ], CDX::Index.open(output).map(&:url)
    end
  end

  def test_repack_text_filter_pieces_are_composable
    Dir.mktmpdir do |dir|
      input = File.join(dir, "extractable.cdxj")
      output = File.join(dir, "extractable.rbcdx")
      File.write(input, extractable_text_cdxj)

      result = CDX::Repacker.repack(input, output, filters: ["+status_200,+warc,+text_like,-asset_like,-site_metadata"])

      assert_equal 7, result.record_count
      assert_equal [
        "https://example.com/",
        "https://example.com/about.txt",
        "https://example.com/feed.xml",
        "https://example.com/octet-html",
        "https://example.com/README.md",
        "https://example.com/sitemap-guide",
        "https://example.org/xhtml"
      ], CDX::Index.open(output).map(&:url)
    end
  end

  def test_repack_filters_before_representability_validation
    Dir.mktmpdir do |dir|
      input = File.join(dir, "filtered.cdxj")
      output = File.join(dir, "filtered.rbcdx")
      File.write(input, <<~CDXJ)
        com,bad)/ 20240101010101 {"url":"ftp://bad.com/","mime":"text/html","status":"200","length":"10","offset":"1","filename":"crawl-data/CC-MAIN-2025-43/segments/123.45/warc/CC-MAIN-20250101000000-20250101030000-00001.warc.gz","future":"skip me"}
        com,example)/ 20240202020202 {"url":"https://example.com/","mime":"text/html","status":"200","length":"20","offset":"11","filename":"crawl-data/CC-MAIN-2025-43/segments/123.45/warc/CC-MAIN-20250101000000-20250101030000-00001.warc.gz"}
      CDXJ

      CDX::Repacker.repack(
        input,
        output,
        filters: [->(record) { record.url.to_s.start_with?("https://example.com/") }]
      )

      assert_equal ["https://example.com/"], CDX::Index.open(output).map(&:url)
    end
  end

  def test_repack_rejects_unsorted_input
    Dir.mktmpdir do |dir|
      input = File.join(dir, "unsorted.cdxj")
      output = File.join(dir, "unsorted.rbcdx")
      File.write(input, sorted_cdxj.lines.reverse.join)

      error = assert_raises(CDX::Backends::RbCDX::Format::EncodeError) do
        CDX::Repacker.repack(input, output)
      end
      assert_match(/input is not sorted by urlkey/, error.message)
    end
  end

  def test_repack_rejects_noncanonical_digest
    Dir.mktmpdir do |dir|
      input = File.join(dir, "bad-digest.cdxj")
      output = File.join(dir, "bad-digest.rbcdx")
      File.write(input, sorted_cdxj.sub("IFUIEFR56GZBO3ZK43VEKSLQ5QOFXDOI", "IFUIEFR56GZBO3ZK43VEKSLQ5QOFXDOIA"))

      error = assert_raises(CDX::Backends::RbCDX::Format::EncodeError) do
        CDX::Repacker.repack(input, output)
      end
      assert_match(/not canonical unpadded base32 SHA-1/, error.message)
    end
  end

  def test_repack_rejects_padded_digest
    Dir.mktmpdir do |dir|
      input = File.join(dir, "bad-digest.cdxj")
      output = File.join(dir, "bad-digest.rbcdx")
      File.write(input, sorted_cdxj.sub("IFUIEFR56GZBO3ZK43VEKSLQ5QOFXDOI", "IFUIEFR56GZBO3ZK43VEKSLQ5QOFXDOI="))

      error = assert_raises(CDX::Backends::RbCDX::Format::EncodeError) do
        CDX::Repacker.repack(input, output)
      end
      assert_match(/not canonical unpadded base32 SHA-1/, error.message)
    end
  end

  def test_repack_rejects_internally_padded_digest
    Dir.mktmpdir do |dir|
      input = File.join(dir, "bad-digest.cdxj")
      output = File.join(dir, "bad-digest.rbcdx")
      File.write(input, sorted_cdxj.sub("IFUIEFR56GZBO3ZK43VEKSLQ5QOFXDOI", "IFUIEFR56GZBO3ZK43VE=SLQ5QOFXDOI"))

      error = assert_raises(CDX::Backends::RbCDX::Format::EncodeError) do
        CDX::Repacker.repack(input, output)
      end
      assert_match(/not canonical unpadded base32 SHA-1/, error.message)
    end
  end

  def test_cli_repack
    Dir.mktmpdir do |dir|
      input = File.join(dir, "sample.cdxj")
      output = File.join(dir, "sample.rbcdx")
      File.write(input, sorted_cdxj)
      out = StringIO.new
      err = StringIO.new

      status = CDX::CLI.start(["repack", "--output", output, input], out: out, err: err)

      assert_equal 0, status
      assert_equal "#{output}\n", out.string
      assert_match(/processing \[1\/1\]/, err.string)
      assert_match(/written \[1\/1\]/, err.string)
      assert_equal ["https://example.com/about"], CDX::Index.open(output).captures("example.com/about").map(&:url)
    end
  end

  def test_cli_repack_dry_run_prints_plan_and_filter_count_without_writing
    Dir.mktmpdir do |dir|
      input = File.join(dir, "sample.cdxj")
      output = File.join(dir, "sample.rbcdx")
      File.write(input, sorted_cdxj)
      out = StringIO.new
      err = StringIO.new

      status = CDX::CLI.start(["repack", "--output", output, "--filter", "status_200", "--dry-run", input], out: out, err: err)

      assert_equal 0, status
      assert_match(/would create \[1\/1\] #{Regexp.escape(output)} from #{Regexp.escape(input)}/, out.string)
      assert_match(/filtered \[1\/1\] #{Regexp.escape(input)}: 2 of 3 records selected/, out.string)
      assert_empty err.string
      refute File.exist?(output)
    end
  end

  def test_cli_repack_dry_run_with_collapse_reports_selected_records
    Dir.mktmpdir do |dir|
      input = File.join(dir, "collapse.cdxj")
      output = File.join(dir, "collapse.rbcdx")
      File.write(input, collapse_repack_cdxj)
      out = StringIO.new

      status = CDX::CLI.start(["repack", "--output", output, "--collapse", "urlkey", "--dry-run", input], out: out, err: StringIO.new)

      assert_equal 0, status
      assert_match(/filtered \[1\/1\] #{Regexp.escape(input)}: 2 of 4 records selected/, out.string)
      refute File.exist?(output)
    end
  end

  def test_cli_repack_dry_run_rejects_selected_unencodable_records
    Dir.mktmpdir do |dir|
      input = File.join(dir, "bad.cdxj")
      output = File.join(dir, "bad.rbcdx")
      File.write(input, <<~CDXJ)
        com,bad)/ 20240101010101 {"url":"ftp://bad.com/","mime":"text/html","status":"200","length":"10","offset":"1","filename":"crawl-data/CC-MAIN-2025-43/segments/123.45/warc/CC-MAIN-20250101000000-20250101030000-00001.warc.gz"}
      CDXJ
      out = StringIO.new
      err = StringIO.new

      status = CDX::CLI.start(["repack", "--output", output, "--filter", "extractable_text", "--dry-run", input], out: out, err: err)

      assert_equal 1, status
      assert_empty out.string
      assert_match(/rbcdx only encodes http and https schemes/, err.string)
      refute File.exist?(output)
    end
  end

  def test_cli_repack_dry_run_rejects_existing_output_without_force
    Dir.mktmpdir do |dir|
      input = File.join(dir, "sample.cdxj")
      output = File.join(dir, "sample.rbcdx")
      File.write(input, sorted_cdxj)
      File.write(output, "already here")
      out = StringIO.new
      err = StringIO.new

      status = CDX::CLI.start(["repack", "--output", output, "--dry-run", input], out: out, err: err)

      assert_equal 1, status
      assert_empty out.string
      assert_match(/output already exists/, err.string)
      assert_equal "already here", File.read(output)
    end
  end

  def test_cli_repack_filter
    Dir.mktmpdir do |dir|
      input = File.join(dir, "sample.cdxj")
      output = File.join(dir, "sample.rbcdx")
      File.write(input, sorted_cdxj)
      out = StringIO.new
      err = StringIO.new

      status = CDX::CLI.start(["repack", "--output", output, "--filter", "status_200", input], out: out, err: err)

      assert_equal 0, status
      assert_match(/processing \[1\/1\]/, err.string)
      assert_match(/written \[1\/1\]/, err.string)
      assert_equal ["https://example.com/about", "https://blog.example.com/post"], CDX::Index.open(output).map(&:url)
    end
  end

  def test_cli_repack_combined_filter_expression
    Dir.mktmpdir do |dir|
      input = File.join(dir, "sample.cdxj")
      output = File.join(dir, "sample.rbcdx")
      File.write(input, sorted_cdxj)
      out = StringIO.new
      err = StringIO.new

      status = CDX::CLI.start(["repack", "--output", output, "--filter", "+status_200,+html,-warc", input], out: out, err: err)

      assert_equal 0, status
      assert_match(/processing \[1\/1\]/, err.string)
      assert_match(/written \[1\/1\]/, err.string)
      assert_empty CDX::Index.open(output).map(&:url)
    end
  end

  def test_cli_repack_rejects_unknown_filter
    Dir.mktmpdir do |dir|
      input = File.join(dir, "sample.cdxj")
      output = File.join(dir, "sample.rbcdx")
      File.write(input, sorted_cdxj)
      out = StringIO.new
      err = StringIO.new

      status = CDX::CLI.start(["repack", "--output", output, "--filter", "missing", input], out: out, err: err)

      assert_equal 1, status
      assert_empty out.string
      assert_match(/unknown repack filter "missing"/, err.string)
    end
  end

  def test_cli_repack_rejects_hyphenated_filter_names
    Dir.mktmpdir do |dir|
      input = File.join(dir, "sample.cdxj")
      output = File.join(dir, "sample.rbcdx")
      File.write(input, sorted_cdxj)
      err = StringIO.new

      status = CDX::CLI.start(["repack", "--output", output, "--filter", "status-200", input], out: StringIO.new, err: err)

      assert_equal 1, status
      assert_match(/unknown repack filter "status-200"/, err.string)
    end
  end

  def test_repack_removes_temp_output_after_failure
    Dir.mktmpdir do |dir|
      input = File.join(dir, "bad.cdxj")
      output = File.join(dir, "bad.rbcdx")
      File.write(input, sorted_cdxj.sub("IFUIEFR56GZBO3ZK43VEKSLQ5QOFXDOI", "IFUIEFR56GZBO3ZK43VEKSLQ5QOFXDOI="))

      assert_raises(CDX::Backends::RbCDX::Format::EncodeError) do
        CDX::Repacker.repack(input, output)
      end

      refute File.exist?(output)
      assert_empty Dir.glob(File.join(dir, "*.tmp"))
    end
  end

  def test_repack_rejects_nondeterministic_filters_even_when_count_matches
    Dir.mktmpdir do |dir|
      input = File.join(dir, "sample.cdxj")
      output = File.join(dir, "sample.rbcdx")
      File.write(input, sorted_cdxj)
      calls = 0
      filter = lambda do |record|
        calls += 1
        expected_line = (calls <= 3) ? 1 : 2
        record.line_number == expected_line
      end

      error = assert_raises(CDX::Error) do
        CDX::Repacker.repack(input, output, filters: [filter])
      end

      assert_match(/selected different records/, error.message)
      refute File.exist?(output)
    end
  end

  def test_repack_where_filter_uses_cdx_filter_syntax
    Dir.mktmpdir do |dir|
      input = File.join(dir, "sample.cdxj")
      output = File.join(dir, "sample.rbcdx")
      File.write(input, sorted_cdxj)

      result = CDX::Repacker.repack(input, output, where: ["=status:200"])

      assert_equal 2, result.record_count
      assert_equal ["https://example.com/about", "https://blog.example.com/post"], CDX::Index.open(output).map(&:url)
    end
  end

  def test_repack_where_filter_normalizes_field_names
    Dir.mktmpdir do |dir|
      input = File.join(dir, "sample.cdxj")
      output = File.join(dir, "sample.rbcdx")
      File.write(input, sorted_cdxj)

      result = CDX::Repacker.repack(input, output, where: ["=status:200", "=mime_detected:text/html"])

      assert_equal 1, result.record_count
      assert_equal ["https://example.com/about"], CDX::Index.open(output).map(&:url)
    end
  end

  def test_repack_rejects_same_input_and_output_path
    Dir.mktmpdir do |dir|
      input = File.join(dir, "sample.cdxj")
      File.write(input, sorted_cdxj)

      error = assert_raises(ArgumentError) do
        CDX::Repacker.repack(input, input)
      end

      assert_match(/input and output paths must be different/, error.message)
      assert_equal sorted_cdxj, File.read(input)
    end
  end

  def test_repack_rejects_symlinked_input_and_output_same_file
    Dir.mktmpdir do |dir|
      input = File.join(dir, "sample.cdxj")
      link = File.join(dir, "sample-link.cdxj")
      File.write(input, sorted_cdxj)
      File.symlink(input, link)

      error = assert_raises(ArgumentError) do
        CDX::Repacker.repack(link, input, force: true)
      end

      assert_match(/input and output paths must be different/, error.message)
      assert_equal sorted_cdxj, File.read(input)
    end
  end

  def test_cli_repack_requires_force_to_overwrite_existing_output
    Dir.mktmpdir do |dir|
      input = File.join(dir, "sample.cdxj")
      output = File.join(dir, "sample.rbcdx")
      File.write(input, sorted_cdxj)
      File.write(output, "existing")
      out = StringIO.new
      err = StringIO.new

      status = CDX::CLI.start(["repack", "--output", output, input], out: out, err: err)

      assert_equal 1, status
      assert_empty out.string
      assert_match(/output already exists/, err.string)
      assert_equal "existing", File.read(output)

      status = CDX::CLI.start(["repack", "--output", output, "--force", input], out: out, err: StringIO.new)

      assert_equal 0, status
      assert_equal 3, CDX::Index.open(output).count
    end
  end

  def test_cli_repack_accepts_collapse_urlkey
    Dir.mktmpdir do |dir|
      input = File.join(dir, "collapse.cdxj")
      output = File.join(dir, "collapse.rbcdx")
      File.write(input, collapse_repack_cdxj)
      out = StringIO.new

      status = CDX::CLI.start(["repack", "--output", output, "--collapse", "urlkey", input], out: out, err: StringIO.new)

      assert_equal 0, status
      assert_equal "#{output}\n", out.string
      assert_equal %w[20250103000000 20250104000000], CDX::Index.open(output).map(&:timestamp)
      assert_equal(
        {"field" => "urlkey", "order" => "latest"},
        CDX::Repacker.read_header(output).fetch("repack").fetch("collapse_signature")
      )
    end
  end

  def test_repack_many_writes_outputs_state_manifest_and_progress
    Dir.mktmpdir do |dir|
      input_dir = File.join(dir, "cdx")
      output_dir = File.join(dir, "rbcdx")
      FileUtils.mkdir_p(input_dir)
      gzip_write(File.join(input_dir, "cdx-00000.gz"), sorted_cdxj)
      gzip_write(File.join(input_dir, "cdx-00001.gz"), duplicate_urlkey_cdxj)
      events = []

      results = CDX::Repacker.repack_many(
        [input_dir],
        output_dir: output_dir,
        max_records: 1,
        progress: ->(event, **payload) { events << [event, payload[:entry]&.fetch("output_path") || payload[:path]] }
      )

      assert_equal [:written, :written], results.map(&:status)
      assert File.file?(File.join(output_dir, "cdx-00000.rbcdx"))
      assert File.file?(File.join(output_dir, "cdx-00001.rbcdx"))
      assert File.file?(File.join(output_dir, CDX::BatchRepacker::STATE_FILENAME))
      assert File.file?(File.join(output_dir, CDX::Backends::RbCDX::Manifest::FILENAME))
      assert_equal ["https://example.com/about"], CDX::Index.open(File.join(output_dir, "cdx-00000.rbcdx")).captures("example.com/about").map(&:url)
      assert_includes events.map(&:first), :state_start
      assert_includes events.map(&:first), :state_finish
      assert_includes events.map(&:first), :start
      assert_includes events.map(&:first), :finish
    end
  end

  def test_repack_many_collapse_urlkey_selects_globally_across_inputs
    Dir.mktmpdir do |dir|
      input_dir = File.join(dir, "cdx")
      output_dir = File.join(dir, "rbcdx")
      FileUtils.mkdir_p(input_dir)
      first = File.join(input_dir, "cdx-00000.cdxj")
      second = File.join(input_dir, "cdx-00001.cdxj")
      File.write(first, collapse_batch_first_cdxj)
      File.write(second, collapse_batch_second_cdxj)

      results = CDX::Repacker.repack_many([input_dir], output_dir: output_dir, collapse: :urlkey)

      assert_equal [:written, :written], results.map(&:status)
      index = CDX::Index.open(output_dir)
      assert_equal [
        "https://batch-collapse.example/a",
        "https://batch-collapse.example/b"
      ], index.captures("batch-collapse.example/*").map(&:url)
      assert_equal ["20250105000000"], index.captures("batch-collapse.example/a").map(&:timestamp)
      assert_equal 0, CDX::Index.open(File.join(output_dir, "cdx-00000.rbcdx")).count
      assert File.file?(File.join(output_dir, CDX::BatchRepacker::SELECTION_DIRNAME, "00000-cdx-00000.rbcdx.lines"))
      assert File.file?(File.join(output_dir, CDX::BatchRepacker::SELECTION_DIRNAME, "00001-cdx-00001.rbcdx.lines"))
      header = CDX::Repacker.read_header(File.join(output_dir, "cdx-00001.rbcdx"))
      assert_equal(
        {"field" => "urlkey", "order" => "latest"},
        header.fetch("repack").fetch("collapse_signature")
      )
      state = JSON.parse(File.read(File.join(output_dir, CDX::BatchRepacker::STATE_FILENAME)))
      assert_equal(
        {"field" => "urlkey", "order" => "latest"},
        state.fetch("plan").fetch("collapse_signature")
      )
      assert state.fetch("entries").all? { |entry| entry.fetch("selection_path").end_with?(".lines") }
    end
  end

  def test_repack_many_collapse_rejects_inputs_that_are_not_globally_grouped
    Dir.mktmpdir do |dir|
      input_dir = File.join(dir, "cdx")
      output_dir = File.join(dir, "rbcdx")
      FileUtils.mkdir_p(input_dir)
      File.write(File.join(input_dir, "cdx-00000.cdxj"), collapse_ungrouped_first_cdxj)
      File.write(File.join(input_dir, "cdx-00001.cdxj"), collapse_ungrouped_second_cdxj)

      error = assert_raises(CDX::UnsupportedCollapse) do
        CDX::Repacker.repack_many([input_dir], output_dir: output_dir, collapse: :urlkey)
      end

      assert_match(/globally urlkey-grouped input files/, error.message)
      refute File.exist?(File.join(output_dir, CDX::BatchRepacker::STATE_FILENAME))
    end
  end

  def test_repack_many_collapse_resume_uses_persisted_selection_after_delete
    Dir.mktmpdir do |dir|
      input_dir = File.join(dir, "cdx")
      output_dir = File.join(dir, "rbcdx")
      FileUtils.mkdir_p(input_dir)
      first = File.join(input_dir, "cdx-00000.cdxj")
      second = File.join(input_dir, "cdx-00001.cdxj")
      File.write(first, collapse_batch_first_cdxj)
      File.write(second, collapse_batch_second_cdxj)

      CDX::Repacker.repack_many([input_dir], output_dir: output_dir, collapse: :urlkey, delete_when_processed: true)
      results = CDX::Repacker.repack_many([input_dir], output_dir: output_dir, collapse: :urlkey, resume: true, delete_when_processed: true)

      assert_equal [:skipped, :skipped], results.map(&:status)
      refute File.exist?(first)
      refute File.exist?(second)
      assert_equal ["20250105000000"], CDX::Index.open(output_dir).captures("batch-collapse.example/a").map(&:timestamp)
    end
  end

  def test_repack_many_collapse_resume_rejects_output_with_wrong_selected_fingerprint
    Dir.mktmpdir do |dir|
      input_dir = File.join(dir, "cdx")
      output_dir = File.join(dir, "rbcdx")
      FileUtils.mkdir_p(input_dir)
      first = File.join(input_dir, "cdx-00000.cdxj")
      second = File.join(input_dir, "cdx-00001.cdxj")
      File.write(first, collapse_batch_first_cdxj)
      File.write(second, collapse_batch_second_cdxj)
      CDX::Repacker.repack_many([input_dir], output_dir: output_dir, collapse: :urlkey)
      stale_output = File.join(output_dir, "cdx-00000.rbcdx")
      CDX::Repacker.repack(first, stale_output, collapse: :urlkey, force: true)

      error = assert_raises(CDX::Error) do
        CDX::Repacker.repack_many([input_dir], output_dir: output_dir, collapse: :urlkey, resume: true, delete_when_processed: true)
      end

      assert_match(/output already exists and does not match/, error.message)
      assert File.exist?(first)
      assert File.exist?(second)
    end
  end

  def test_repack_many_collapse_resume_rejects_corrupted_selection_sidecar
    Dir.mktmpdir do |dir|
      input_dir = File.join(dir, "cdx")
      output_dir = File.join(dir, "rbcdx")
      FileUtils.mkdir_p(input_dir)
      File.write(File.join(input_dir, "cdx-00000.cdxj"), collapse_batch_first_cdxj)
      File.write(File.join(input_dir, "cdx-00001.cdxj"), collapse_batch_second_cdxj)
      CDX::Repacker.repack_many([input_dir], output_dir: output_dir, collapse: :urlkey)
      state = JSON.parse(File.read(File.join(output_dir, CDX::BatchRepacker::STATE_FILENAME)))
      second_entry = state.fetch("entries").last
      File.write(second_entry.fetch("selection_path"), "2\n")
      File.delete(second_entry.fetch("output_path"))

      error = assert_raises(CDX::Error) do
        CDX::Repacker.repack_many([input_dir], output_dir: output_dir, collapse: :urlkey, resume: true)
      end

      assert_match(/collapse selection sidecar does not match this repack plan/, error.message)
      refute File.exist?(second_entry.fetch("output_path"))
    end
  end

  def test_repack_many_collapse_resume_recovers_output_published_before_state_result
    Dir.mktmpdir do |dir|
      input_dir = File.join(dir, "cdx")
      output_dir = File.join(dir, "rbcdx")
      FileUtils.mkdir_p(input_dir)
      first = File.join(input_dir, "cdx-00000.cdxj")
      second = File.join(input_dir, "cdx-00001.cdxj")
      File.write(first, collapse_batch_first_cdxj)
      File.write(second, collapse_batch_second_cdxj)
      CDX::Repacker.repack_many([input_dir], output_dir: output_dir, collapse: :urlkey)
      state_path = File.join(output_dir, CDX::BatchRepacker::STATE_FILENAME)
      state = JSON.parse(File.read(state_path))
      interrupted = state.fetch("entries").first
      interrupted["status"] = "processing"
      interrupted.delete("output_signature")
      interrupted.delete("record_count")
      interrupted.delete("selected_fingerprint")
      File.write(state_path, "#{JSON.pretty_generate(state)}\n")

      results = CDX::Repacker.repack_many([input_dir], output_dir: output_dir, collapse: :urlkey, resume: true)

      assert_equal [:skipped, :skipped], results.map(&:status)
      recovered = JSON.parse(File.read(state_path)).fetch("entries").first
      assert_equal "complete", recovered.fetch("status")
      assert recovered.fetch("selected_fingerprint").is_a?(Hash)
      assert_equal 0, recovered.fetch("selected_fingerprint").fetch("count")
    end
  end

  def test_repack_progress_reports_prepare_and_write_phases
    Dir.mktmpdir do |dir|
      input = File.join(dir, "sample.cdxj")
      output = File.join(dir, "sample.rbcdx")
      File.write(input, sorted_cdxj)
      events = []

      CDX::Repacker.repack(
        input,
        output,
        progress: ->(event, **payload) { events << [event, payload] }
      )

      progress_events = events.filter_map { |event, payload| payload if event == :progress }
      assert_includes progress_events.map { |payload| payload.fetch(:phase) }, "prepare"
      assert_includes progress_events.map { |payload| payload.fetch(:phase) }, "write"
      assert progress_events.any? { |payload| payload.fetch(:processed_bytes) == File.size(input) }
      assert progress_events.any? { |payload| payload.fetch(:selected_records) == 3 }
    end
  end

  def test_repack_many_rebuilds_manifest_once_after_batch_even_when_deleting_sources
    Dir.mktmpdir do |dir|
      input_dir = File.join(dir, "cdx")
      output_dir = File.join(dir, "rbcdx")
      FileUtils.mkdir_p(input_dir)
      first = File.join(input_dir, "cdx-00000.gz")
      second = File.join(input_dir, "cdx-00001.gz")
      gzip_write(first, sorted_cdxj)
      gzip_write(second, duplicate_urlkey_cdxj)

      with_manifest_build_tracking do |builds|
        results = CDX::Repacker.repack_many([input_dir], output_dir: output_dir, delete_when_processed: true)

        assert_equal [:written, :written], results.map(&:status)
        assert_equal 1, builds.length
        assert_equal(
          [File.join(output_dir, "cdx-00000.rbcdx"), File.join(output_dir, "cdx-00001.rbcdx")],
          builds.first
        )
      end

      refute File.exist?(first)
      refute File.exist?(second)
      manifest = JSON.parse(File.read(File.join(output_dir, CDX::Backends::RbCDX::Manifest::FILENAME)))
      assert_equal ["cdx-00000.rbcdx", "cdx-00001.rbcdx"], manifest.fetch("files").map { |entry| entry.fetch("path") }.sort
      assert_equal ["deleted", "deleted"], JSON.parse(File.read(File.join(output_dir, CDX::BatchRepacker::STATE_FILENAME))).fetch("entries").map { |entry| entry.fetch("status") }
    end
  end

  def test_repack_many_dry_run_prints_plan_without_writing
    Dir.mktmpdir do |dir|
      input_dir = File.join(dir, "cdx")
      FileUtils.mkdir_p(input_dir)
      input = File.join(input_dir, "sample.cdxj")
      output_dir = File.join(dir, "rbcdx")
      File.write(input, sorted_cdxj)
      events = []

      results = CDX::Repacker.repack_many(
        [input],
        output_dir: output_dir,
        dry_run: true,
        progress: ->(event, **payload) { events << [event, payload[:entry]&.fetch("output_path") || payload[:path]] }
      )

      assert_equal [:planned], results.map(&:status)
      assert_equal 3, results.first.result.record_count
      assert_equal 3, results.first.result.total_records
      refute Dir.exist?(output_dir)
      assert_equal [
        [:planned, File.join(output_dir, "sample.rbcdx")],
        [:preview, File.join(output_dir, "sample.rbcdx")]
      ], events
    end
  end

  def test_repack_many_dry_run_reports_filtered_count
    Dir.mktmpdir do |dir|
      input_dir = File.join(dir, "cdx")
      FileUtils.mkdir_p(input_dir)
      input = File.join(input_dir, "sample.cdxj")
      output_dir = File.join(dir, "rbcdx")
      File.write(input, sorted_cdxj)

      results = CDX::Repacker.repack_many(
        [input],
        output_dir: output_dir,
        filters: ["status_200"],
        dry_run: true
      )

      assert_equal [:planned], results.map(&:status)
      assert_equal 2, results.first.result.record_count
      assert_equal 3, results.first.result.total_records
      assert_equal 1, results.first.result.filtered_count
      refute Dir.exist?(output_dir)
    end
  end

  def test_repack_many_dry_run_resume_skips_matching_deleted_sources
    Dir.mktmpdir do |dir|
      input = File.join(dir, "sample.cdxj")
      output = File.join(dir, "sample.rbcdx")
      File.write(input, sorted_cdxj)
      CDX::Repacker.repack_many([dir], output_dir: dir, delete_when_processed: true)
      events = []

      results = CDX::Repacker.repack_many(
        [dir],
        output_dir: dir,
        resume: true,
        delete_when_processed: true,
        dry_run: true,
        progress: ->(event, **payload) { events << [event, payload[:entry]&.fetch("output_path") || payload[:path]] }
      )

      assert_equal [:skipped], results.map(&:status)
      refute File.exist?(input)
      assert File.file?(output)
      assert_equal [[:skip, output]], events
    end
  end

  def test_repack_many_dry_run_rejects_existing_output_without_force
    Dir.mktmpdir do |dir|
      input_dir = File.join(dir, "cdx")
      output_dir = File.join(dir, "rbcdx")
      FileUtils.mkdir_p([input_dir, output_dir])
      input = File.join(input_dir, "sample.cdxj")
      output = File.join(output_dir, "sample.rbcdx")
      File.write(input, sorted_cdxj)
      File.write(output, "already here")
      events = []

      error = assert_raises(CDX::Error) do
        CDX::Repacker.repack_many(
          [input],
          output_dir: output_dir,
          dry_run: true,
          progress: ->(event, **payload) { events << [event, payload[:entry]&.fetch("output_path") || payload[:path]] }
        )
      end

      assert_match(/output already exists/, error.message)
      assert_empty events
      assert_equal "already here", File.read(output)
    end
  end

  def test_repack_many_dry_run_allows_existing_output_with_force
    Dir.mktmpdir do |dir|
      input_dir = File.join(dir, "cdx")
      output_dir = File.join(dir, "rbcdx")
      FileUtils.mkdir_p([input_dir, output_dir])
      input = File.join(input_dir, "sample.cdxj")
      output = File.join(output_dir, "sample.rbcdx")
      File.write(input, sorted_cdxj)
      File.write(output, "already here")

      results = CDX::Repacker.repack_many(
        [input],
        output_dir: output_dir,
        dry_run: true,
        force: true
      )

      assert_equal [:planned], results.map(&:status)
      assert_equal 3, results.first.result.total_records
      assert_equal "already here", File.read(output)
    end
  end

  def test_repack_many_requires_resume_or_force_when_state_exists
    Dir.mktmpdir do |dir|
      input_dir = File.join(dir, "cdx")
      FileUtils.mkdir_p(input_dir)
      input = File.join(input_dir, "sample.cdxj")
      output_dir = File.join(dir, "rbcdx")
      File.write(input, sorted_cdxj)
      CDX::Repacker.repack_many([input], output_dir: output_dir)

      error = assert_raises(CDX::Error) do
        CDX::Repacker.repack_many([input], output_dir: output_dir)
      end

      assert_match(/repack state already exists/, error.message)
    end
  end

  def test_repack_many_resume_skips_matching_output
    Dir.mktmpdir do |dir|
      input_dir = File.join(dir, "cdx")
      FileUtils.mkdir_p(input_dir)
      input = File.join(input_dir, "sample.cdxj")
      output_dir = File.join(dir, "rbcdx")
      File.write(input, sorted_cdxj)
      CDX::Repacker.repack_many([input], output_dir: output_dir)

      results = CDX::Repacker.repack_many([input], output_dir: output_dir, resume: true)

      assert_equal [:skipped], results.map(&:status)
      assert_equal 3, CDX::Index.open(File.join(output_dir, "sample.rbcdx")).count
    end
  end

  def test_repack_many_delete_when_processed_deletes_after_resume_skip
    Dir.mktmpdir do |dir|
      input_dir = File.join(dir, "cdx")
      output_dir = File.join(dir, "rbcdx")
      FileUtils.mkdir_p(input_dir)
      input = File.join(input_dir, "sample.cdxj")
      File.write(input, sorted_cdxj)
      CDX::Repacker.repack_many([input_dir], output_dir: output_dir)

      results = CDX::Repacker.repack_many([input_dir], output_dir: output_dir, resume: true, delete_when_processed: true)

      assert_equal [:skipped], results.map(&:status)
      refute File.exist?(input)
      assert_equal ["deleted"], JSON.parse(File.read(File.join(output_dir, CDX::BatchRepacker::STATE_FILENAME))).fetch("entries").map { |entry| entry.fetch("status") }
    end
  end

  def test_repack_many_resume_does_not_delete_source_for_mismatched_output_metadata
    Dir.mktmpdir do |dir|
      input_dir = File.join(dir, "cdx")
      output_dir = File.join(dir, "rbcdx")
      FileUtils.mkdir_p(input_dir)
      input = File.join(input_dir, "sample.cdxj")
      output = File.join(output_dir, "sample.rbcdx")
      File.write(input, sorted_cdxj)
      CDX::Repacker.repack_many([input_dir], output_dir: output_dir)
      corrupt_record_count(output)

      error = assert_raises(CDX::Error) do
        CDX::Repacker.repack_many([input_dir], output_dir: output_dir, resume: true, delete_when_processed: true)
      end

      assert_match(/output already exists and does not match/, error.message)
      assert File.exist?(input)
    end
  end

  def test_repack_many_resume_recovers_when_deleted_source_is_missing
    Dir.mktmpdir do |dir|
      input_dir = File.join(dir, "cdx")
      output_dir = File.join(dir, "rbcdx")
      FileUtils.mkdir_p(input_dir)
      input = File.join(input_dir, "sample.cdxj")
      File.write(input, sorted_cdxj)
      CDX::Repacker.repack_many([input_dir], output_dir: output_dir, delete_when_processed: true)

      results = CDX::Repacker.repack_many([input_dir], output_dir: output_dir, resume: true, delete_when_processed: true)

      assert_equal [:skipped], results.map(&:status)
      refute File.exist?(input)
      assert File.file?(File.join(output_dir, "sample.rbcdx"))
    end
  end

  def test_repack_many_allows_same_directory_without_deleting_sources
    Dir.mktmpdir do |dir|
      input = File.join(dir, "sample.cdxj")
      output = File.join(dir, "sample.rbcdx")
      File.write(input, sorted_cdxj)

      results = CDX::Repacker.repack_many([input], output_dir: dir)

      assert_equal [:written], results.map(&:status)
      assert File.exist?(input)
      assert File.file?(output)
      assert_equal ["https://example.com/about"], CDX::Index.open(output).captures("example.com/about").map(&:url)
    end
  end

  def test_repack_many_allows_same_directory_when_deleting_sources
    Dir.mktmpdir do |dir|
      input = File.join(dir, "sample.cdxj")
      output = File.join(dir, "sample.rbcdx")
      File.write(input, sorted_cdxj)

      results = CDX::Repacker.repack_many([dir], output_dir: dir, delete_when_processed: true)

      assert_equal [:written], results.map(&:status)
      refute File.exist?(input)
      assert File.file?(output)
      assert File.file?(File.join(dir, CDX::BatchRepacker::STATE_FILENAME))
      assert File.file?(File.join(dir, CDX::Backends::RbCDX::Manifest::FILENAME))
      assert_equal ["https://example.com/about"], CDX::Index.open(dir).captures("example.com/about").map(&:url)

      resumed = CDX::Repacker.repack_many([dir], output_dir: dir, resume: true, delete_when_processed: true)
      assert_equal [:skipped], resumed.map(&:status)
    end
  end

  def test_repack_many_allows_output_directory_inside_input_directory
    Dir.mktmpdir do |dir|
      input_dir = File.join(dir, "cdx")
      output_dir = File.join(input_dir, "rbcdx")
      FileUtils.mkdir_p(input_dir)
      input = File.join(input_dir, "sample.cdxj")
      File.write(input, sorted_cdxj)

      results = CDX::Repacker.repack_many([input_dir], output_dir: output_dir)

      assert_equal [:written], results.map(&:status)
      assert File.exist?(input)
      assert_equal ["https://example.com/about"], CDX::Index.open(File.join(output_dir, "sample.rbcdx")).captures("example.com/about").map(&:url)
    end
  end

  def test_repack_many_allows_glob_output_directory_inside_input_tree
    Dir.mktmpdir do |dir|
      input_dir = File.join(dir, "cdx")
      output_dir = File.join(input_dir, "rbcdx")
      FileUtils.mkdir_p(input_dir)
      File.write(File.join(input_dir, "sample.cdxj"), sorted_cdxj)

      results = CDX::Repacker.repack_many([File.join(input_dir, "*.cdxj")], output_dir: output_dir)

      assert_equal [:written], results.map(&:status)
      assert File.file?(File.join(output_dir, "sample.rbcdx"))
    end
  end

  def test_repack_many_allows_recursive_glob_output_directory_inside_input_tree
    Dir.mktmpdir do |dir|
      input_dir = File.join(dir, "cdx")
      shard_dir = File.join(input_dir, "shards")
      output_dir = File.join(input_dir, "rbcdx")
      FileUtils.mkdir_p(shard_dir)
      File.write(File.join(shard_dir, "sample.cdxj"), sorted_cdxj)

      results = CDX::Repacker.repack_many([File.join(input_dir, "**", "*.cdxj")], output_dir: output_dir)

      assert_equal [:written], results.map(&:status)
      assert File.file?(File.join(output_dir, "sample.rbcdx"))
    end
  end

  def test_repack_many_allows_symlinked_output_directory_inside_input_tree
    Dir.mktmpdir do |dir|
      input_dir = File.join(dir, "cdx")
      output_dir = File.join(dir, "rbcdx-link")
      input = File.join(input_dir, "sample.cdxj")
      FileUtils.mkdir_p(input_dir)
      File.write(input, sorted_cdxj)
      File.symlink(input_dir, output_dir)

      results = CDX::Repacker.repack_many([input_dir], output_dir: output_dir)

      assert_equal [:written], results.map(&:status)
      assert File.exist?(input)
      assert File.file?(File.join(input_dir, "sample.rbcdx"))
    end
  end

  def test_repack_many_does_not_rebuild_manifest_for_partial_failed_batch
    Dir.mktmpdir do |dir|
      input_dir = File.join(dir, "cdx")
      output_dir = File.join(dir, "rbcdx")
      FileUtils.mkdir_p([input_dir, output_dir])
      first = File.join(input_dir, "first.cdxj")
      second = File.join(input_dir, "second.cdxj")
      stale_input = File.join(dir, "stale.cdxj")
      File.write(first, sorted_cdxj)
      File.write(second, duplicate_urlkey_cdxj)
      File.write(stale_input, sorted_cdxj)
      CDX::Repacker.repack(stale_input, File.join(output_dir, "second.rbcdx"))

      error = assert_raises(CDX::Error) do
        CDX::Repacker.repack_many([first, second], output_dir: output_dir)
      end

      assert_match(/output already exists/, error.message)
      refute File.exist?(File.join(output_dir, CDX::Backends::RbCDX::Manifest::FILENAME))
      state = JSON.parse(File.read(File.join(output_dir, CDX::BatchRepacker::STATE_FILENAME)))
      assert_equal ["complete", "failed"], state.fetch("entries").map { |entry| entry.fetch("status") }
    end
  end

  def test_repack_many_requires_filter_signature_for_proc_filters_when_resumable
    Dir.mktmpdir do |dir|
      input_dir = File.join(dir, "cdx")
      FileUtils.mkdir_p(input_dir)
      input = File.join(input_dir, "sample.cdxj")
      output_dir = File.join(dir, "rbcdx")
      File.write(input, sorted_cdxj)

      error = assert_raises(ArgumentError) do
        CDX::Repacker.repack_many([input], output_dir: output_dir, resume: true, filters: [->(_record) { true }])
      end

      assert_match(/filter_signature/, error.message)
    end
  end

  def test_repack_many_accepts_proc_filters_with_explicit_signature
    Dir.mktmpdir do |dir|
      input_dir = File.join(dir, "cdx")
      FileUtils.mkdir_p(input_dir)
      input = File.join(input_dir, "sample.cdxj")
      output_dir = File.join(dir, "rbcdx")
      File.write(input, sorted_cdxj)

      results = CDX::Repacker.repack_many(
        [input],
        output_dir: output_dir,
        resume: true,
        filters: [->(record) { record.status == "200" }],
        filter_signature: "status-is-200"
      )

      assert_equal [:written], results.map(&:status)
      assert_equal ["https://example.com/about", "https://blog.example.com/post"], CDX::Index.open(File.join(output_dir, "sample.rbcdx")).map(&:url)
    end
  end

  def test_cli_repack_many_dry_run
    Dir.mktmpdir do |dir|
      input_dir = File.join(dir, "cdx")
      FileUtils.mkdir_p(input_dir)
      input = File.join(input_dir, "sample.cdxj")
      output_dir = File.join(dir, "rbcdx")
      File.write(input, sorted_cdxj)
      out = StringIO.new
      err = StringIO.new

      status = CDX::CLI.start(["repack", "--output-dir", output_dir, "--dry-run", input], out: out, err: err)

      assert_equal 0, status
      assert_match(/would create \[1\/1\].*sample\.rbcdx from .*sample\.cdxj/, out.string)
      assert_match(/filtered \[1\/1\].*sample\.cdxj: 3 of 3 records selected/, out.string)
      assert_empty err.string
      refute Dir.exist?(output_dir)
    end
  end

  def test_cli_repack_many_dry_run_reports_delete_plan
    Dir.mktmpdir do |dir|
      input = File.join(dir, "sample.cdxj")
      File.write(input, sorted_cdxj)
      out = StringIO.new
      err = StringIO.new

      status = CDX::CLI.start(["repack", "--output-dir", dir, "--delete-when-processed", "--dry-run", input], out: out, err: err)

      assert_equal 0, status
      assert_match(/would create \[1\/1\].*sample\.rbcdx from .*sample\.cdxj/, out.string)
      assert_match(/would delete after written output \[1\/1\] #{Regexp.escape(input)}/, out.string)
      assert_match(/filtered \[1\/1\].*sample\.cdxj: 3 of 3 records selected/, out.string)
      assert_empty err.string
      assert File.exist?(input)
      refute File.exist?(File.join(dir, "sample.rbcdx"))
    end
  end

  def test_cli_repack_defaults_to_current_directory_for_batch_input_and_output
    Dir.mktmpdir do |dir|
      input = File.join(dir, "sample.cdxj")
      output = File.join(dir, "sample.rbcdx")
      File.write(input, sorted_cdxj)
      out = StringIO.new
      err = StringIO.new
      previous = Dir.pwd

      Dir.chdir(dir) do
        status = CDX::CLI.start(["repack"], out: out, err: err)

        assert_equal 0, status
      end

      assert_equal "#{File.join(File.realpath(dir), "sample.rbcdx")}\n", out.string
      assert_includes err.string, "created resume log "
      assert_includes err.string, CDX::CLI::REPACK_LOG_FILENAME
      assert_match(/if interrupted, run: rbcdx repack --resume/, err.string)
      assert_includes err.string, "created repack state "
      assert_includes err.string, CDX::BatchRepacker::STATE_FILENAME
      assert_match(/processing \[1\/1\]/, err.string)
      assert_includes err.string, "removed resume log "
      assert_includes err.string, CDX::CLI::REPACK_LOG_FILENAME
      assert File.exist?(input)
      assert File.file?(output)
    ensure
      Dir.chdir(previous) if previous
    end
  end

  def test_cli_repack_output_dir_defaults_input_to_current_directory
    Dir.mktmpdir do |dir|
      input = File.join(dir, "sample.cdxj")
      output_dir = File.join(dir, "out")
      File.write(input, sorted_cdxj)
      out = StringIO.new
      previous = Dir.pwd

      Dir.chdir(dir) do
        status = CDX::CLI.start(["repack", "--output-dir", output_dir], out: out, err: StringIO.new)

        assert_equal 0, status
      end

      assert_match(/sample\.rbcdx/, out.string)
      assert File.file?(File.join(output_dir, "sample.rbcdx"))
    ensure
      Dir.chdir(previous) if previous
    end
  end

  def test_cli_repack_resume_uses_request_log
    Dir.mktmpdir do |dir|
      input = File.join(dir, "sample.cdxj")
      output_dir = File.join(dir, "packed")
      log_path = File.join(dir, CDX::CLI::REPACK_LOG_FILENAME)
      real_log_path = File.join(File.realpath(dir), CDX::CLI::REPACK_LOG_FILENAME)
      File.write(input, sorted_cdxj)
      previous = Dir.pwd

      Dir.chdir(dir) do
        calls = 0
        original_repack = CDX::Repacker.method(:repack)
        replacement_repack = lambda do |*args, **options|
          calls += 1
          raise CDX::Error, "simulated interruption" if calls == 1

          original_repack.call(*args, **options)
        end

        with_singleton_replacement(CDX::Repacker, :repack, replacement_repack) do
          first_err = StringIO.new
          status = CDX::CLI.start(["repack", "--output-dir", output_dir, "--filter", "status_200", input], out: StringIO.new, err: first_err)

          assert_equal 1, status
          assert_includes first_err.string, "created resume log #{real_log_path}"
          assert_match(/if interrupted, run: rbcdx repack --resume/, first_err.string)
          assert_includes first_err.string, "created repack state "
          assert_includes first_err.string, CDX::BatchRepacker::STATE_FILENAME
          assert_includes first_err.string, "resume log kept #{real_log_path}"
          assert_match(/resume with: rbcdx repack --resume/, first_err.string)
        end

        log = JSON.parse(File.read(log_path))
        assert_equal "rbcdx-repack-log", log.fetch("format")
        assert_equal [input], log.fetch("request").fetch("inputs")
        assert_equal output_dir, log.fetch("request").fetch("options").fetch("output_dir")
        assert_equal ["status_200"], log.fetch("request").fetch("options").fetch("filters")

        out = StringIO.new
        err = StringIO.new
        status = CDX::CLI.start(["repack", "--resume"], out: out, err: err)

        assert_equal 0, status
        assert_includes err.string, "resuming from #{real_log_path}"
        assert_includes err.string, "loaded repack state "
        assert_includes err.string, CDX::BatchRepacker::STATE_FILENAME
        assert_match(/processing \[1\/1\]/, err.string)
        assert_includes err.string, "removed resume log #{real_log_path}"
        assert_equal "#{File.join(output_dir, "sample.rbcdx")}\n", out.string
        assert File.file?(File.join(output_dir, "sample.rbcdx"))
        refute File.exist?(log_path)
      end
    ensure
      Dir.chdir(previous) if previous
    end
  end

  def test_cli_repack_resume_without_log_is_clear
    Dir.mktmpdir do |dir|
      out = StringIO.new
      err = StringIO.new
      previous = Dir.pwd

      Dir.chdir(dir) do
        status = CDX::CLI.start(["repack", "--resume"], out: out, err: err)

        assert_equal 1, status
      end

      assert_empty out.string
      assert_match(/no repack log found/, err.string)
      assert_includes err.string, CDX::CLI::REPACK_LOG_FILENAME
    ensure
      Dir.chdir(previous) if previous
    end
  end

  def test_cli_repack_resume_rejects_malformed_request_log
    Dir.mktmpdir do |dir|
      log_path = File.join(dir, CDX::CLI::REPACK_LOG_FILENAME)
      File.write(log_path, "{not-json}\n")
      out = StringIO.new
      err = StringIO.new
      previous = Dir.pwd

      Dir.chdir(dir) do
        status = CDX::CLI.start(["repack", "--resume"], out: out, err: err)

        assert_equal 1, status
      end

      assert_empty out.string
      assert_match(/malformed repack log JSON/, err.string)
      assert File.exist?(log_path)
    ensure
      Dir.chdir(previous) if previous
    end
  end

  def test_cli_repack_resume_rejects_invalid_request_log_shape
    Dir.mktmpdir do |dir|
      log_path = File.join(dir, CDX::CLI::REPACK_LOG_FILENAME)
      File.write(log_path, "#{JSON.pretty_generate({"format" => CDX::CLI::REPACK_LOG_FORMAT, "version" => CDX::CLI::REPACK_LOG_VERSION, "request" => "nope"})}\n")
      out = StringIO.new
      err = StringIO.new
      previous = Dir.pwd

      Dir.chdir(dir) do
        status = CDX::CLI.start(["repack", "--resume"], out: out, err: err)

        assert_equal 1, status
      end

      assert_empty out.string
      assert_match(/invalid repack log request/, err.string)
      assert File.exist?(log_path)
    ensure
      Dir.chdir(previous) if previous
    end
  end

  def test_cli_repack_resume_rejects_invalid_request_log_inputs
    Dir.mktmpdir do |dir|
      log_path = File.join(dir, CDX::CLI::REPACK_LOG_FILENAME)
      write_cli_repack_log(log_path, inputs: [nil], output_dir: File.join(dir, "packed"))
      out = StringIO.new
      err = StringIO.new
      previous = Dir.pwd

      Dir.chdir(dir) do
        status = CDX::CLI.start(["repack", "--resume"], out: out, err: err)

        assert_equal 1, status
      end

      assert_empty out.string
      assert_match(/invalid repack log input path/, err.string)
      assert File.exist?(log_path)
    ensure
      Dir.chdir(previous) if previous
    end
  end

  def test_cli_repack_resume_rejects_empty_request_log_inputs
    Dir.mktmpdir do |dir|
      log_path = File.join(dir, CDX::CLI::REPACK_LOG_FILENAME)
      write_cli_repack_log(log_path, inputs: [], output_dir: File.join(dir, "packed"))
      out = StringIO.new
      err = StringIO.new
      previous = Dir.pwd

      Dir.chdir(dir) do
        status = CDX::CLI.start(["repack", "--resume"], out: out, err: err)

        assert_equal 1, status
      end

      assert_empty out.string
      assert_match(/invalid repack log input path/, err.string)
      assert File.exist?(log_path)
    ensure
      Dir.chdir(previous) if previous
    end
  end

  def test_cli_repack_resume_rejects_non_boolean_delete_when_processed
    Dir.mktmpdir do |dir|
      input = File.join(dir, "sample.cdxj")
      output_dir = File.join(dir, "packed")
      log_path = File.join(dir, CDX::CLI::REPACK_LOG_FILENAME)
      File.write(input, sorted_cdxj)
      write_cli_repack_log(log_path, inputs: [input], output_dir: output_dir, delete_when_processed: "false")
      out = StringIO.new
      err = StringIO.new
      previous = Dir.pwd

      Dir.chdir(dir) do
        status = CDX::CLI.start(["repack", "--resume"], out: out, err: err)

        assert_equal 1, status
      end

      assert_empty out.string
      assert_match(/invalid repack log delete_when_processed/, err.string)
      assert File.exist?(input)
      refute File.exist?(File.join(output_dir, "sample.rbcdx"))
      assert File.exist?(log_path)
    ensure
      Dir.chdir(previous) if previous
    end
  end

  def test_cli_repack_resume_rejects_unsupported_request_log_version
    Dir.mktmpdir do |dir|
      log_path = File.join(dir, CDX::CLI::REPACK_LOG_FILENAME)
      write_cli_repack_log(log_path, inputs: [], output_dir: File.join(dir, "packed"), version: 999)
      out = StringIO.new
      err = StringIO.new
      previous = Dir.pwd

      Dir.chdir(dir) do
        status = CDX::CLI.start(["repack", "--resume"], out: out, err: err)

        assert_equal 1, status
      end

      assert_empty out.string
      assert_match(/unsupported repack log version 999/, err.string)
      assert File.exist?(log_path)
    ensure
      Dir.chdir(previous) if previous
    end
  end

  def test_cli_repack_resume_uses_request_log_when_state_is_missing
    Dir.mktmpdir do |dir|
      input = File.join(dir, "sample.cdxj")
      output_dir = File.join(dir, "packed")
      log_path = File.join(dir, CDX::CLI::REPACK_LOG_FILENAME)
      File.write(input, sorted_cdxj)
      write_cli_repack_log(log_path, inputs: [input], output_dir: output_dir, filters: ["status_200"])
      out = StringIO.new
      err = StringIO.new
      previous = Dir.pwd

      Dir.chdir(dir) do
        status = CDX::CLI.start(["repack", "--resume"], out: out, err: err)

        assert_equal 0, status
      end

      assert_equal "#{File.join(output_dir, "sample.rbcdx")}\n", out.string
      assert_includes err.string, "resuming from #{File.join(File.realpath(dir), CDX::CLI::REPACK_LOG_FILENAME)}"
      assert_match(/creating repack state/, err.string)
      assert_match(/processing \[1\/1\]/, err.string)
      assert File.file?(File.join(output_dir, "sample.rbcdx"))
      refute File.exist?(log_path)
    ensure
      Dir.chdir(previous) if previous
    end
  end

  def test_cli_repack_resume_clears_collapse_when_request_log_omits_it
    Dir.mktmpdir do |dir|
      input = File.join(dir, "duplicates.cdxj")
      output_dir = File.join(dir, "packed")
      log_path = File.join(dir, CDX::CLI::REPACK_LOG_FILENAME)
      File.write(input, duplicate_urlkey_cdxj)
      write_cli_repack_log(log_path, inputs: [input], output_dir: output_dir)
      out = StringIO.new
      err = StringIO.new
      previous = Dir.pwd

      Dir.chdir(dir) do
        status = CDX::CLI.start(["repack", "--resume", "--collapse", "urlkey"], out: out, err: err)

        assert_equal 0, status
      end

      output = File.join(output_dir, "duplicates.rbcdx")
      assert_equal "#{output}\n", out.string
      assert_equal 3, CDX::Index.open(output).captures("example.com/repeat").count
      assert_includes err.string, "resuming from #{File.join(File.realpath(dir), CDX::CLI::REPACK_LOG_FILENAME)}"
      refute File.exist?(log_path)
    ensure
      Dir.chdir(previous) if previous
    end
  end

  def test_cli_repack_resume_keeps_request_log_when_state_is_corrupt
    Dir.mktmpdir do |dir|
      input = File.join(dir, "sample.cdxj")
      output_dir = File.join(dir, "packed")
      log_path = File.join(dir, CDX::CLI::REPACK_LOG_FILENAME)
      state_path = File.join(output_dir, CDX::BatchRepacker::STATE_FILENAME)
      File.write(input, sorted_cdxj)
      FileUtils.mkdir_p(output_dir)
      File.write(state_path, "{not-json}\n")
      write_cli_repack_log(log_path, inputs: [input], output_dir: output_dir)
      out = StringIO.new
      err = StringIO.new
      previous = Dir.pwd

      Dir.chdir(dir) do
        status = CDX::CLI.start(["repack", "--resume"], out: out, err: err)

        assert_equal 1, status
      end

      assert_empty out.string
      assert_match(/malformed repack state JSON/, err.string)
      assert_includes err.string, "resume log kept #{File.join(File.realpath(dir), CDX::CLI::REPACK_LOG_FILENAME)}"
      assert File.exist?(log_path)
      refute File.exist?(File.join(output_dir, "sample.rbcdx"))
    ensure
      Dir.chdir(previous) if previous
    end
  end

  def test_cli_repack_resume_rejects_invalid_state_entries_shape
    Dir.mktmpdir do |dir|
      input = File.join(dir, "sample.cdxj")
      output_dir = File.join(dir, "packed")
      log_path = File.join(dir, CDX::CLI::REPACK_LOG_FILENAME)
      state_path = File.join(output_dir, CDX::BatchRepacker::STATE_FILENAME)
      File.write(input, sorted_cdxj)
      FileUtils.mkdir_p(output_dir)
      File.write(state_path, "#{JSON.pretty_generate({"format" => CDX::BatchRepacker::FORMAT, "version" => CDX::BatchRepacker::VERSION, "entries" => "bad"})}\n")
      write_cli_repack_log(log_path, inputs: [input], output_dir: output_dir)
      out = StringIO.new
      err = StringIO.new
      previous = Dir.pwd

      Dir.chdir(dir) do
        status = CDX::CLI.start(["repack", "--resume"], out: out, err: err)

        assert_equal 1, status
      end

      assert_empty out.string
      assert_match(/invalid repack state entries/, err.string)
      assert_includes err.string, "resume log kept #{File.join(File.realpath(dir), CDX::CLI::REPACK_LOG_FILENAME)}"
      assert File.exist?(log_path)
      assert File.exist?(input)
    ensure
      Dir.chdir(previous) if previous
    end
  end

  def test_cli_repack_resume_rejects_invalid_state_entry
    Dir.mktmpdir do |dir|
      input = File.join(dir, "sample.cdxj")
      output_dir = File.join(dir, "packed")
      log_path = File.join(dir, CDX::CLI::REPACK_LOG_FILENAME)
      state_path = File.join(output_dir, CDX::BatchRepacker::STATE_FILENAME)
      File.write(input, sorted_cdxj)
      FileUtils.mkdir_p(output_dir)
      File.write(state_path, "#{JSON.pretty_generate({"format" => CDX::BatchRepacker::FORMAT, "version" => CDX::BatchRepacker::VERSION, "entries" => [{"input_path" => input}]})}\n")
      write_cli_repack_log(log_path, inputs: [input], output_dir: output_dir)
      out = StringIO.new
      err = StringIO.new
      previous = Dir.pwd

      Dir.chdir(dir) do
        status = CDX::CLI.start(["repack", "--resume"], out: out, err: err)

        assert_equal 1, status
      end

      assert_empty out.string
      assert_match(/invalid repack state entry/, err.string)
      assert_includes err.string, "resume log kept #{File.join(File.realpath(dir), CDX::CLI::REPACK_LOG_FILENAME)}"
      assert File.exist?(log_path)
      assert File.exist?(input)
    ensure
      Dir.chdir(previous) if previous
    end
  end

  def test_cli_repack_resume_rejects_invalid_state_entry_field_types
    Dir.mktmpdir do |dir|
      input = File.join(dir, "sample.cdxj")
      output_dir = File.join(dir, "packed")
      log_path = File.join(dir, CDX::CLI::REPACK_LOG_FILENAME)
      state_path = File.join(output_dir, CDX::BatchRepacker::STATE_FILENAME)
      File.write(input, sorted_cdxj)
      FileUtils.mkdir_p(output_dir)
      File.write(state_path, "#{JSON.pretty_generate({
        "format" => CDX::BatchRepacker::FORMAT,
        "version" => CDX::BatchRepacker::VERSION,
        "plan" => {},
        "entries" => [{
          "input_path" => input,
          "output_path" => [],
          "source_signature" => {},
          "status" => "pending"
        }]
      })}\n")
      write_cli_repack_log(log_path, inputs: [input], output_dir: output_dir)
      out = StringIO.new
      err = StringIO.new
      previous = Dir.pwd

      Dir.chdir(dir) do
        status = CDX::CLI.start(["repack", "--resume"], out: out, err: err)

        assert_equal 1, status
      end

      assert_empty out.string
      assert_match(/invalid repack state entry: invalid entry field type/, err.string)
      assert_includes err.string, "resume log kept #{File.join(File.realpath(dir), CDX::CLI::REPACK_LOG_FILENAME)}"
      assert File.exist?(log_path)
      assert File.exist?(input)
    ensure
      Dir.chdir(previous) if previous
    end
  end

  def test_cli_repack_resume_rejects_explicit_args
    Dir.mktmpdir do |dir|
      input = File.join(dir, "sample.cdxj")
      output_dir = File.join(dir, "packed")
      File.write(input, sorted_cdxj)
      CDX::Repacker.repack_many([input], output_dir: output_dir)
      out = StringIO.new
      err = StringIO.new
      previous = Dir.pwd

      Dir.chdir(dir) do
        status = CDX::CLI.start(["repack", "--resume", "--output-dir", output_dir, input], out: out, err: err)

        assert_equal 1, status
      end

      assert_empty out.string
      assert_match(/repack --resume uses rbcdx-repack-log\.json/, err.string)
      assert_match(/without input paths or --output-dir/, err.string)
    ensure
      Dir.chdir(previous) if previous
    end
  end

  def test_cli_repack_refuses_to_start_over_with_active_log
    Dir.mktmpdir do |dir|
      input = File.join(dir, "sample.cdxj")
      File.write(input, sorted_cdxj)
      File.write(File.join(dir, CDX::CLI::REPACK_LOG_FILENAME), "{}\n")
      previous = Dir.pwd

      Dir.chdir(dir) do
        out = StringIO.new
        err = StringIO.new

        status = CDX::CLI.start(["repack", input], out: out, err: err)

        assert_equal 1, status
        assert_empty out.string
        assert_match(/repack log already exists/, err.string)
      end
    ensure
      Dir.chdir(previous) if previous
    end
  end

  def test_cli_single_file_output_still_requires_input
    out = StringIO.new
    err = StringIO.new

    status = CDX::CLI.start(["repack", "--output", "sample.rbcdx"], out: out, err: err)

    assert_equal 1, status
    assert_match(/missing input CDXJ path/, err.string)
  end

  def test_cli_repack_many_where_filter_and_progress
    Dir.mktmpdir do |dir|
      input_dir = File.join(dir, "cdx")
      FileUtils.mkdir_p(input_dir)
      input = File.join(input_dir, "sample.cdxj")
      output_dir = File.join(dir, "rbcdx")
      File.write(input, sorted_cdxj)
      out = StringIO.new
      err = StringIO.new

      status = CDX::CLI.start(["repack", "--output-dir", output_dir, "--where", "=status:200", input], out: out, err: err)

      assert_equal 0, status
      assert_match(/sample\.rbcdx/, out.string)
      assert_match(/processing \[1\/1\]/, err.string)
      assert_match(/progress \[1\/1\].* prepare /, err.string)
      assert_match(/progress \[1\/1\].* write /, err.string)
      assert_match(/written \[1\/1\]/, err.string)
      assert_equal ["https://example.com/about", "https://blog.example.com/post"], CDX::Index.open(File.join(output_dir, "sample.rbcdx")).map(&:url)
    end
  end

  def test_repack_filters_receive_capture_objects
    Dir.mktmpdir do |dir|
      input = File.join(dir, "sample.cdxj")
      output = File.join(dir, "sample.rbcdx")
      seen = []
      File.write(input, sorted_cdxj)

      CDX::Repacker.repack(
        input,
        output,
        filters: [->(record) {
          seen << record
          true
        }]
      )

      assert seen.all? { |record| record.is_a?(CDX::Capture) }
      assert_equal ["https://example.com/about"], CDX::Index.open(output).captures("example.com/about").map(&:url)
    end
  end

  def test_repack_cdxj_output_preserves_selected_raw_lines
    Dir.mktmpdir do |dir|
      input = File.join(dir, "sample.cdxj")
      output = File.join(dir, "filtered.cdxj")
      lines = sorted_cdxj.lines
      File.write(input, sorted_cdxj)

      result = CDX::Repacker.repack(input, output, output_format: "cdxj", filters: ["status_200"])

      assert_equal 2, result.record_count
      assert_equal "cdxj", result.output_format
      assert_equal lines[1..2].join, File.read(output)
    end
  end

  def test_repack_cdxj_output_format_is_not_inferred_from_filename
    Dir.mktmpdir do |dir|
      input = File.join(dir, "sample.cdxj")
      output = File.join(dir, "anything.rbcdx")
      File.write(input, sorted_cdxj)

      CDX::Repacker.repack(input, output, output_format: "cdxj", filters: ["status_200"])

      refute_equal CDX::Backends::RbCDX::Format::MAGIC, File.binread(output, CDX::Backends::RbCDX::Format::MAGIC.bytesize)
      assert_match(/\Acom,example\)\/about 20240202020202 /, File.read(output))
    end
  end

  def test_repack_cdxj_output_accepts_records_rbcdx_cannot_encode
    Dir.mktmpdir do |dir|
      input = File.join(dir, "future.cdxj")
      output = File.join(dir, "future.cdxj")
      File.write(input, <<~CDXJ)
        com,bad)/ 20240101010101 {"url":"ftp://bad.com/","mime":"text/html","status":"200","length":"10","offset":"1","filename":"crawl-data/CC-MAIN-2025-43/segments/123.45/warc/CC-MAIN-20250101000000-20250101030000-00001.warc.gz","future":"kept"}
      CDXJ

      assert_raises(ArgumentError) { CDX::Repacker.repack(input, input, output_format: "cdxj") }
      CDX::Repacker.repack(input, output.sub(".cdxj", ".out"), output_format: "cdxj")

      assert_match(/"future":"kept"/, File.read(output.sub(".cdxj", ".out")))
    end
  end

  def test_repack_cdxj_gzip_output_uses_output_extension_only_for_compression
    Dir.mktmpdir do |dir|
      input = File.join(dir, "sample.cdxj")
      output = File.join(dir, "weird.name.gz")
      File.write(input, sorted_cdxj)

      CDX::Repacker.repack(input, output, output_format: "cdxj", filters: ["status_200"])

      assert_equal sorted_cdxj.lines[1..2].join, gzip_read(output)
    end
  end

  def test_repack_cdxj_streams_input_once_by_default
    Dir.mktmpdir do |dir|
      input = File.join(dir, "sample.cdxj")
      output = File.join(dir, "sample.cdxj.filtered")
      File.write(input, sorted_cdxj)
      calls = 0
      original = CDX::Backends::CDXJ::RepackReader.instance_method(:each_capture)

      replace_instance_method(CDX::Backends::CDXJ::RepackReader, :each_capture, proc do |&block|
        calls += 1
        original.bind_call(self, &block)
      end)
      begin
        CDX::Repacker.repack(input, output, output_format: "cdxj")

        assert_equal 1, calls
      ensure
        replace_instance_method(CDX::Backends::CDXJ::RepackReader, :each_capture, original)
      end
    end
  end

  def test_repack_many_cdxj_preserves_basename_when_output_dir_differs
    Dir.mktmpdir do |dir|
      input_dir = File.join(dir, "source")
      output_dir = File.join(dir, "out")
      FileUtils.mkdir_p(input_dir)
      input = File.join(input_dir, "sample.cdxj")
      File.write(input, sorted_cdxj)

      results = CDX::Repacker.repack_many([input], output_dir: output_dir, output_format: "cdxj", filters: ["status_200"])

      assert_equal [:written], results.map(&:status)
      assert File.file?(File.join(output_dir, "sample.cdxj"))
      assert_equal sorted_cdxj.lines[1..2].join, File.read(File.join(output_dir, "sample.cdxj"))
    end
  end

  def test_repack_many_cdxj_same_directory_uses_filtered_name
    Dir.mktmpdir do |dir|
      input = File.join(dir, "sample.cdxj")
      output = File.join(dir, "sample.filtered.cdxj")
      File.write(input, sorted_cdxj)

      results = CDX::Repacker.repack_many([input], output_dir: dir, output_format: "cdxj", filters: ["status_200"])

      assert_equal [:written], results.map(&:status)
      assert File.file?(output)
      assert_equal sorted_cdxj.lines[1..2].join, File.read(output)
      refute File.exist?(File.join(dir, CDX::Backends::RbCDX::Manifest::FILENAME))
      state = JSON.parse(File.read(File.join(dir, CDX::BatchRepacker::STATE_FILENAME)))
      assert_equal ["cdxj"], state.fetch("entries").map { |entry| entry.fetch("output_format") }
    end
  end

  def test_repack_many_rejects_output_colliding_with_another_input
    Dir.mktmpdir do |dir|
      input_dir = File.join(dir, "source")
      output_dir = File.join(dir, "out")
      FileUtils.mkdir_p([input_dir, output_dir])
      input = File.join(input_dir, "sample.cdxj")
      colliding_input = File.join(output_dir, "sample.cdxj")
      File.write(input, sorted_cdxj)
      File.write(colliding_input, sorted_cdxj)

      error = assert_raises(ArgumentError) do
        CDX::Repacker.repack_many([input, colliding_input], output_dir: output_dir, output_format: "cdxj")
      end

      assert_match(/planned output collides with input path/, error.message)
    end
  end

  def test_repack_many_cdxj_resume_skips_matching_output_from_state
    Dir.mktmpdir do |dir|
      input = File.join(dir, "sample.cdxj")
      File.write(input, sorted_cdxj)

      CDX::Repacker.repack_many([input], output_dir: dir, output_format: "cdxj", filters: ["status_200"])
      results = CDX::Repacker.repack_many([input], output_dir: dir, output_format: "cdxj", filters: ["status_200"], resume: true)

      assert_equal [:skipped], results.map(&:status)
    end
  end

  def test_repack_many_cdxj_rejects_source_changed_before_write_and_does_not_delete
    Dir.mktmpdir do |dir|
      input_dir = File.join(dir, "source")
      output_dir = File.join(dir, "out")
      FileUtils.mkdir_p(input_dir)
      input = File.join(input_dir, "sample.cdxj")
      File.write(input, sorted_cdxj)
      changed = false

      error = assert_raises(CDX::Error) do
        CDX::Repacker.repack_many(
          [input],
          output_dir: output_dir,
          output_format: "cdxj",
          delete_when_processed: true,
          progress: lambda do |event, **_payload|
            next unless event == :state_finish
            next if changed

            changed = true
            File.write(input, duplicate_urlkey_cdxj)
          end
        )
      end

      assert_match(/source changed before output was written/, error.message)
      assert File.exist?(input)
    end
  end

  def test_repack_many_cdxj_resume_ignores_same_directory_output
    Dir.mktmpdir do |dir|
      input = File.join(dir, "sample.cdxj")
      output = File.join(dir, "sample.filtered.cdxj")
      File.write(input, sorted_cdxj)

      CDX::Repacker.repack_many([dir], output_dir: dir, output_format: "cdxj", filters: ["status_200"], delete_when_processed: true)
      results = CDX::Repacker.repack_many([dir], output_dir: dir, output_format: "cdxj", filters: ["status_200"], delete_when_processed: true, resume: true)

      assert_equal [:skipped], results.map(&:status)
      refute File.exist?(input)
      assert File.file?(output)
    end
  end

  def test_repack_many_cdxj_resume_ignores_nested_output_dir
    Dir.mktmpdir do |dir|
      input_dir = File.join(dir, "indexes")
      source_dir = File.join(input_dir, "source")
      output_dir = File.join(input_dir, "filtered")
      FileUtils.mkdir_p(source_dir)
      input = File.join(source_dir, "sample.cdxj")
      output = File.join(output_dir, "sample.cdxj")
      File.write(input, sorted_cdxj)

      CDX::Repacker.repack_many([input_dir], output_dir: output_dir, output_format: "cdxj", filters: ["status_200"])
      results = CDX::Repacker.repack_many([input_dir], output_dir: output_dir, output_format: "cdxj", filters: ["status_200"], resume: true)

      assert_equal [:skipped], results.map(&:status)
      assert File.file?(input)
      assert File.file?(output)
    end
  end

  def test_repack_many_cdxj_delete_does_not_delete_on_parse_error
    Dir.mktmpdir do |dir|
      input = File.join(dir, "bad.cdxj")
      File.write(input, "com,bad)/ 20240101010101 {not-json}\n")

      assert_raises(CDX::Backends::RbCDX::Format::EncodeError) do
        CDX::Repacker.repack_many([input], output_dir: dir, output_format: "cdxj", delete_when_processed: true)
      end

      assert File.exist?(input)
      refute File.exist?(File.join(dir, "bad.filtered.cdxj"))
    end
  end

  def test_cli_repack_cdxj_allows_weird_output_filename
    Dir.mktmpdir do |dir|
      input = File.join(dir, "sample.cdxj")
      output = File.join(dir, "anything.rbcdx")
      File.write(input, sorted_cdxj)
      out = StringIO.new
      err = StringIO.new

      status = CDX::CLI.start(["repack", "--output-format", "cdxj", "--output", output, "--filter", "status_200", input], out: out, err: err)

      assert_equal 0, status
      assert_equal "#{output}\n", out.string
      assert_match(/processing \[1\/1\]/, err.string)
      assert_match(/written \[1\/1\]/, err.string)
      assert_match(/\Acom,example\)\/about 20240202020202 /, File.read(output))
    end
  end

  def test_cli_repack_cdxj_rejects_rbcdx_tuning_flags
    Dir.mktmpdir do |dir|
      input = File.join(dir, "sample.cdxj")
      output = File.join(dir, "sample.cdxj.out")
      File.write(input, sorted_cdxj)
      out = StringIO.new
      err = StringIO.new

      status = CDX::CLI.start(["repack", "--output-format", "cdxj", "--block-bytes", "100", "--output", output, input], out: out, err: err)

      assert_equal 1, status
      assert_empty out.string
      assert_match(/--block-bytes only applies/, err.string)
    end
  end

  private

  def with_manifest_build_tracking
    builds = []
    original_build = CDX::Backends::RbCDX::Manifest.method(:build)
    replacement_build = lambda do |paths, **options|
      builds << Array(paths).map(&:to_s)
      original_build.call(paths, **options)
    end

    with_singleton_replacement(CDX::Backends::RbCDX::Manifest, :build, replacement_build) { yield builds }
  end

  def write_cli_repack_log(path, inputs:, output_dir:, version: CDX::CLI::REPACK_LOG_VERSION, output_format: "rbcdx", filters: [], where: [], delete_when_processed: false, manifest: true)
    File.write(path, "#{JSON.pretty_generate({
      "format" => CDX::CLI::REPACK_LOG_FORMAT,
      "version" => version,
      "request" => {
        "inputs" => inputs,
        "options" => {
          "output_dir" => output_dir,
          "output_format" => output_format,
          "filters" => filters,
          "where" => where,
          "delete_when_processed" => delete_when_processed,
          "manifest" => manifest
        }
      }
    })}\n")
  end

  def with_singleton_replacement(object, method_name, replacement)
    original = object.method(method_name)
    replace_singleton_method(object, method_name, replacement)
    yield
  ensure
    replace_singleton_method(object, method_name, original) if original
  end

  def replace_singleton_method(object, method_name, callable)
    verbose = $VERBOSE
    $VERBOSE = nil
    object.define_singleton_method(method_name, callable)
  ensure
    $VERBOSE = verbose
  end

  def replace_instance_method(klass, method_name, callable)
    verbose = $VERBOSE
    $VERBOSE = nil
    klass.define_method(method_name, callable)
  ensure
    $VERBOSE = verbose
  end

  def gzip_write(path, content)
    Zlib::GzipWriter.open(path) { |gzip| gzip.write(content) }
  end

  def gzip_read(path)
    Zlib::GzipReader.open(path, &:read)
  end

  def corrupt_record_count(path)
    rewrite_header(path) { |header| header["record_count"] += 1 }
  end

  def rewrite_header(path)
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

  def sorted_cdxj
    <<~CDXJ
      com,example)/ 20240101010101 {"url":"http://example.com/","mime":"text/html","mime-detected":"text/html","status":"404","length":"10","offset":"5","filename":"crawl-data/CC-MAIN-2025-43/segments/123.45/warc/CC-MAIN-20250101000000-20250101030000-00001.warc.gz"}
      com,example)/about 20240202020202 {"url":"https://example.com/about","mime":"text/html","mime-detected":"text/html","status":"200","digest":"IFUIEFR56GZBO3ZK43VEKSLQ5QOFXDOI","length":"20","offset":"15","filename":"crawl-data/CC-MAIN-2025-43/segments/123.45/warc/CC-MAIN-20250101000000-20250101030000-00001.warc.gz","charset":"UTF-8","languages":"eng,spa"}
      com,example,blog)/post 20240303030303 {"url":"https://blog.example.com/post","mime":"text/html","status":"200","length":"30","offset":"35","filename":"crawl-data/CC-MAIN-2025-43/segments/123.45/warc/CC-MAIN-20250101000000-20250101030000-00002.warc.gz"}
    CDXJ
  end

  def duplicate_urlkey_cdxj
    <<~CDXJ
      com,example)/repeat 20240101010101 {"url":"https://example.com/repeat","mime":"text/html","status":"200","length":"10","offset":"1","filename":"crawl-data/CC-MAIN-2025-43/segments/123.45/warc/CC-MAIN-20250101000000-20250101030000-00001.warc.gz"}
      com,example)/repeat 20240202020202 {"url":"https://example.com/repeat","mime":"text/html","status":"200","length":"20","offset":"11","filename":"crawl-data/CC-MAIN-2025-43/segments/123.45/warc/CC-MAIN-20250101000000-20250101030000-00001.warc.gz"}
      com,example)/repeat 20240303030303 {"url":"https://example.com/repeat","mime":"text/html","status":"200","length":"30","offset":"31","filename":"crawl-data/CC-MAIN-2025-43/segments/123.45/warc/CC-MAIN-20250101000000-20250101030000-00001.warc.gz"}
    CDXJ
  end

  def collapse_repack_cdxj
    <<~CDXJ
      example,collapse)/a 20250101000000 {"url":"https://collapse.example/a","mime":"text/html","status":"200","length":"10","offset":"1","filename":"crawl-data/CC-MAIN-2025-43/segments/123.45/warc/CC-MAIN-20250101000000-20250101030000-00001.warc.gz"}
      example,collapse)/a 20250103000000 {"url":"https://collapse.example/a","mime":"text/html","status":"200","length":"10","offset":"2","filename":"crawl-data/CC-MAIN-2025-43/segments/123.45/warc/CC-MAIN-20250101000000-20250101030000-00001.warc.gz"}
      example,collapse)/b 20250102000000 {"url":"https://collapse.example/b","mime":"text/html","status":"200","length":"10","offset":"3","filename":"crawl-data/CC-MAIN-2025-43/segments/123.45/warc/CC-MAIN-20250101000000-20250101030000-00001.warc.gz"}
      example,collapse)/b 20250104000000 {"url":"https://collapse.example/b","mime":"text/html","status":"200","length":"10","offset":"4","filename":"crawl-data/CC-MAIN-2025-43/segments/123.45/warc/CC-MAIN-20250101000000-20250101030000-00001.warc.gz"}
    CDXJ
  end

  def collapse_batch_first_cdxj
    <<~CDXJ
      example,batch-collapse)/a 20250101000000 {"url":"https://batch-collapse.example/a","mime":"text/html","status":"200","length":"10","offset":"1","filename":"crawl-data/CC-MAIN-2025-43/segments/123.45/warc/CC-MAIN-20250101000000-20250101030000-00001.warc.gz"}
    CDXJ
  end

  def collapse_batch_second_cdxj
    <<~CDXJ
      example,batch-collapse)/a 20250105000000 {"url":"https://batch-collapse.example/a","mime":"text/html","status":"200","length":"10","offset":"3","filename":"crawl-data/CC-MAIN-2025-43/segments/123.45/warc/CC-MAIN-20250101000000-20250101030000-00002.warc.gz"}
      example,batch-collapse)/b 20250103000000 {"url":"https://batch-collapse.example/b","mime":"text/html","status":"200","length":"10","offset":"4","filename":"crawl-data/CC-MAIN-2025-43/segments/123.45/warc/CC-MAIN-20250101000000-20250101030000-00002.warc.gz"}
    CDXJ
  end

  def collapse_ungrouped_first_cdxj
    <<~CDXJ
      example,batch-collapse)/a 20250101000000 {"url":"https://batch-collapse.example/a","mime":"text/html","status":"200","length":"10","offset":"1","filename":"crawl-data/CC-MAIN-2025-43/segments/123.45/warc/CC-MAIN-20250101000000-20250101030000-00001.warc.gz"}
      example,batch-collapse)/b 20250102000000 {"url":"https://batch-collapse.example/b","mime":"text/html","status":"200","length":"10","offset":"2","filename":"crawl-data/CC-MAIN-2025-43/segments/123.45/warc/CC-MAIN-20250101000000-20250101030000-00001.warc.gz"}
    CDXJ
  end

  def collapse_ungrouped_second_cdxj
    <<~CDXJ
      example,batch-collapse)/a 20250105000000 {"url":"https://batch-collapse.example/a","mime":"text/html","status":"200","length":"10","offset":"3","filename":"crawl-data/CC-MAIN-2025-43/segments/123.45/warc/CC-MAIN-20250101000000-20250101030000-00002.warc.gz"}
      example,batch-collapse)/c 20250103000000 {"url":"https://batch-collapse.example/c","mime":"text/html","status":"200","length":"10","offset":"4","filename":"crawl-data/CC-MAIN-2025-43/segments/123.45/warc/CC-MAIN-20250101000000-20250101030000-00002.warc.gz"}
    CDXJ
  end

  def extractable_text_cdxj
    <<~CDXJ
      com,example)/ 20240101010101 {"url":"https://example.com/","mime":"text/html; charset=UTF-8","status":"200","length":"10","offset":"1","filename":"crawl-data/CC-MAIN-2025-43/segments/123.45/warc/CC-MAIN-20250101000000-20250101030000-00001.warc.gz"}
      com,example)/about.txt 20240101010102 {"url":"https://example.com/about.txt","mime":"text/plain","status":"200","length":"10","offset":"11","filename":"crawl-data/CC-MAIN-2025-43/segments/123.45/warc/CC-MAIN-20250101000000-20250101030000-00001.warc.gz"}
      com,example)/app.js 20240101010103 {"url":"https://example.com/app.js","mime":"application/javascript","status":"200","length":"10","offset":"21","filename":"crawl-data/CC-MAIN-2025-43/segments/123.45/warc/CC-MAIN-20250101000000-20250101030000-00001.warc.gz"}
      com,example)/feed.xml 20240101010104 {"url":"https://example.com/feed.xml","mime":"application/rss+xml","status":"200","length":"10","offset":"31","filename":"crawl-data/CC-MAIN-2025-43/segments/123.45/warc/CC-MAIN-20250101000000-20250101030000-00001.warc.gz"}
      com,example)/image.jpg 20240101010105 {"url":"https://example.com/image.jpg","mime":"image/jpeg","status":"200","length":"10","offset":"41","filename":"crawl-data/CC-MAIN-2025-43/segments/123.45/warc/CC-MAIN-20250101000000-20250101030000-00001.warc.gz"}
      com,example)/kml 20240101010105 {"url":"https://example.com/map.kml","mime":"application/vnd.google-earth.kml+xml","status":"200","length":"10","offset":"42","filename":"crawl-data/CC-MAIN-2025-43/segments/123.45/warc/CC-MAIN-20250101000000-20250101030000-00001.warc.gz"}
      com,example)/manifest.json 20240101010106 {"url":"https://example.com/manifest.json","mime":"text/plain","status":"200","length":"10","offset":"51","filename":"crawl-data/CC-MAIN-2025-43/segments/123.45/warc/CC-MAIN-20250101000000-20250101030000-00001.warc.gz"}
      com,example)/missing 20240101010107 {"url":"https://example.com/missing","mime":"text/html","status":"404","length":"10","offset":"61","filename":"crawl-data/CC-MAIN-2025-43/segments/123.45/warc/CC-MAIN-20250101000000-20250101030000-00001.warc.gz"}
      com,example)/octet-html 20240101010107 {"url":"https://example.com/octet-html","mime":"application/octet-stream","mime-detected":"text/html","status":"200","length":"10","offset":"62","filename":"crawl-data/CC-MAIN-2025-43/segments/123.45/warc/CC-MAIN-20250101000000-20250101030000-00001.warc.gz"}
      com,example)/playlist.xspf 20240101010107 {"url":"https://example.com/playlist.xspf","mime":"application/xspf+xml","status":"200","length":"10","offset":"63","filename":"crawl-data/CC-MAIN-2025-43/segments/123.45/warc/CC-MAIN-20250101000000-20250101030000-00001.warc.gz"}
      com,example)/post-sitemap.xml 20240101010107 {"url":"https://example.com/post-sitemap.xml","mime":"application/xml","status":"200","length":"10","offset":"64","filename":"crawl-data/CC-MAIN-2025-43/segments/123.45/warc/CC-MAIN-20250101000000-20250101030000-00001.warc.gz"}
      com,example)/readme.md 20240101010107 {"url":"https://example.com/README.md","mime":"text/markdown","status":"200","length":"10","offset":"65","filename":"crawl-data/CC-MAIN-2025-43/segments/123.45/warc/CC-MAIN-20250101000000-20250101030000-00001.warc.gz"}
      com,example)/robots.txt 20240101010108 {"url":"https://example.com/robots.txt","mime":"text/plain","status":"200","length":"10","offset":"71","filename":"crawl-data/CC-MAIN-2025-43/segments/123.45/robotstxt/CC-MAIN-20250101000000-20250101030000-00001.warc.gz"}
      com,example)/sitemap 20240101010109 {"url":"https://example.com/sitemap","mime":"text/plain","mime-detected":"application/xml","status":"200","length":"10","offset":"80","filename":"crawl-data/CC-MAIN-2025-43/segments/123.45/warc/CC-MAIN-20250101000000-20250101030000-00001.warc.gz"}
      com,example)/sitemap-guide 20240101010109 {"url":"https://example.com/sitemap-guide","mime":"text/html","status":"200","length":"10","offset":"80","filename":"crawl-data/CC-MAIN-2025-43/segments/123.45/warc/CC-MAIN-20250101000000-20250101030000-00001.warc.gz"}
      com,example)/sitemap.xml 20240101010109 {"url":"https://example.com/sitemap.xml","mime":"application/xml","status":"200","length":"10","offset":"81","filename":"crawl-data/CC-MAIN-2025-43/segments/123.45/warc/CC-MAIN-20250101000000-20250101030000-00001.warc.gz"}
      com,example)/svg.svg 20240101010110 {"url":"https://example.com/svg.svg","mime":"application/svg+xml","status":"200","length":"10","offset":"91","filename":"crawl-data/CC-MAIN-2025-43/segments/123.45/warc/CC-MAIN-20250101000000-20250101030000-00001.warc.gz"}
      com,example)/wp-sitemap-posts-post-1.xml 20240101010110 {"url":"https://example.com/wp-sitemap-posts-post-1.xml","mime":"application/xml","status":"200","length":"10","offset":"92","filename":"crawl-data/CC-MAIN-2025-43/segments/123.45/warc/CC-MAIN-20250101000000-20250101030000-00001.warc.gz"}
      org,example)/xhtml 20240101010111 {"url":"https://example.org/xhtml","mime":"application/xhtml+xml","status":"200","length":"10","offset":"101","filename":"crawl-data/CC-MAIN-2025-43/segments/123.45/warc/CC-MAIN-20250101000000-20250101030000-00001.warc.gz"}
    CDXJ
  end
end

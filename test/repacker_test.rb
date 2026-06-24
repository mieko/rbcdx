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

  def test_repack_reads_gzip_input
    Dir.mktmpdir do |dir|
      input = File.join(dir, "cdx-00000.gz")
      output = File.join(dir, "cdx-00000.rbcdx")
      Zlib::GzipWriter.open(input) { |gzip| gzip.write(sorted_cdxj) }

      CDX::Backends::Rbcdx.write(input, output, block_bytes: 180)

      assert_equal ["https://example.com/about"], CDX::Index.open(output).captures("example.com/about").map(&:url)
    end
  end

  def test_repack_spools_hot_and_cold_sections_to_format_writer
    writer_sections = []
    original_write_file = CDX::RbcdxFormat.method(:write_file)
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

    with_singleton_replacement(CDX::RbcdxFormat, :write_file, replacement_write_file) do
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
          "about" => ->(record) { record["url"].to_s.end_with?("/about") }
        }
      )

      assert_equal 1, result.record_count
      assert_equal ["https://example.com/about"], CDX::Index.open(output).map(&:url)
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
          "ok" => ->(record) { record["status"].to_s == "200" },
          "about" => ->(record) { record["url"].to_s.end_with?("/about") }
        }
      )

      assert_equal 1, result.record_count
      assert_equal ["https://blog.example.com/post"], CDX::Index.open(output).map(&:url)
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
        filters: [->(record) { record["url"].to_s.start_with?("https://example.com/") }]
      )

      assert_equal ["https://example.com/"], CDX::Index.open(output).map(&:url)
    end
  end

  def test_repack_rejects_unsorted_input
    Dir.mktmpdir do |dir|
      input = File.join(dir, "unsorted.cdxj")
      output = File.join(dir, "unsorted.rbcdx")
      File.write(input, sorted_cdxj.lines.reverse.join)

      error = assert_raises(CDX::RbcdxFormat::EncodeError) do
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

      error = assert_raises(CDX::RbcdxFormat::EncodeError) do
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

      error = assert_raises(CDX::RbcdxFormat::EncodeError) do
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

      error = assert_raises(CDX::RbcdxFormat::EncodeError) do
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
      assert_empty err.string
      assert_equal ["https://example.com/about"], CDX::Index.open(output).captures("example.com/about").map(&:url)
    end
  end

  def test_cli_repack_filter
    Dir.mktmpdir do |dir|
      input = File.join(dir, "sample.cdxj")
      output = File.join(dir, "sample.rbcdx")
      File.write(input, sorted_cdxj)
      out = StringIO.new
      err = StringIO.new

      status = CDX::CLI.start(["repack", "--output", output, "--filter", "status-200", input], out: out, err: err)

      assert_equal 0, status
      assert_empty err.string
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

      status = CDX::CLI.start(["repack", "--output", output, "--filter", "+status-200,+html,-warc", input], out: out, err: err)

      assert_equal 0, status
      assert_empty err.string
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

  def test_repack_removes_temp_output_after_failure
    Dir.mktmpdir do |dir|
      input = File.join(dir, "bad.cdxj")
      output = File.join(dir, "bad.rbcdx")
      File.write(input, sorted_cdxj.sub("IFUIEFR56GZBO3ZK43VEKSLQ5QOFXDOI", "IFUIEFR56GZBO3ZK43VEKSLQ5QOFXDOI="))

      assert_raises(CDX::RbcdxFormat::EncodeError) do
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
        progress: ->(event, **payload) { events << [event, payload.fetch(:entry).fetch("output_path")] }
      )

      assert_equal [:written, :written], results.map(&:status)
      assert File.file?(File.join(output_dir, "cdx-00000.rbcdx"))
      assert File.file?(File.join(output_dir, "cdx-00001.rbcdx"))
      assert File.file?(File.join(output_dir, CDX::BatchRepacker::STATE_FILENAME))
      assert File.file?(File.join(output_dir, CDX::RbcdxManifest::FILENAME))
      assert_equal ["https://example.com/about"], CDX::Index.open(File.join(output_dir, "cdx-00000.rbcdx")).captures("example.com/about").map(&:url)
      assert_includes events.map(&:first), :start
      assert_includes events.map(&:first), :finish
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
      manifest = JSON.parse(File.read(File.join(output_dir, CDX::RbcdxManifest::FILENAME)))
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
        progress: ->(event, **payload) { events << [event, payload.fetch(:entry).fetch("output_path")] }
      )

      assert_equal [:planned], results.map(&:status)
      refute Dir.exist?(output_dir)
      assert_equal [[:planned, File.join(output_dir, "sample.rbcdx")]], events
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

  def test_repack_many_rejects_same_input_and_output_directory
    Dir.mktmpdir do |dir|
      input = File.join(dir, "sample.cdxj")
      File.write(input, sorted_cdxj)

      error = assert_raises(ArgumentError) do
        CDX::Repacker.repack_many([input], output_dir: dir)
      end

      assert_match(/output directory must be separate/, error.message)
    end
  end

  def test_repack_many_rejects_output_directory_inside_input_directory
    Dir.mktmpdir do |dir|
      input_dir = File.join(dir, "cdx")
      output_dir = File.join(input_dir, "rbcdx")
      FileUtils.mkdir_p(input_dir)
      File.write(File.join(input_dir, "sample.cdxj"), sorted_cdxj)

      error = assert_raises(ArgumentError) do
        CDX::Repacker.repack_many([input_dir], output_dir: output_dir)
      end

      assert_match(/output directory must be separate/, error.message)
    end
  end

  def test_repack_many_rejects_glob_output_directory_inside_input_tree
    Dir.mktmpdir do |dir|
      input_dir = File.join(dir, "cdx")
      output_dir = File.join(input_dir, "rbcdx")
      FileUtils.mkdir_p(input_dir)
      File.write(File.join(input_dir, "sample.cdxj"), sorted_cdxj)

      error = assert_raises(ArgumentError) do
        CDX::Repacker.repack_many([File.join(input_dir, "*.cdxj")], output_dir: output_dir)
      end

      assert_match(/output directory must be separate/, error.message)
    end
  end

  def test_repack_many_rejects_recursive_glob_output_directory_inside_input_tree
    Dir.mktmpdir do |dir|
      input_dir = File.join(dir, "cdx")
      shard_dir = File.join(input_dir, "shards")
      output_dir = File.join(input_dir, "rbcdx")
      FileUtils.mkdir_p(shard_dir)
      File.write(File.join(shard_dir, "sample.cdxj"), sorted_cdxj)

      error = assert_raises(ArgumentError) do
        CDX::Repacker.repack_many([File.join(input_dir, "**", "*.cdxj")], output_dir: output_dir)
      end

      assert_match(/output directory must be separate/, error.message)
    end
  end

  def test_repack_many_rejects_symlinked_output_directory_inside_input_tree
    Dir.mktmpdir do |dir|
      input_dir = File.join(dir, "cdx")
      output_dir = File.join(dir, "rbcdx-link")
      input = File.join(input_dir, "sample.cdxj")
      FileUtils.mkdir_p(input_dir)
      File.write(input, sorted_cdxj)
      File.symlink(input_dir, output_dir)

      error = assert_raises(ArgumentError) do
        CDX::Repacker.repack_many([input_dir], output_dir: output_dir, delete_when_processed: true)
      end

      assert_match(/output directory must be separate/, error.message)
      assert File.exist?(input)
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
      refute File.exist?(File.join(output_dir, CDX::RbcdxManifest::FILENAME))
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
        filters: [->(record) { record["status"] == "200" }],
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
      assert_match(/planned \[1\/1\].*sample\.cdxj -> .*sample\.rbcdx/, out.string)
      assert_empty err.string
      refute Dir.exist?(output_dir)
    end
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
      assert_match(/written \[1\/1\]/, err.string)
      assert_equal ["https://example.com/about", "https://blog.example.com/post"], CDX::Index.open(File.join(output_dir, "sample.rbcdx")).map(&:url)
    end
  end

  private

  def with_manifest_build_tracking
    builds = []
    original_build = CDX::RbcdxManifest.method(:build)
    replacement_build = lambda do |paths, **options|
      builds << Array(paths).map(&:to_s)
      original_build.call(paths, **options)
    end

    with_singleton_replacement(CDX::RbcdxManifest, :build, replacement_build) { yield builds }
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

  def gzip_write(path, content)
    Zlib::GzipWriter.open(path) { |gzip| gzip.write(content) }
  end

  def corrupt_record_count(path)
    rewrite_header(path) { |header| header["record_count"] += 1 }
  end

  def rewrite_header(path)
    File.open(path, "r+b") do |file|
      magic = file.read(CDX::RbcdxFormat::MAGIC.bytesize)
      raise "invalid test rbcdx magic" unless magic == CDX::RbcdxFormat::MAGIC

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
end

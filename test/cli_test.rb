require_relative "test_helper"

class CliTest < Minitest::Test
  def test_captures_outputs_jsonl
    out = StringIO.new
    status = CDX::CLI.start(
      ["captures", "--index", fixture_path("sample.cdxj"), "--filter", "=status:200", "example.com/*"],
      out: out,
      err: StringIO.new
    )

    assert_equal 0, status
    lines = out.string.lines.map { |line| JSON.parse(line) }
    assert_equal ["https://example.com/about"], lines.map { |line| line["url"] }
  end

  def test_captures_accepts_named_filter_expression
    out = StringIO.new
    status = CDX::CLI.start(
      ["captures", "--index", fixture_path("sample.cdxj"), "--filter", "html", "commoncrawl.org/*"],
      out: out,
      err: StringIO.new
    )

    assert_equal 0, status
    lines = out.string.lines.map { |line| JSON.parse(line) }
    assert_equal [
      "https://commoncrawl.org/",
      "https://www.commoncrawl.org/blog/",
      "https://www.commoncrawl.org/get-started"
    ], lines.map { |line| line["url"] }
  end

  def test_captures_can_mix_named_and_field_filter_flags
    out = StringIO.new
    status = CDX::CLI.start(
      ["captures", "--index", fixture_path("sample.cdxj"), "--filter", "html", "--filter", "~url:get-started", "commoncrawl.org/*"],
      out: out,
      err: StringIO.new
    )

    assert_equal 0, status
    lines = out.string.lines.map { |line| JSON.parse(line) }
    assert_equal ["https://www.commoncrawl.org/get-started"], lines.map { |line| line["url"] }
  end

  def test_captures_splits_named_first_mixed_filter_expression
    out = StringIO.new
    status = CDX::CLI.start(
      ["captures", "--index", fixture_path("sample.cdxj"), "--filter", "html,~url:get-started", "commoncrawl.org/*"],
      out: out,
      err: StringIO.new
    )

    assert_equal 0, status
    lines = out.string.lines.map { |line| JSON.parse(line) }
    assert_equal ["https://www.commoncrawl.org/get-started"], lines.map { |line| line["url"] }
  end

  def test_captures_rejects_unknown_named_filter
    err = StringIO.new
    status = CDX::CLI.start(
      ["captures", "--index", fixture_path("sample.cdxj"), "--filter", "extractable-text", "commoncrawl.org/*"],
      out: StringIO.new,
      err: err
    )

    assert_equal 1, status
    assert_match(/unknown query filter "extractable-text"/, err.string)
    assert_match(/extractable_text/, err.string)
  end

  def test_count_outputs_count
    out = StringIO.new
    status = CDX::CLI.start(
      ["count", "--index", fixture_path("sample.cdxj"), "commoncrawl.org/*"],
      out: out,
      err: StringIO.new
    )

    assert_equal 0, status
    assert_equal "4\n", out.string
  end

  def test_match_option
    out = StringIO.new
    status = CDX::CLI.start(
      ["count", "--index", fixture_path("sample.cdxj"), "--match", "domain", "commoncrawl.org"],
      out: out,
      err: StringIO.new
    )

    assert_equal 0, status
    assert_equal "5\n", out.string
  end

  def test_invalid_match_option_returns_error
    err = StringIO.new
    status = CDX::CLI.start(
      ["count", "--index", fixture_path("sample.cdxj"), "--match", "weird", "commoncrawl.org"],
      out: StringIO.new,
      err: err
    )

    assert_equal 1, status
    assert_match(/unsupported match/, err.string)
  end

  def test_invalid_sort_option_returns_error
    err = StringIO.new
    status = CDX::CLI.start(
      ["count", "--index", fixture_path("sample.cdxj"), "--sort", "sideways", "commoncrawl.org/*"],
      out: StringIO.new,
      err: err
    )

    assert_equal 1, status
    assert_match(/unsupported sort/, err.string)
  end

  def test_options_after_positional_are_rejected
    err = StringIO.new
    status = CDX::CLI.start(
      ["count", "commoncrawl.org/*", "--index", fixture_path("sample.cdxj")],
      out: StringIO.new,
      err: err
    )

    assert_equal 1, status
    assert_match(/options must appear before the URL pattern/, err.string)
  end

  def test_invalid_option_returns_error
    err = StringIO.new
    status = CDX::CLI.start(
      ["count", "--wat", fixture_path("sample.cdxj"), "commoncrawl.org/*"],
      out: StringIO.new,
      err: err
    )

    assert_equal 1, status
    assert_match(/invalid option/, err.string)
  end

  def test_subcommand_help_uses_configured_output
    out = StringIO.new
    err = StringIO.new
    status = CDX::CLI.start(["captures", "--help"], out: out, err: err)

    assert_equal 0, status
    assert_match(/Usage:/, out.string)
    assert_match(/--index PATH/, out.string)
    assert_empty err.string
  end

  def test_data_list_outputs_crawls
    out = StringIO.new
    status = CDX::CLI.start(["data", "list"], out: out, err: StringIO.new, data_client: FakeDataClient.new)

    assert_equal 0, status
    assert_match(/CC-MAIN-2026-25/, out.string)
    assert_match(/June 2026 Index/, out.string)
  end

  def test_data_list_outputs_jsonl
    out = StringIO.new
    status = CDX::CLI.start(
      ["data", "list", "--format", "jsonl", "--limit", "1"],
      out: out,
      err: StringIO.new,
      data_client: FakeDataClient.new
    )

    assert_equal 0, status
    lines = out.string.lines.map { |line| JSON.parse(line) }
    assert_equal ["CC-MAIN-2026-25"], lines.map { |line| line["id"] }
  end

  def test_data_download_defaults_to_latest_and_all_files
    client = FakeDataClient.new
    out = StringIO.new
    err = StringIO.new
    status = CDX::CLI.start(
      ["data", "download", "--output", "indexes"],
      out: out,
      err: err,
      data_client: client
    )

    assert_equal 0, status
    assert_equal [{crawl_id: "CC-MAIN-2026-25", output_dir: "indexes", limit: nil, force: false, zipnum: true}], client.download_requests
    assert_match(%r{indexes/CC-MAIN-2026-25/cdx-00000.gz}, out.string)
    assert_match(%r{indexes/CC-MAIN-2026-25/cluster.idx}, out.string)
    assert_match(/downloading \[1\/3\] cdx-00000\.gz/, err.string)
    assert_match(/progress \[1\/3\] cdx-00000\.gz 64\.0 MiB \/ 128\.0 MiB \(50%\)/, err.string)
    assert_match(/downloaded/, err.string)
  end

  def test_data_download_accepts_crawl_override_limit_and_force
    client = FakeDataClient.new
    status = CDX::CLI.start(
      ["data", "download", "--crawl", "CC-MAIN-2026-21", "--output", "indexes", "--limit", "1", "--force"],
      out: StringIO.new,
      err: StringIO.new,
      data_client: client
    )

    assert_equal 0, status
    assert_equal [{crawl_id: "CC-MAIN-2026-21", output_dir: "indexes", limit: 1, force: true, zipnum: true}], client.download_requests
  end

  def test_data_download_can_skip_zipnum_lookup
    client = FakeDataClient.new
    status = CDX::CLI.start(
      ["data", "download", "--output", "indexes", "--no-zipnum"],
      out: StringIO.new,
      err: StringIO.new,
      data_client: client
    )

    assert_equal 0, status
    assert_equal [{crawl_id: "CC-MAIN-2026-25", output_dir: "indexes", limit: nil, force: false, zipnum: false}], client.download_requests
  end

  def test_data_download_dry_run_does_not_require_output
    client = FakeDataClient.new
    out = StringIO.new
    status = CDX::CLI.start(
      ["data", "download", "--crawl", "CC-MAIN-2026-21", "--limit", "1", "--dry-run"],
      out: out,
      err: StringIO.new,
      data_client: client
    )

    assert_equal 0, status
    assert_empty client.download_requests
    assert_equal [{crawl_id: "CC-MAIN-2026-21", limit: 1, zipnum: true}], client.index_requests
    assert_match(%r{https://data.commoncrawl.org/.*/cdx-00000.gz}, out.string)
    assert_match(%r{https://data.commoncrawl.org/.*/cluster.idx}, out.string)
  end

  def test_data_download_dry_run_with_output_does_not_create_output_directory
    Dir.mktmpdir do |dir|
      client = FakeDataClient.new
      out = StringIO.new
      output_dir = File.join(dir, "indexes")
      status = CDX::CLI.start(
        ["data", "download", "--output", output_dir, "--dry-run"],
        out: out,
        err: StringIO.new,
        data_client: client
      )

      assert_equal 0, status
      refute Dir.exist?(output_dir)
      assert_empty client.download_requests
      assert_match(%r{https://data.commoncrawl.org/.*/cdx-00000.gz -> #{Regexp.escape(output_dir)}}, out.string)
    end
  end

  def test_data_download_requires_output_for_real_download
    err = StringIO.new
    status = CDX::CLI.start(
      ["data", "download"],
      out: StringIO.new,
      err: err,
      data_client: FakeDataClient.new
    )

    assert_equal 1, status
    assert_match(/provide --output DIR/, err.string)
  end

  def test_data_download_rejects_crawl_and_latest_together
    err = StringIO.new
    status = CDX::CLI.start(
      ["data", "download", "--crawl", "CC-MAIN-2026-25", "--latest", "--output", "indexes"],
      out: StringIO.new,
      err: err,
      data_client: FakeDataClient.new
    )

    assert_equal 1, status
    assert_match(/choose --crawl or --latest/, err.string)
  end

  def test_data_help_uses_configured_output
    out = StringIO.new
    err = StringIO.new
    status = CDX::CLI.start(["data", "--help"], out: out, err: err, data_client: FakeDataClient.new)

    assert_equal 0, status
    assert_match(/rbcdx data list/, out.string)
    assert_match(/Commands:/, out.string)
    assert_match(/download  Download Common Crawl index files/, out.string)
    assert_empty err.string
  end

  def test_data_subcommand_help_uses_configured_output
    out = StringIO.new
    err = StringIO.new
    status = CDX::CLI.start(["data", "download", "--help"], out: out, err: err, data_client: FakeDataClient.new)

    assert_equal 0, status
    assert_match(/--output DIR/, out.string)
    assert_empty err.string
  end

  def test_data_list_help_uses_configured_output
    out = StringIO.new
    err = StringIO.new
    status = CDX::CLI.start(["data", "list", "--help"], out: out, err: err, data_client: FakeDataClient.new)

    assert_equal 0, status
    assert_match(/--format text\|jsonl/, out.string)
    assert_empty err.string
  end

  class FakeDataClient
    attr_reader :download_requests, :index_requests

    def initialize
      @download_requests = []
      @index_requests = []
    end

    def crawls
      [
        CDX::CommonCrawlData::Crawl.new(
          "CC-MAIN-2026-25",
          "June 2026 Index",
          "2026-06-05T21:48:11",
          "2026-06-18T19:32:05"
        ),
        CDX::CommonCrawlData::Crawl.new(
          "CC-MAIN-2026-21",
          "May 2026 Index",
          "2026-05-01T00:00:00",
          "2026-05-14T00:00:00"
        )
      ]
    end

    def latest_crawl
      crawls.first
    end

    def index_files(crawl_id, limit: nil, zipnum: true)
      @index_requests << {crawl_id: crawl_id, limit: limit, zipnum: zipnum}
      files(crawl_id, limit: limit, zipnum: zipnum)
    end

    def download_indexes(crawl_id:, output_dir:, limit: nil, force: nil, zipnum: true, progress: nil)
      @download_requests << {crawl_id: crawl_id, output_dir: output_dir, limit: limit, force: force, zipnum: zipnum}
      files = files(crawl_id, limit: limit, zipnum: zipnum)
      files.map.with_index(1) do |file, index|
        destination = file.destination(output_dir)
        progress&.call(:start, file: file, destination: destination, index: index, total: files.length)
        progress&.call(
          :progress,
          file: file,
          destination: destination,
          index: index,
          total: files.length,
          downloaded_bytes: 64 * 1024 * 1024,
          total_bytes: 128 * 1024 * 1024
        )
        progress&.call(:finish, file: file, destination: destination, index: index, total: files.length)
        CDX::CommonCrawlData::DownloadResult.new(
          file,
          destination,
          :downloaded
        )
      end
    end

    private

    def files(crawl_id, limit: nil, zipnum: true)
      files = %w[cdx-00000.gz cdx-00001.gz].map do |filename|
        path = "cc-index/collections/#{crawl_id}/indexes/#{filename}"
        CDX::CommonCrawlData::IndexFile.new(
          crawl_id,
          path,
          "https://data.commoncrawl.org/#{path}"
        )
      end
      files = files.first(limit) if limit
      return files unless zipnum

      path = "cc-index/collections/#{crawl_id}/indexes/cluster.idx"
      files + [CDX::CommonCrawlData::IndexFile.new(crawl_id, path, "https://data.commoncrawl.org/#{path}")]
    end
  end
end

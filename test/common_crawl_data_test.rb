require_relative "test_helper"

class CommonCrawlDataTest < Minitest::Test
  CRAWL_ID = "CC-MAIN-2026-25"

  def setup
    @downloads = []
    @client = CDX::CommonCrawlData.new(
      fetcher: ->(url) { fetches.fetch(url) },
      downloader: ->(url, destination) do
        @downloads << [url, destination]
        File.write(destination, "index")
      end
    )
  end

  def test_crawls_parse_collinfo
    crawls = @client.crawls

    assert_equal ["CC-MAIN-2026-25", "CC-MAIN-2026-21"], crawls.map(&:id)
    assert_equal "June 2026 Index", crawls.first.name
    assert_equal "2026-06-05T21:48:11", crawls.first.from
  end

  def test_latest_crawl_uses_first_collinfo_entry
    assert_equal "CC-MAIN-2026-25", @client.latest_crawl.id
  end

  def test_index_files_parse_gzipped_path_list
    files = @client.index_files(CRAWL_ID)

    assert_equal %w[cdx-00000.gz cdx-00001.gz cdx-00002.gz cluster.idx], files.map(&:filename)
    assert_equal "https://data.commoncrawl.org/#{files.first.path}", files.first.url
  end

  def test_index_files_support_limit
    files = @client.index_files(CRAWL_ID, limit: 2)

    assert_equal %w[cdx-00000.gz cdx-00001.gz cluster.idx], files.map(&:filename)
  end

  def test_index_files_can_skip_zipnum_lookup
    files = @client.index_files(CRAWL_ID, limit: 2, zipnum: false)

    assert_equal %w[cdx-00000.gz cdx-00001.gz], files.map(&:filename)
  end

  def test_index_files_limit_zero_returns_no_files
    assert_empty @client.index_files(CRAWL_ID, limit: 0)
  end

  def test_download_indexes_skips_existing_files_unless_forced
    Dir.mktmpdir do |dir|
      existing = File.join(dir, CRAWL_ID, "cdx-00000.gz")
      FileUtils.mkdir_p(File.dirname(existing))
      File.write(existing, "old")

      results = @client.download_indexes(crawl_id: CRAWL_ID, output_dir: dir, limit: 2)

      assert_equal [:skipped, :downloaded, :downloaded], results.map(&:status)
      assert_equal 2, @downloads.length
      assert_equal "old", File.read(existing)

      forced = @client.download_indexes(crawl_id: CRAWL_ID, output_dir: dir, limit: 1, force: true)

      assert_equal [:downloaded, :downloaded], forced.map(&:status)
      assert_equal "index", File.read(existing)
    end
  end

  def test_download_indexes_does_not_leave_partial_file_after_failure
    Dir.mktmpdir do |dir|
      client = client_with_downloader do |_url, destination|
        File.write(destination, "partial")
        raise IOError, "stream ended early"
      end
      destination = File.join(dir, CRAWL_ID, "cdx-00000.gz")

      error = assert_raises(CDX::Error) do
        client.download_indexes(crawl_id: CRAWL_ID, output_dir: dir, limit: 1)
      end

      assert_match(/stream ended early/, error.message)
      refute File.exist?(destination)
      assert_empty Dir.children(File.dirname(destination))
    end
  end

  def test_download_indexes_preserves_existing_file_when_forced_download_fails
    Dir.mktmpdir do |dir|
      existing = File.join(dir, CRAWL_ID, "cdx-00000.gz")
      FileUtils.mkdir_p(File.dirname(existing))
      File.write(existing, "complete")
      client = client_with_downloader do |_url, destination|
        File.write(destination, "partial")
        raise IOError, "stream ended early"
      end

      assert_raises(CDX::Error) do
        client.download_indexes(crawl_id: CRAWL_ID, output_dir: dir, limit: 1, force: true)
      end

      assert_equal "complete", File.read(existing)
      assert_equal ["cdx-00000.gz"], Dir.children(File.dirname(existing))
    end
  end

  def test_download_indexes_emits_progress_events
    Dir.mktmpdir do |dir|
      existing = File.join(dir, CRAWL_ID, "cdx-00000.gz")
      FileUtils.mkdir_p(File.dirname(existing))
      File.write(existing, "old")
      events = []
      client = client_with_downloader do |_url, destination, progress: nil|
        progress&.call(downloaded_bytes: 0, total_bytes: 128)
        progress&.call(downloaded_bytes: 128, total_bytes: 128)
        File.write(destination, "index")
      end

      client.download_indexes(
        crawl_id: CRAWL_ID,
        output_dir: dir,
        limit: 2,
        progress: ->(event, **payload) { events << [event, payload[:file].filename, payload[:downloaded_bytes], payload[:total_bytes]] }
      )

      assert_equal [
        [:skip, "cdx-00000.gz", nil, nil],
        [:start, "cdx-00001.gz", nil, nil],
        [:progress, "cdx-00001.gz", 0, 128],
        [:progress, "cdx-00001.gz", 128, 128],
        [:finish, "cdx-00001.gz", nil, nil],
        [:start, "cluster.idx", nil, nil],
        [:progress, "cluster.idx", 0, 128],
        [:progress, "cluster.idx", 128, 128],
        [:finish, "cluster.idx", nil, nil]
      ], events
    end
  end

  def test_download_indexes_does_not_pass_progress_to_unrelated_keyword_downloader
    Dir.mktmpdir do |dir|
      calls = []
      client = client_with_downloader do |url, destination, retries: 3|
        calls << [url, destination, retries]
        File.write(destination, "index")
      end

      client.download_indexes(crawl_id: CRAWL_ID, output_dir: dir, limit: 1, zipnum: false)

      assert_equal 1, calls.length
      assert_equal 3, calls.first.last
    end
  end

  def test_download_indexes_passes_progress_to_callable_downloader_object
    Dir.mktmpdir do |dir|
      downloader = ProgressDownloader.new
      client = CDX::CommonCrawlData.new(
        fetcher: ->(url) { fetches.fetch(url) },
        downloader: downloader
      )
      events = []

      client.download_indexes(
        crawl_id: CRAWL_ID,
        output_dir: dir,
        limit: 1,
        zipnum: false,
        progress: ->(event, **payload) { events << [event, payload[:downloaded_bytes], payload[:total_bytes]] }
      )

      assert_equal [[0, 10], [10, 10]], downloader.progress_events
      assert_includes events, [:progress, 10, 10]
    end
  end

  class ProgressDownloader
    attr_reader :progress_events

    def initialize
      @progress_events = []
    end

    def call(_url, destination, progress: nil)
      if progress
        progress.call(downloaded_bytes: 0, total_bytes: 10)
        @progress_events << [0, 10]
        progress.call(downloaded_bytes: 10, total_bytes: 10)
        @progress_events << [10, 10]
      end
      File.write(destination, "index")
    end
  end

  private

  def client_with_downloader(&downloader)
    CDX::CommonCrawlData.new(
      fetcher: ->(url) { fetches.fetch(url) },
      downloader: downloader
    )
  end

  def fetches
    @fetches ||= {
      CDX::CommonCrawlData::CRAWL_LIST_URL => File.read(fixture_path("collinfo.json")),
      @client.index_paths_url(CRAWL_ID) => gzip(File.read(fixture_path("cc-index.paths")))
    }
  end

  def gzip(text)
    output = StringIO.new
    Zlib::GzipWriter.wrap(output) { |gzip| gzip.write(text) }
    output.string
  end
end

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

    assert_equal %w[cdx-00000.gz cdx-00001.gz cdx-00002.gz], files.map(&:filename)
    assert_equal "https://data.commoncrawl.org/#{files.first.path}", files.first.url
  end

  def test_index_files_support_limit
    files = @client.index_files(CRAWL_ID, limit: 2)

    assert_equal %w[cdx-00000.gz cdx-00001.gz], files.map(&:filename)
  end

  def test_download_indexes_skips_existing_files_unless_forced
    Dir.mktmpdir do |dir|
      existing = File.join(dir, CRAWL_ID, "cdx-00000.gz")
      FileUtils.mkdir_p(File.dirname(existing))
      File.write(existing, "old")

      results = @client.download_indexes(crawl_id: CRAWL_ID, output_dir: dir, limit: 2)

      assert_equal [:skipped, :downloaded], results.map(&:status)
      assert_equal 1, @downloads.length
      assert_equal "old", File.read(existing)

      forced = @client.download_indexes(crawl_id: CRAWL_ID, output_dir: dir, limit: 1, force: true)

      assert_equal [:downloaded], forced.map(&:status)
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

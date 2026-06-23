require_relative "test_helper"

class HTTPTest < Minitest::Test
  def setup
    @index = CDX::Index.open(fixture_path("sample.cdxj"))
  end

  def test_requests_return_http_request_objects
    archive = CDX::HTTP::RemoteArchive.new(@index)
    request = archive.requests("commoncrawl.org/get-started").first

    assert_instance_of CDX::HTTP::Request, request
    assert_instance_of URI::HTTPS, request.uri
    assert_instance_of CDX::Capture, request.capture
    assert_equal "https://data.commoncrawl.org/crawl-data/CC-MAIN-2025-43/get-started.warc.gz", request.url
    assert_equal "https://data.commoncrawl.org", request.origin
    assert_equal "https", request.scheme
    assert_equal "data.commoncrawl.org", request.host
    assert_equal 443, request.port
    assert_equal "/crawl-data/CC-MAIN-2025-43/get-started.warc.gz", request.path
    assert_nil request.query
    assert_equal request.path, request.request_uri
    assert request.https?
    assert_equal "GET", request.http_method
    assert_equal 686_242_195, request.offset
    assert_equal 12_675, request.length
    assert_equal 686_242_195..686_254_869, request.range
    assert_equal "bytes=686242195-686254869", request.range_header_value
    assert_equal({"Range" => "bytes=686242195-686254869"}, request.headers)
  end

  def test_requests_support_block_iteration_and_return_archive
    archive = CDX::HTTP::RemoteArchive.new(@index)
    urls = []

    returned = archive.requests("commoncrawl.org/*", limit: 2) do |request|
      urls << request.url
    end

    assert_same archive, returned
    assert_equal 2, urls.length
    assert urls.all? { |url| url.start_with?("https://data.commoncrawl.org/") }
  end

  def test_explicit_base_url_preserves_path_prefix
    archive = CDX::HTTP::RemoteArchive.new(@index, base_url: "http://archive.example:8080/mirror/")
    request = archive.requests("commoncrawl.org/").first

    assert_instance_of URI::HTTP, request.uri
    assert_equal "http", request.scheme
    assert_equal "archive.example", request.host
    assert_equal 8080, request.port
    assert_equal "http://archive.example:8080", request.origin
    assert_equal "/mirror/crawl-data/CC-MAIN-2025-43/root.warc.gz", request.path
    assert_equal request.path, request.request_uri
    assert_equal "http://archive.example:8080/mirror/crawl-data/CC-MAIN-2025-43/root.warc.gz", request.url
    refute request.https?
  end

  def test_base_url_validation
    assert_raises(ArgumentError) { CDX::HTTP::RemoteArchive.new(@index, base_url: "/archive") }
    assert_raises(ArgumentError) { CDX::HTTP::RemoteArchive.new(@index, base_url: "ftp://example.com") }
    assert_raises(ArgumentError) { CDX::HTTP::RemoteArchive.new(@index, base_url: "https://example.com/archive?token=1") }
    assert_raises(ArgumentError) { CDX::HTTP::RemoteArchive.new(@index, base_url: "https://example.com/archive#top") }
  end

  def test_common_crawl_base_url_can_be_inferred_from_index_paths
    Dir.mktmpdir do |dir|
      index_dir = File.join(dir, "cc-index", "collections", "CC-MAIN-2026-25", "indexes")
      FileUtils.mkdir_p(index_dir)
      path = File.join(index_dir, "cdx-00000.gz")
      Zlib::GzipWriter.open(path) do |gzip|
        gzip.write "com,example)/ 20260101000000 {\"url\":\"https://example.com/\",\"status\":\"200\",\"length\":\"10\",\"offset\":\"5\",\"filename\":\"custom/example.warc.gz\"}\n"
      end

      index = CDX::Index.open(path)
      request = CDX::HTTP::RemoteArchive.new(index).requests("example.com/").first

      assert_equal "https://data.commoncrawl.org/custom/example.warc.gz", request.url
    end
  end

  def test_unknown_archive_requires_base_url
    Dir.mktmpdir do |dir|
      path = File.join(dir, "local.cdxj")
      File.write(path, "com,example)/ 20260101000000 {\"url\":\"https://example.com/\",\"status\":\"200\",\"length\":\"10\",\"offset\":\"5\",\"filename\":\"custom/example.warc.gz\"}\n")
      archive = CDX::HTTP::RemoteArchive.new(CDX::Index.open(path))

      error = assert_raises(ArgumentError) { archive.requests("example.com/").first }
      assert_match(/base_url is required/, error.message)
    end
  end

  def test_fields_are_rejected
    archive = CDX::HTTP::RemoteArchive.new(@index)

    error = assert_raises(ArgumentError) do
      archive.requests("commoncrawl.org/*", fields: [])
    end

    assert_match(/fields is not supported/, error.message)
  end

  def test_missing_capture_fields_raise_or_skip
    invalid = CDX::Capture.new({
      "url" => "https://example.com/invalid",
      "offset" => "-1",
      "length" => "0"
    })
    valid = CDX::Capture.new({
      "url" => "https://example.com/valid",
      "filename" => "crawl-data/CC-MAIN-2025-43/valid.warc.gz",
      "offset" => "10",
      "length" => "5"
    })
    archive = CDX::HTTP::RemoteArchive.new(StubIndex.new([invalid, valid]))

    error = assert_raises(CDX::HTTP::UnrequestableCapture) do
      archive.requests("example.com/*").first
    end
    assert_same invalid, error.capture
    assert_equal %w[filename offset length], error.missing_fields

    skipped = archive.requests("example.com/*", on_missing: :skip).to_a
    assert_equal 1, skipped.length
    assert_equal "https://data.commoncrawl.org/crawl-data/CC-MAIN-2025-43/valid.warc.gz", skipped.first.url
  end

  def test_request_hash_is_generic
    request = CDX::HTTP::RemoteArchive.new(@index).requests("commoncrawl.org/").first

    assert_equal request.url, request.to_h[:url]
    assert_equal request.request_uri, request.to_h[:request_uri]
    assert_equal request.range_header_value, request.to_h[:range_header_value]
    assert_equal "GET", request.to_h[:method]
    assert_equal "data.commoncrawl.org", request.to_h[:host]
  end

  StubIndex = Struct.new(:captures_to_return) do
    def captures(*, **)
      captures_to_return.each
    end
  end
end

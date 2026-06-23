require_relative "test_helper"

class IndexTest < Minitest::Test
  def setup
    @index = CDX::Index.open(fixture_path("sample.cdxj"))
  end

  def test_prefix_query_matches_canonical_host_and_www
    urls = @index.captures("commoncrawl.org/*").map(&:url)

    assert_includes urls, "https://commoncrawl.org/"
    assert_includes urls, "https://www.commoncrawl.org/blog/"
    refute_includes urls, "https://assets.commoncrawl.org/logo.png"
  end

  def test_domain_query_matches_subdomains
    urls = @index.captures("*.commoncrawl.org").map(&:url)

    assert_includes urls, "https://commoncrawl.org/"
    assert_includes urls, "https://assets.commoncrawl.org/logo.png"
  end

  def test_exact_query_matches_unschemed_url_across_http_and_https
    capture = @index.captures("commoncrawl.org/get-started").first

    assert_equal "https://www.commoncrawl.org/get-started", capture.url
  end

  def test_filter_string_exact_and_inverted
    ok = @index.captures("example.com/*", filters: "=status:200").to_a
    not_found = @index.captures("example.com/*", filters: "!=status:200").to_a

    assert_equal ["https://example.com/about"], ok.map(&:url)
    assert_equal ["http://example.com/"], not_found.map(&:url)
  end

  def test_filter_hash_regex_and_proc
    captures = @index.captures(
      "commoncrawl.org/*",
      filters: [
        {"mime" => /html/},
        ->(capture) { capture.warc_length > 10_000 }
      ]
    ).to_a

    assert_equal ["https://commoncrawl.org/", "https://www.commoncrawl.org/get-started"], captures.map(&:url)
  end

  def test_timestamp_range
    captures = @index.captures("commoncrawl.org/*", from: "20251015", to: "20251016").to_a

    assert_equal ["https://commoncrawl.org/", "https://www.commoncrawl.org/blog/"], captures.map(&:url)
  end

  def test_limit_and_field_projection
    capture = @index.captures("commoncrawl.org/*", fields: %w[url status]).first

    assert_equal({"url" => "https://commoncrawl.org/", "status" => "200"}, capture.to_h)
  end

  def test_count_is_exact_for_local_files
    assert_equal 4, @index.captures("commoncrawl.org/*").count
    assert_equal 7, @index.count
  end

  def test_closest_sorts_by_distance
    captures = @index.captures("commoncrawl.org/*", closest: "20251015000000", limit: 2).to_a

    assert_equal ["https://www.commoncrawl.org/get-started", "https://www.commoncrawl.org/blog/"], captures.map(&:url)
  end

  def test_cdx11_fixture
    index = CDX::Index.open(fixture_path("sample.cdx"))
    capture = index.captures("commoncrawl.org/old").first

    assert_equal "https://commoncrawl.org/old", capture.url
    assert_equal 654, capture.warc_offset
    assert_equal 321, capture.warc_length
    assert_equal 654..974, capture.byte_range
  end

  def test_gzip_input
    Dir.mktmpdir do |dir|
      gz_path = File.join(dir, "sample.cdxj.gz")
      Zlib::GzipWriter.open(gz_path) do |gzip|
        gzip.write File.read(fixture_path("sample.cdxj"))
      end

      index = CDX::Index.open(gz_path)
      assert_equal 4, index.captures("commoncrawl.org/*").count
    end
  end

  def test_glob_input_filters_non_index_files
    Dir.mktmpdir do |dir|
      gz_path = File.join(dir, "cdx-00000.gz")
      ignored = File.join(dir, "metadata.yaml")
      File.write(ignored, "---\n")

      Zlib::GzipWriter.open(gz_path) do |gzip|
        gzip.write File.read(fixture_path("sample.cdxj"))
      end

      index = CDX::Index.open(File.join(dir, "*"))
      assert_equal [gz_path], index.paths
    end
  end

  def test_explicit_non_index_file_raises
    Dir.mktmpdir do |dir|
      path = File.join(dir, "metadata.yaml")
      File.write(path, "---\n")

      error = assert_raises(ArgumentError) { CDX::Index.open(path) }
      assert_match(/not a supported CDX\/CDXJ index file/, error.message)
    end
  end

  def test_directory_input_recognizes_common_crawl_shard_names
    Dir.mktmpdir do |dir|
      gz_path = File.join(dir, "cdx-00000.gz")
      File.write(File.join(dir, "cluster.idx"), "not a cdx shard\n")
      File.write(File.join(dir, "metadata.yaml"), "---\n")

      Zlib::GzipWriter.open(gz_path) do |gzip|
        gzip.write File.read(fixture_path("sample.cdxj"))
      end

      index = CDX::Index.open(dir)
      assert_equal [gz_path], index.paths
      assert_equal 4, index.captures("commoncrawl.org/*").count
    end
  end

  def test_open_accepts_block_form
    count = CDX::Index.open(fixture_path("sample.cdxj")) do |index|
      index.captures("example.com/*").count
    end

    assert_equal 2, count
  end

  def test_block_iteration_returns_receiver
    returned = @index.captures("example.com/*") { |_capture| }

    assert_same @index, returned
  end

  def test_capture_slice_accepts_varargs
    capture = @index.captures("commoncrawl.org/*").first

    assert_equal({"url" => "https://commoncrawl.org/", "status" => "200"}, capture.slice("url", "status"))
  end

  def test_capture_fields_returns_copy
    capture = @index.captures("commoncrawl.org/*").first
    fields = capture.fields
    fields["url"] = "changed"

    assert_equal "https://commoncrawl.org/", capture.url
  end

  def test_capture_with_fields_returns_capture
    capture = @index.captures("commoncrawl.org/*").first.with_fields("url", "status")

    assert_instance_of CDX::Capture, capture
    assert_equal({"url" => "https://commoncrawl.org/", "status" => "200"}, capture.to_h)
  end

  def test_match_keyword_and_validation
    domain_urls = @index.captures("commoncrawl.org", match: :domain).map(&:url)

    assert_includes domain_urls, "https://assets.commoncrawl.org/logo.png"

    error = assert_raises(ArgumentError) do
      @index.captures("commoncrawl.org", match: :weird).first
    end
    assert_match(/unsupported match/, error.message)
  end

  def test_sort_validation
    error = assert_raises(ArgumentError) do
      @index.captures("commoncrawl.org/*", sort: :sideways).first
    end

    assert_match(/unsupported sort/, error.message)
  end
end

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

  def test_gzip_input_reads_concatenated_members
    Dir.mktmpdir do |dir|
      gz_path = File.join(dir, "cdx-00000.gz")
      first_member = <<~CDXJ
        com,example)/ 20240101010101 {"url":"http://example.com/","status":"200"}
      CDXJ
      second_member = <<~CDXJ
        org,commoncrawl)/ 20251016192109 {"url":"https://commoncrawl.org/","status":"200"}
      CDXJ
      File.binwrite(gz_path, gzip(first_member) + gzip(second_member))

      index = CDX::Index.open(gz_path)
      assert_equal ["http://example.com/", "https://commoncrawl.org/"], index.map(&:url)
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

  def test_directory_input_uses_zipnum_lookup_when_cluster_idx_exists
    Dir.mktmpdir do |dir|
      first_block = <<~CDXJ
        com,example)/ 20240101010101 {"url":"http://example.com/","status":"200","length":"10","offset":"5","filename":"crawl-data/example.warc.gz"}
      CDXJ
      second_block = <<~CDXJ
        org,commoncrawl)/ 20251016192109 {"url":"https://commoncrawl.org/","status":"200","length":"12695","offset":"160581106","filename":"crawl-data/CC-MAIN-2025-43/root.warc.gz"}
        org,commoncrawl)/blog/ 20251015120000 {"url":"https://www.commoncrawl.org/blog/","status":"200","length":"5321","offset":"42","filename":"crawl-data/CC-MAIN-2025-43/blog.warc.gz"}
        org,commoncrawl,assets)/logo.png 20251014120000 {"url":"https://assets.commoncrawl.org/logo.png","status":"200","length":"123","offset":"100","filename":"crawl-data/CC-MAIN-2025-43/logo.warc.gz"}
      CDXJ
      first_gzip = gzip(first_block)
      second_gzip = gzip(second_block)
      File.binwrite(File.join(dir, "cdx-00000.gz"), first_gzip + second_gzip)
      File.write(File.join(dir, "cdx-00001.gz"), "not gzip")
      File.write(
        File.join(dir, "cluster.idx"),
        [
          "com,example)/ 20240101010101\tcdx-00000.gz\t0\t#{first_gzip.bytesize}\t1",
          "org,commoncrawl)/ 20251016192109\tcdx-00000.gz\t#{first_gzip.bytesize}\t#{second_gzip.bytesize}\t2",
          "org,commoncrawla)/ 20250101000000\tcdx-00001.gz\t0\t10\t3",
          "zzz,example)/ 20250101000000\tcdx-00001.gz\t0\t10\t3"
        ].join("\n")
      )

      index = CDX::Index.open(dir)
      captures = index.captures("commoncrawl.org/*").to_a
      assert_equal ["https://commoncrawl.org/", "https://www.commoncrawl.org/blog/"], captures.map(&:url)
      assert_equal [3001, 3002], captures.map(&:line_number)
      assert_equal [
        "https://commoncrawl.org/",
        "https://www.commoncrawl.org/blog/",
        "https://assets.commoncrawl.org/logo.png"
      ], index.captures("*.commoncrawl.org").map(&:url)
    end
  end

  def test_zipnum_lookup_keeps_unreferenced_files_in_fallback_scan
    Dir.mktmpdir do |dir|
      zipnum_block = <<~CDXJ
        com,example)/ 20240101010101 {"url":"http://example.com/","status":"200"}
      CDXJ
      uncovered_block = <<~CDXJ
        example,uncovered)/ 20250101010101 {"url":"https://uncovered.example/","status":"200"}
      CDXJ
      extra_index = <<~CDXJ
        org,commoncrawl)/extra 20251016192109 {"url":"https://commoncrawl.org/extra","status":"200"}
      CDXJ
      zipnum_gzip = gzip(zipnum_block)
      File.binwrite(File.join(dir, "cdx-00000.gz"), zipnum_gzip)
      File.binwrite(File.join(dir, "cdx-00001.gz"), gzip(uncovered_block))
      File.write(File.join(dir, "extra.cdxj"), extra_index)
      File.write(
        File.join(dir, "cluster.idx"),
        "com,example)/ 20240101010101\tcdx-00000.gz\t0\t#{zipnum_gzip.bytesize}\t1\n"
      )

      index = CDX::Index.open(dir)
      assert_equal ["https://commoncrawl.org/extra"], index.captures("commoncrawl.org/*").map(&:url)
      assert_equal ["https://uncovered.example/"], index.captures("uncovered.example/*").map(&:url)
    end
  end

  def test_zipnum_lookup_keeps_partially_covered_shard_in_fallback_scan
    Dir.mktmpdir do |dir|
      first_block = <<~CDXJ
        com,example)/ 20240101010101 {"url":"http://example.com/","status":"200"}
      CDXJ
      second_block = <<~CDXJ
        org,commoncrawl)/missing 20251016192109 {"url":"https://commoncrawl.org/missing","status":"200"}
      CDXJ
      first_gzip = gzip(first_block)
      File.binwrite(File.join(dir, "cdx-00000.gz"), first_gzip + gzip(second_block))
      File.write(
        File.join(dir, "cluster.idx"),
        "com,example)/ 20240101010101\tcdx-00000.gz\t0\t#{first_gzip.bytesize}\t1\n"
      )

      index = CDX::Index.open(dir)
      assert_equal ["https://commoncrawl.org/missing"], index.captures("commoncrawl.org/*").map(&:url)
      assert_equal ["http://example.com/"], index.captures("example.com/*").map(&:url)
    end
  end

  def test_zipnum_lookup_preserves_path_order_with_limit
    Dir.mktmpdir do |dir|
      fallback_block = <<~CDXJ
        example,order)/first 20250101010101 {"url":"https://order.example/first","status":"200"}
      CDXJ
      zipnum_block = <<~CDXJ
        example,order)/second 20250101010102 {"url":"https://order.example/second","status":"200"}
      CDXJ
      zipnum_gzip = gzip(zipnum_block)
      File.binwrite(File.join(dir, "cdx-00000.gz"), gzip(fallback_block))
      File.binwrite(File.join(dir, "cdx-00001.gz"), zipnum_gzip)
      File.write(
        File.join(dir, "cluster.idx"),
        "example,order)/second 20250101010102\tcdx-00001.gz\t0\t#{zipnum_gzip.bytesize}\t1\n"
      )

      index = CDX::Index.open(dir)
      assert_equal ["https://order.example/first"], index.captures("order.example/*", limit: 1).map(&:url)
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

  private

  def gzip(text)
    output = StringIO.new
    Zlib::GzipWriter.wrap(output) { |gzip| gzip.write(text) }
    output.string
  end
end

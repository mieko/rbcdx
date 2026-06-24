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

  def test_closest_with_limit_selects_global_candidates_after_scanning_all_matches
    Dir.mktmpdir do |dir|
      path = File.join(dir, "bounded.cdxj")
      File.write(path, bounded_cdxj)
      index = CDX::Index.open(path)
      seen = []
      filter = lambda do |capture|
        seen << capture.url
        capture.status == "200"
      end

      captures = index.captures(
        "bounded.example/*",
        closest: "20240115000000",
        limit: 3,
        filters: filter
      ).to_a

      assert_equal [
        "https://bounded.example/day-15",
        "https://bounded.example/day-14",
        "https://bounded.example/day-16"
      ], captures.map(&:url)
      assert_equal (1..20).map { |day| "https://bounded.example/day-%02d" % day }, seen
    end
  end

  def test_sort_with_limit_selects_global_timestamp_candidates
    Dir.mktmpdir do |dir|
      path = File.join(dir, "timestamp-sort.cdxj")
      File.write(path, <<~CDXJ)
        example,sorted)/a 20240105000000 {"url":"https://sorted.example/a","status":"200"}
        example,sorted)/b 20240101000000 {"url":"https://sorted.example/b","status":"200"}
        example,sorted)/c 20240103000000 {"url":"https://sorted.example/c","status":"200"}
        example,sorted)/d 20240102000000 {"url":"https://sorted.example/d","status":"200"}
        example,sorted)/e 20240104000000 {"url":"https://sorted.example/e","status":"200"}
      CDXJ
      index = CDX::Index.open(path)

      assert_equal [
        "https://sorted.example/b",
        "https://sorted.example/d",
        "https://sorted.example/c"
      ], index.captures("sorted.example/*", sort: :timestamp, limit: 3).map(&:url)
      assert_equal [
        "https://sorted.example/a",
        "https://sorted.example/e"
      ], index.captures("sorted.example/*", sort: :reverse_timestamp, limit: 2).map(&:url)
    end
  end

  def test_cdx11_fixture
    index = CDX::Index.open(fixture_path("sample.cdx"))
    capture = index.captures("commoncrawl.org/old").first

    assert_equal "https://commoncrawl.org/old", capture.url
    assert_equal 654, capture.warc_offset
    assert_equal 321, capture.warc_length
    assert_equal 654..974, capture.byte_range
  end

  def test_capture_numeric_helpers_treat_zero_padded_values_as_decimal
    capture = CDX::Capture.new({"offset" => "00843", "length" => "00009"})

    assert_equal 843, capture.warc_offset
    assert_equal 9, capture.warc_length
    assert_equal 843..851, capture.byte_range
  end

  def test_string_limit_is_treated_as_decimal
    captures = @index.captures(limit: "08").to_a

    assert_equal 7, captures.length
  end

  def test_limit_zero_yields_no_captures
    assert_empty @index.captures(limit: 0).to_a
    assert_empty @index.captures("commoncrawl.org/*", sort: :timestamp, limit: "0").to_a
  end

  def test_limit_must_be_non_negative_decimal
    assert_raises(ArgumentError) { @index.captures(limit: "bogus").to_a }
    assert_raises(ArgumentError) { @index.captures(limit: "-1").to_a }
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
      assert_match(/not a supported local index file/, error.message)
    end
  end

  def test_rbcdx_index_files_are_recognized_but_invalid_magic_raises
    Dir.mktmpdir do |dir|
      path = File.join(dir, "sample.rbcdx")
      File.write(path, "future binary format")

      error = assert_raises(CDX::Error) { CDX::Index.open(path) }
      assert_match(/invalid rbcdx magic/, error.message)
    end
  end

  def test_rbcdx_index_file_suffixes_are_recognized
    Dir.mktmpdir do |dir|
      path = File.join(dir, "sample.rbcdxV1a")
      File.write(path, "future binary format")

      error = assert_raises(CDX::Error) { CDX::Index.open(path) }
      assert_match(/invalid rbcdx magic/, error.message)
    end
  end

  def test_rbcdx_index_rejects_missing_header_length
    Dir.mktmpdir do |dir|
      path = File.join(dir, "sample.rbcdx")
      File.binwrite(path, CDX::Backends::RbCDX::Format::MAGIC)

      error = assert_raises(CDX::Error) { CDX::Index.open(path) }
      assert_match(/missing rbcdx header length/, error.message)
    end
  end

  def test_rbcdx_index_rejects_truncated_header
    Dir.mktmpdir do |dir|
      path = File.join(dir, "sample.rbcdx")
      File.binwrite(path, CDX::Backends::RbCDX::Format::MAGIC + [10].pack("L<") + "{}")

      error = assert_raises(CDX::Error) { CDX::Index.open(path) }
      assert_match(/truncated rbcdx header/, error.message)
    end
  end

  def test_rbcdx_index_rejects_truncated_dictionary
    Dir.mktmpdir do |dir|
      path = repack_rbcdx(dir, "sample.rbcdx", minimal_repackable_cdxj)
      rewrite_rbcdx_header(path) do |header|
        header["dict_offset"] = File.size(path)
        header["dict_length"] = 1
      end

      error = assert_raises(CDX::Error) { CDX::Index.open(path) }
      assert_match(/truncated rbcdx dictionary/, error.message)
    end
  end

  def test_rbcdx_index_rejects_truncated_directory
    Dir.mktmpdir do |dir|
      path = repack_rbcdx(dir, "sample.rbcdx", minimal_repackable_cdxj)
      rewrite_rbcdx_header(path) do |header|
        header["directory_offset"] = header.fetch("cold_blocks_offset") + header.fetch("cold_blocks_length")
        header["directory_length"] = 1
      end

      error = assert_raises(CDX::Error) { CDX::Index.open(path) }
      assert_match(/truncated rbcdx directory/, error.message)
    end
  end

  def test_rbcdx_index_rejects_invalid_section_bounds
    Dir.mktmpdir do |dir|
      path = repack_rbcdx(dir, "sample.rbcdx", minimal_repackable_cdxj)
      rewrite_rbcdx_header(path) { |header| header["dict_offset"] = -1 }

      error = assert_raises(CDX::Error) { CDX::Index.open(path) }
      assert_match(/invalid rbcdx dictionary section bounds/, error.message)
    end
  end

  def test_rbcdx_index_rejects_missing_section_bounds
    Dir.mktmpdir do |dir|
      path = repack_rbcdx(dir, "sample.rbcdx", minimal_repackable_cdxj)
      rewrite_rbcdx_header(path) { |header| header.delete("directory_length") }

      error = assert_raises(CDX::Error) { CDX::Index.open(path) }
      assert_match(/missing rbcdx directory section bounds/, error.message)
    end
  end

  def test_rbcdx_index_rejects_invalid_hot_block_section_bounds
    Dir.mktmpdir do |dir|
      path = repack_rbcdx(dir, "sample.rbcdx", minimal_repackable_cdxj)
      rewrite_rbcdx_header(path) { |header| header["hot_blocks_offset"] = -1 }

      error = assert_raises(CDX::Error) { CDX::Index.open(path) }
      assert_match(/invalid rbcdx hot_blocks section bounds/, error.message)
    end
  end

  def test_rbcdx_index_rejects_hot_block_outside_declared_section
    Dir.mktmpdir do |dir|
      path = repack_rbcdx(dir, "sample.rbcdx", minimal_repackable_cdxj)
      rewrite_rbcdx_header(path) { |header| header["hot_blocks_length"] = 0 }

      error = assert_raises(CDX::Error) { CDX::Index.open(path).to_a }
      assert_match(/hot_blocks block exceeds section bounds/, error.message)
    end
  end

  def test_rbcdx_index_rejects_cold_block_outside_declared_section
    Dir.mktmpdir do |dir|
      path = repack_rbcdx(dir, "sample.rbcdx", minimal_repackable_cdxj)
      rewrite_rbcdx_header(path) { |header| header["cold_blocks_length"] = 0 }
      capture = CDX::Index.open(path).first

      error = assert_raises(CDX::Error) { capture.digest }
      assert_match(/cold_blocks block exceeds section bounds/, error.message)
    end
  end

  def test_rbcdx_index_wraps_corrupt_hot_block_payload
    Dir.mktmpdir do |dir|
      path = repack_rbcdx(dir, "sample.rbcdx", minimal_repackable_cdxj)
      overwrite_rbcdx_section(path, "hot_blocks")

      error = assert_raises(CDX::Error) { CDX::Index.open(path).to_a }
      assert_match(/hot_blocks block decompression failed/, error.message)
    end
  end

  def test_rbcdx_index_wraps_corrupt_cold_block_payload
    Dir.mktmpdir do |dir|
      path = repack_rbcdx(dir, "sample.rbcdx", minimal_repackable_cdxj)
      overwrite_rbcdx_section(path, "cold_blocks")
      capture = CDX::Index.open(path).first

      error = assert_raises(CDX::Error) { capture.digest }
      assert_match(/cold_blocks block decompression failed/, error.message)
    end
  end

  def test_rbcdx_index_file_matching_is_case_sensitive
    Dir.mktmpdir do |dir|
      path = File.join(dir, "sample.RBCDX")
      File.write(path, "not the lowercase rbcdx format")

      error = assert_raises(ArgumentError) { CDX::Index.open(path) }
      assert_match(/not a supported local index file/, error.message)
    end
  end

  def test_directory_rejects_gzip_and_rbcdx_files_together
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "cdx-00000.gz"), "")
      File.write(File.join(dir, "sample.rbcdx"), "future binary format")

      error = assert_raises(ArgumentError) { CDX::Index.open(dir) }
      assert_match(/cannot mix CDX \.gz and \.rbcdx index files/, error.message)
    end
  end

  def test_directory_rejects_gzip_and_rbcdx_suffix_files_together
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "cdx-00000.gz"), "")
      File.write(File.join(dir, "sample.rbcdxbin"), "future binary format")

      error = assert_raises(ArgumentError) { CDX::Index.open(dir) }
      assert_match(/cannot mix CDX \.gz and \.rbcdx index files/, error.message)
    end
  end

  def test_directory_does_not_treat_unrelated_gzip_files_as_cdx_mix
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "README.gz"), "compressed notes")
      File.write(File.join(dir, "sample.rbcdx"), "future binary format")

      error = assert_raises(CDX::Error) { CDX::Index.open(dir) }
      assert_match(/invalid rbcdx magic/, error.message)
    end
  end

  def test_directory_does_not_treat_rbcdx_substrings_as_index_files
    Dir.mktmpdir do |dir|
      gz_path = File.join(dir, "cdx-00000.gz")
      Zlib::GzipWriter.open(gz_path) do |gzip|
        gzip.write "com,example)/ 20240101010101 {\"url\":\"http://example.com/\",\"status\":\"200\"}\n"
      end
      File.write(File.join(dir, "notes.rbcdx.md"), "not an index")

      index = CDX::Index.open(dir)
      assert_equal [gz_path], index.paths
      assert_equal ["http://example.com/"], index.map(&:url)
    end
  end

  def test_index_rejects_mixed_backends_from_explicit_paths
    Dir.mktmpdir do |dir|
      cdx_path = File.join(dir, "sample.cdxj")
      rbcdx_path = File.join(dir, "sample.rbcdx")
      File.write(cdx_path, File.read(fixture_path("sample.cdxj")))
      File.write(rbcdx_path, "future binary format")

      error = assert_raises(ArgumentError) { CDX::Index.open(cdx_path, rbcdx_path) }
      assert_match(/cannot mix local index formats/, error.message)
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

  def test_zipnum_lookup_groups_discontiguous_entries_by_filename
    Dir.mktmpdir do |dir|
      first_block = <<~CDXJ
        com,alpha)/first 20250101010101 {"url":"https://alpha.com/first","status":"200"}
      CDXJ
      middle_block = <<~CDXJ
        com,middle)/only 20250101010102 {"url":"https://middle.com/only","status":"200"}
      CDXJ
      second_block = <<~CDXJ
        com,zeta)/second 20250101010103 {"url":"https://zeta.com/second","status":"200"}
      CDXJ
      first_gzip = gzip(first_block)
      middle_gzip = gzip(middle_block)
      second_gzip = gzip(second_block)
      shard_path = File.join(dir, "cdx-00000.gz")
      middle_path = File.join(dir, "cdx-00001.gz")
      cluster_path = File.join(dir, "cluster.idx")
      File.binwrite(shard_path, first_gzip + second_gzip)
      File.binwrite(middle_path, middle_gzip)
      File.write(
        cluster_path,
        [
          "com,alpha)/first 20250101010101\tcdx-00000.gz\t0\t#{first_gzip.bytesize}\t1",
          "com,middle)/only 20250101010102\tcdx-00001.gz\t0\t#{middle_gzip.bytesize}\t1",
          "com,zeta)/second 20250101010103\tcdx-00000.gz\t#{first_gzip.bytesize}\t#{second_gzip.bytesize}\t2"
        ].join("\n")
      )

      zipnum = CDX::Backends::CDXJ::ZipNumIndex.new(cluster_path, [shard_path, middle_path])
      assert_equal [shard_path, middle_path], zipnum.paths

      capture = CDX::Index.open(dir).captures("zeta.com/*").first
      assert_equal "https://zeta.com/second", capture.url
      assert_equal 3001, capture.line_number
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

  def test_zipnum_entries_treat_zero_padded_numbers_as_decimal
    Dir.mktmpdir do |dir|
      cluster_path = File.join(dir, "cluster.idx")
      File.write(cluster_path, "example,zero)/\tcdx-00000.gz\t00008\t00009\t00001\n")

      assert_predicate CDX::Backends::CDXJ::ZipNumIndex.new(cluster_path, []), :usable?
    end
  end

  def test_rbcdx_manifest_skips_noncandidate_files
    Dir.mktmpdir do |dir|
      alpha = repack_rbcdx(dir, "cdx-00000.rbcdx", <<~CDXJ)
        com,alpha)/ 20240101010101 {"url":"https://alpha.com/","mime":"text/html","status":"200","length":"10","offset":"1","filename":"crawl-data/CC-MAIN-2025-43/segments/123.45/warc/CC-MAIN-20250101000000-20250101030000-00001.warc.gz"}
      CDXJ
      zeta = repack_rbcdx(dir, "cdx-00001.rbcdx", <<~CDXJ)
        com,zeta)/ 20240101010101 {"url":"https://zeta.com/","mime":"text/html","status":"200","length":"10","offset":"1","filename":"crawl-data/CC-MAIN-2025-43/segments/123.45/warc/CC-MAIN-20250101000000-20250101030000-00001.warc.gz"}
      CDXJ
      CDX::Backends::RbCDX::Manifest.write([alpha, zeta], File.join(dir, CDX::Backends::RbCDX::Manifest::FILENAME))
      File.binwrite(zeta, "x" * File.size(zeta))

      index = CDX::Index.open(dir)

      assert_equal ["https://alpha.com/"], index.captures("alpha.com/*").map(&:url)
    end
  end

  def test_rbcdx_manifest_keeps_uncovered_files_in_fallback_scan
    Dir.mktmpdir do |dir|
      alpha = repack_rbcdx(dir, "cdx-00000.rbcdx", <<~CDXJ)
        com,alpha)/ 20240101010101 {"url":"https://alpha.com/","mime":"text/html","status":"200","length":"10","offset":"1","filename":"crawl-data/CC-MAIN-2025-43/segments/123.45/warc/CC-MAIN-20250101000000-20250101030000-00001.warc.gz"}
      CDXJ
      repack_rbcdx(dir, "cdx-00001.rbcdx", <<~CDXJ)
        com,zeta)/ 20240101010101 {"url":"https://zeta.com/","mime":"text/html","status":"200","length":"10","offset":"1","filename":"crawl-data/CC-MAIN-2025-43/segments/123.45/warc/CC-MAIN-20250101000000-20250101030000-00001.warc.gz"}
      CDXJ
      CDX::Backends::RbCDX::Manifest.write([alpha], File.join(dir, CDX::Backends::RbCDX::Manifest::FILENAME))

      index = CDX::Index.open(dir)

      assert_equal ["https://zeta.com/"], index.captures("zeta.com/*").map(&:url)
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

  def test_capture_exposes_fields_as_methods
    capture = @index.captures("commoncrawl.org/*").first

    assert_equal "https://commoncrawl.org/", capture.url
    assert_equal "text/html", capture.mime_detected
    assert_equal "ROOTDIGEST", capture.digest
    assert_equal "12695", capture.length
    assert_equal 12_695, capture.warc_length
  end

  def test_capture_does_not_expose_hash_access
    capture = @index.captures("commoncrawl.org/*").first

    refute_respond_to capture, :[]
    refute_respond_to capture, :fetch
    refute_respond_to capture, :key?
    refute_respond_to capture, :each
    refute_respond_to capture, :slice
    refute_respond_to capture, :fields
  end

  def test_capture_to_h_returns_copy
    capture = @index.captures("commoncrawl.org/*").first
    data = capture.to_h
    data["url"] = "changed"

    assert_equal "https://commoncrawl.org/", capture.url
  end

  def test_capture_to_h_materializes_lazy_method_fields
    capture = LazyCapture.new({"url" => "https://example.com/"}, fields: %w[url digest])

    assert_equal({"url" => "https://example.com/", "digest" => "LAZYDIGEST"}, capture.to_h)
    assert_equal 1, capture.digest_calls
  end

  def test_capture_to_h_preserves_fields_that_collide_with_ruby_methods
    capture = CDX::Capture.new({"hash" => "stored-hash", "class" => "stored-class"})

    assert_equal({"hash" => "stored-hash", "class" => "stored-class"}, capture.to_h)
    assert_equal "stored-hash", capture.field("hash")
    assert_equal "stored-class", capture.field("class")
  end

  def test_capture_field_prefers_stored_data_over_field_like_methods
    capture = CDX::Capture.new({
      "warc_url" => "stored-warc-url",
      "to_h" => "stored-to-h",
      "field" => "stored-field"
    })

    assert_equal "stored-warc-url", capture.field("warc_url")
    assert_equal "stored-to-h", capture.field("to_h")
    assert_equal "stored-field", capture.field("field")
    assert_equal({"warc_url" => "stored-warc-url", "to_h" => "stored-to-h", "field" => "stored-field"}, capture.to_h)
  end

  def test_capture_field_does_not_call_non_capture_field_methods
    capture = CDX::Capture.new({})

    assert_nil capture.field("warc_url")
    assert_nil capture.field("to_h")
    assert_nil capture.field("field")
  end

  def test_capture_with_fields_returns_capture
    capture = @index.captures("commoncrawl.org/*").first.with_fields("url", "status")

    assert_instance_of CDX::Capture, capture
    assert_equal({"url" => "https://commoncrawl.org/", "status" => "200"}, capture.to_h)
  end

  def test_capture_with_fields_materializes_lazy_method_fields
    capture = LazyCapture.new({"url" => "https://example.com/"}, fields: %w[url digest])
    projected = capture.with_fields("digest")

    assert_instance_of LazyCapture, projected
    assert_equal 1, capture.digest_calls
    assert_equal({"digest" => "LAZYDIGEST"}, projected.to_h)
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

  class LazyCapture < CDX::Capture
    attr_reader :digest_calls

    def initialize(data = {}, source_path: nil, line_number: nil, fields: %w[url digest])
      @digest_calls = 0
      super
    end

    def digest
      @digest_calls += 1
      "LAZYDIGEST"
    end
  end

  def gzip(text)
    output = StringIO.new
    Zlib::GzipWriter.wrap(output) { |gzip| gzip.write(text) }
    output.string
  end

  def bounded_cdxj
    (1..20).map do |day|
      path = "day-%02d" % day
      timestamp = "202401%02d000000" % day
      "example,bounded)/#{path} #{timestamp} {\"url\":\"https://bounded.example/#{path}\",\"status\":\"200\"}\n"
    end.join
  end

  def minimal_repackable_cdxj
    <<~CDXJ
      com,alpha)/ 20240101010101 {"url":"https://alpha.com/","mime":"text/html","status":"200","length":"10","offset":"1","filename":"crawl-data/CC-MAIN-2025-43/segments/123.45/warc/CC-MAIN-20250101000000-20250101030000-00001.warc.gz"}
    CDXJ
  end

  def repack_rbcdx(dir, basename, cdxj)
    input = File.join(dir, "#{basename}.cdxj")
    output = File.join(dir, basename)
    File.write(input, cdxj)
    CDX::Repacker.repack(input, output, max_records: 1)
    File.delete(input)
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

  def overwrite_rbcdx_section(path, name)
    header = read_rbcdx_header(path)
    offset = header.fetch("#{name}_offset")
    length = header.fetch("#{name}_length")
    File.open(path, "r+b") do |file|
      file.seek(offset)
      file.write("\0".b * length)
    end
  end

  def read_rbcdx_header(path)
    File.open(path, "rb") do |file|
      magic = file.read(CDX::Backends::RbCDX::Format::MAGIC.bytesize)
      raise "invalid test rbcdx magic" unless magic == CDX::Backends::RbCDX::Format::MAGIC

      header_length = file.read(4).unpack1("L<")
      JSON.parse(file.read(header_length))
    end
  end
end

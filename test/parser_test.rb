require_relative "test_helper"

class ParserTest < Minitest::Test
  def test_parses_raw_cdxj_lines
    parser = CDX::Backends::CDXJ::Parser.new
    data = parser.parse('org,example)/ 20250101000000 {"url":"https://example.org/","status":"200"}')

    assert_equal "org,example)/", data["urlkey"]
    assert_equal "20250101000000", data["timestamp"]
    assert_equal "https://example.org/", data["url"]
  end

  def test_parses_json_object_lines
    parser = CDX::Backends::CDXJ::Parser.new
    data = parser.parse('{"urlkey":"org,example)/","timestamp":"20250101000000","url":"https://example.org/"}')

    assert_equal "org,example)/", data["urlkey"]
    assert_equal "https://example.org/", data["url"]
  end

  def test_parses_cdx11_rows_after_header
    parser = CDX::Backends::CDXJ::Parser.new
    assert_nil parser.parse(" CDX N b a m s k r M S V g")

    data = parser.parse("org,example)/ 20200101000000 https://example.org/ text/html 200 DIG - - 123 456 crawl-data/example.warc.gz")

    assert_equal "org,example)/", data["urlkey"]
    assert_equal "20200101000000", data["timestamp"]
    assert_equal "https://example.org/", data["url"]
    assert_equal "123", data["length"]
    assert_equal "456", data["offset"]
    assert_equal "crawl-data/example.warc.gz", data["filename"]
  end
end

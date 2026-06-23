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
end

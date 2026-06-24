require_relative "test_helper"

class RbCDXFormatTest < Minitest::Test
  ExpandingJsonValue = Class.new do
    def initialize
      @calls = 0
    end

    def to_json(*)
      @calls += 1
      JSON.generate("x" * @calls)
    end
  end

  def test_parse_filename_treats_zero_padded_shards_as_decimal
    parsed = CDX::Backends::RbCDX::Format.parse_filename(
      "sample.cdxj",
      1,
      "org,example)/",
      "crawl-data/CC-MAIN-2026-25/segments/1749571843203.36/warc/CC-MAIN-20260610131725-20260610161725-00843.warc.gz",
      {}
    )

    assert_equal ["CC-MAIN-2026-25", "1749571843203.36", "warc", "CC-MAIN-20260610131725-20260610161725", 843], parsed
  end

  def test_parse_nonnegative_integer_treats_zero_padded_values_as_decimal
    assert_equal 843, CDX::Backends::RbCDX::Format.parse_nonnegative_integer("sample.cdxj", 1, "org,example)/", "offset", "00843")
  end

  def test_read_metadata_rejects_non_object_header_json
    Dir.mktmpdir do |dir|
      path = File.join(dir, "bad.rbcdx")
      header = JSON.generate([])
      File.binwrite(path, CDX::Backends::RbCDX::Format::MAGIC + [header.bytesize].pack("L<") + header)

      error = assert_raises(CDX::Error) do
        CDX::Backends::RbCDX::Format.read_metadata(path)
      end

      assert_match(/header must be a JSON object/, error.message)
    end
  end

  def test_decode_payload_rejects_non_monotonic_column_offsets
    payload = +"HOT3".b
    payload << [1, 0, 1, 0].pack("L<Q<S<S<")
    payload << [1, 0].pack("L<L<")
    payload << "x"

    error = assert_raises(CDX::Error) do
      CDX::Backends::RbCDX::Format.decode_payload(payload, "HOT3".b, ["one"])
    end
    assert_match(/column offsets are not monotonic/, error.message)
  end

  def test_front_coded_string_rejects_prefix_past_previous_string
    data = +"".b
    data << [32].pack("S<")
    data << CDX::Backends::RbCDX::Format.varint(1)
    data << CDX::Backends::RbCDX::Format.varint(0)

    error = assert_raises(CDX::Error) do
      CDX::Backends::RbCDX::Format.decode_front_coded_strings(data, 1)
    end
    assert_match(/prefix exceeds previous string length/, error.message)
  end

  def test_unpack_unsigned_rejects_truncated_column
    error = assert_raises(CDX::Error) do
      CDX::Backends::RbCDX::Format.unpack_unsigned([8, 1].pack("CC"), 2)
    end

    assert_match(/packed integer column is truncated/, error.message)
  end

  def test_unpack_unsigned_rejects_trailing_bytes
    data = CDX::Backends::RbCDX::Format.pack_unsigned([1])
    error = assert_raises(CDX::Error) do
      CDX::Backends::RbCDX::Format.unpack_unsigned(data + "\0".b, 1)
    end

    assert_match(/packed integer column has trailing bytes/, error.message)
  end

  def test_decode_directory_rejects_zero_restart_interval
    data = [0, 0].pack("L<S<")

    error = assert_raises(CDX::Error) do
      CDX::Backends::RbCDX::Format.decode_directory(data)
    end

    assert_match(/directory has zero restart interval/, error.message)
  end

  def test_decode_directory_rejects_truncated_block_record
    data = [1, 1].pack("L<S<")
    data << CDX::Backends::RbCDX::Format.varint(0) << CDX::Backends::RbCDX::Format.varint(1) << "a"
    data << CDX::Backends::RbCDX::Format.varint(0) << CDX::Backends::RbCDX::Format.varint(1) << "a"

    error = assert_raises(CDX::Error) do
      CDX::Backends::RbCDX::Format.decode_directory(data)
    end

    assert_match(/directory block record is truncated/, error.message)
  end

  def test_decode_directory_rejects_trailing_bytes
    data = [0, 1].pack("L<S<") + "x"

    error = assert_raises(CDX::Error) do
      CDX::Backends::RbCDX::Format.decode_directory(data)
    end

    assert_match(/directory section has trailing bytes/, error.message)
  end

  def test_decode_dictionaries_rejects_truncated_table_name
    data = [1].pack("L<") + [2].pack("S<") + "x"

    error = assert_raises(CDX::Error) do
      CDX::Backends::RbCDX::Format.decode_dictionaries(data)
    end

    assert_match(/dictionary table name is truncated/, error.message)
  end

  def test_decode_dictionaries_rejects_trailing_bytes
    data = [0].pack("L<") + "x"

    error = assert_raises(CDX::Error) do
      CDX::Backends::RbCDX::Format.decode_dictionaries(data)
    end

    assert_match(/dictionary section has trailing bytes/, error.message)
  end

  def test_write_file_rejects_non_converging_header_offsets
    Dir.mktmpdir do |dir|
      path = File.join(dir, "out.rbcdx")

      error = assert_raises(CDX::Error) do
        CDX::Backends::RbCDX::Format.write_file(
          path,
          dict_data: +"dict".b,
          directory_data: +"directory".b,
          hot_data: +"hot".b,
          cold_data: +"cold".b,
          header: {
            "version" => CDX::Backends::RbCDX::Format::VERSION,
            "unstable" => ExpandingJsonValue.new
          }
        )
      end

      assert_match(/header offsets did not converge/, error.message)
      refute File.exist?(path)
    end
  end
end

require "fileutils"
require "json"
require "time"
require "uri"
require "zlib"
require "zstd-ruby"

module CDX
  module Backends
    class RbCDX
      module Format
        MAGIC = "RBCDXV3A\n".b
        HOT_BLOCK_MAGIC = "HOT3".b
        COLD_BLOCK_MAGIC = "CLD3".b
        VERSION = 3
        VARIANT = "v3a"
        SOURCE_KIND_COMMON_CRAWL_CDXJ = 1
        DEFAULT_RESTART_INTERVAL = 32
        DEFAULT_BLOCK_BYTES = 512 * 1024
        DEFAULT_MAX_RECORDS = 16_384
        DEFAULT_SECTIONS = %w[dict directory hot_blocks cold_blocks].freeze
        SECTION_LABELS = {
          "dict" => "dictionary"
        }.freeze

        KNOWN_FIELDS = %w[
          url
          mime
          mime-detected
          status
          digest
          length
          offset
          filename
          charset
          languages
          redirect
          truncated
        ].freeze
        REQUIRED_FIELDS = %w[url mime status length offset filename].freeze
        TABLE_NAMES = [
          "status",
          "mime",
          "mime-detected",
          "charset",
          "language",
          "truncated",
          "segment",
          "warc-time-pair",
          "fallback-filename"
        ].freeze

        KIND_TO_ID = {
          "warc" => 0,
          "robotstxt" => 1,
          "crawldiagnostics" => 2
        }.freeze
        ID_TO_KIND = KIND_TO_ID.invert.freeze
        FILENAME_PATTERN = %r{\Acrawl-data/([^/]+)/segments/([^/]+)/(warc|robotstxt|crawldiagnostics)/(.+)-(\d{5})\.warc\.gz\z}

        HOT_COLUMN_NAMES = [
          "record_flags",
          "status_and_hot_flags",
          "mime_and_flags",
          "mime_detected_and_flags",
          "urlkey_front_codes",
          "url_without_scheme_front_codes",
          "timestamp_deltas",
          "lengths",
          "offsets",
          "filename_kind",
          "segment_ids",
          "warc_time_pair_ids",
          "shard_ids",
          "fallback_filename_ids",
          "status_extended_ids",
          "mime_extended_ids",
          "mime_detected_extended_ids"
        ].freeze

        COLD_COLUMN_NAMES = [
          "digest",
          "redirects",
          "charset_ids",
          "languages",
          "truncated_ids",
          "extras"
        ].freeze

        RECORD_FLAG_HAS_PORT = 1 << 0
        RECORD_FLAG_HAS_QUERY_OR_FRAGMENT = 1 << 1
        RECORD_FLAG_FALLBACK_FILENAME = 1 << 2
        STATUS_FLAG_HTTPS = 1 << 6
        STATUS_FLAG_HAS_REDIRECT = 1 << 7
        MIME_FLAG_HAS_CHARSET = 1 << 7
        MIME_DETECTED_FLAG_HAS_LANGUAGES = 1 << 6
        MIME_DETECTED_FLAG_HAS_TRUNCATED = 1 << 7
        BASE32_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"

        BlockEntry = Struct.new(
          :first_urlkey,
          :last_urlkey,
          :record_count,
          :hot_compressed_offset,
          :hot_compressed_length,
          :hot_uncompressed_length,
          :cold_compressed_offset,
          :cold_compressed_length,
          :cold_uncompressed_length,
          :block_base_timestamp
        )
        SectionBounds = Struct.new(:name, :offset, :length) do
          def finish
            offset + length
          end
        end
        FileMetadata = Struct.new(:path, :header, :header_length, :file_size, :sections) do
          def first_section_offset
            Format::MAGIC.bytesize + 4 + header_length
          end

          def section(name)
            sections.fetch(name.to_s)
          end

          def read_section(name)
            bounds = section(name)
            File.open(path, "rb") do |file|
              file.seek(bounds.offset)
              data = file.read(bounds.length)
              unless data&.bytesize == bounds.length
                raise Error, "#{path}: truncated rbcdx #{Format.section_label(name)}"
              end

              data
            end
          rescue SystemCallError => error
            raise Error, "#{path}: invalid rbcdx #{Format.section_label(name)} section bounds: #{error.message}"
          end
        end
        FilenameRef = Struct.new(:kind, :segment_id, :warc_time_pair_id, :shard_id, :fallback_filename_id)
        Record = Struct.new(
          :source_path,
          :line_number,
          :urlkey,
          :timestamp_epoch,
          :url_without_scheme,
          :https,
          :has_port,
          :has_query_or_fragment,
          :status_id,
          :mime_id,
          :mime_detected_id,
          :digest,
          :length,
          :offset,
          :filename_ref,
          :charset_id,
          :language_ids,
          :redirect,
          :truncated_id
        )

        class EncodeError < Error
          def initialize(source_path:, line_number:, urlkey:, field:, value:, reason:, suggestion: nil)
            display = value.inspect
            display = "#{display[0, 237]}..." if display.length > 240
            message = "cannot encode CDX record at #{source_path}:#{line_number}\n"
            message << "urlkey: #{urlkey || "<unknown>"}\n"
            message << "field: #{field}\n"
            message << "value: #{display}\n"
            message << "reason: #{reason}"
            message << "\nsuggestion: #{suggestion}" if suggestion
            super(message)
          end
        end

        module_function

        def varint(value)
          raise ArgumentError, "varint cannot encode negative values" if value.negative?

          output = +"".b
          while value >= 0x80
            output << ((value & 0x7f) | 0x80)
            value >>= 7
          end
          output << value
          output
        end

        def read_varint(data, pos)
          shift = 0
          value = 0
          loop do
            byte = data.getbyte(pos)
            raise Error, "unexpected EOF while reading varint" unless byte

            pos += 1
            value |= (byte & 0x7f) << shift
            return [value, pos] if byte < 0x80

            shift += 7
          end
        end

        def common_prefix(left, right)
          size = [left.bytesize, right.bytesize].min
          index = 0
          index += 1 while index < size && left.getbyte(index) == right.getbyte(index)
          index
        end

        def encode_front_coded_strings(values, restart_interval = DEFAULT_RESTART_INTERVAL)
          output = [restart_interval].pack("S<")
          previous = +"".b
          values.each_with_index do |value, index|
            data = value.to_s.encode("UTF-8").b
            previous = +"".b if (index % restart_interval).zero?
            prefix = common_prefix(previous, data)
            suffix = data.byteslice(prefix..).to_s
            output << varint(prefix)
            output << varint(suffix.bytesize)
            output << suffix
            previous = data
          end
          output
        end

        def read_front_coded_string(data, pos, previous)
          prefix, pos = read_varint(data, pos)
          suffix_length, pos = read_varint(data, pos)
          if prefix > previous.bytesize
            raise Error, "front-coded string prefix exceeds previous string length"
          end
          if pos + suffix_length > data.bytesize
            raise Error, "front-coded string suffix exceeds available data"
          end

          suffix = data.byteslice(pos, suffix_length)
          pos += suffix_length
          value = (previous.byteslice(0, prefix).to_s.b + suffix.to_s.b).force_encoding(Encoding::UTF_8)
          [value, pos]
        end

        def decode_front_coded_strings(data, count)
          raise Error, "front-coded string sequence is missing restart interval" if data.bytesize < 2

          restart_interval = data.byteslice(0, 2).unpack1("S<")
          raise Error, "front-coded string sequence has zero restart interval" if restart_interval.zero?

          pos = 2
          previous = +"".b
          values = Array.new(count) do |index|
            previous = +"".b if (index % restart_interval).zero?
            value, pos = read_front_coded_string(data, pos, previous)
            previous = value.b
            value
          end
          raise Error, "front-coded string sequence has trailing bytes" unless pos == data.bytesize

          values
        end

        def encode_string_table(values, restart_interval = DEFAULT_RESTART_INTERVAL)
          sorted_values = values.map(&:to_s).sort
          [
            encode_front_coded_strings(sorted_values, restart_interval),
            sorted_values.each_with_index.to_h { |value, index| [value, index + 1] }
          ]
        end

        def pack_unsigned(values)
          width = values.empty? ? 0 : values.max.bit_length
          output = [width].pack("C")
          return output if width.zero?

          total_bits = width * values.length
          packed = "\0".b * ((total_bits + 7) / 8)
          bit_pos = 0
          values.each do |value|
            raise ArgumentError, "cannot pack negative integer" if value.negative?

            width.times do |bit_index|
              if (value & (1 << bit_index)) != 0
                absolute = bit_pos + bit_index
                byte_index = absolute / 8
                packed.setbyte(byte_index, packed.getbyte(byte_index) | (1 << (absolute % 8)))
              end
            end
            bit_pos += width
          end
          output << packed
        end

        def unpack_unsigned(data, count)
          width = data.getbyte(0)
          raise Error, "empty packed integer column" unless width

          raise Error, "packed integer column cannot decode a negative count" if count.negative?
          raise Error, "empty packed integer column has nonzero width" if count.zero? && !width.zero?

          payload_bytes = width.zero? ? 0 : ((width * count) + 7) / 8
          expected_bytes = 1 + payload_bytes
          raise Error, "packed integer column is truncated" if data.bytesize < expected_bytes
          raise Error, "packed integer column has trailing bytes" if data.bytesize > expected_bytes

          return Array.new(count, 0) if width.zero?

          values = []
          bit_pos = 0
          count.times do
            value = 0
            width.times do |bit_index|
              absolute = bit_pos + bit_index
              byte = data.getbyte(1 + (absolute / 8))
              value |= 1 << bit_index if (byte & (1 << (absolute % 8))) != 0
            end
            values << value
            bit_pos += width
          end
          values
        end

        def encode_varint_sequence(values)
          values.each_with_object(+"".b) { |value, output| output << varint(value) }
        end

        def read_fixed(data, pos, template)
          size = {"L<" => 4, "S<" => 2, "Q<" => 8}.fetch(template)
          bytes, pos = read_bytes(data, pos, size, "fixed #{template} value")
          [bytes.unpack1(template), pos]
        end

        def read_bytes(data, pos, size, context)
          raise Error, "#{context} length cannot be negative" if size.negative?

          bytes = data.byteslice(pos, size)
          raise Error, "#{context} is truncated" unless bytes && bytes.bytesize == size

          [bytes, pos + size]
        end

        def zstd_compress(data, level: 6)
          Zstd.compress(data, level: level)
        end

        def zstd_decompress(data)
          Zstd.decompress(data)
        end

        def read_header(path)
          read_metadata(path, sections: []).header
        end

        def read_metadata(path, sections: DEFAULT_SECTIONS)
          File.open(path, "rb") do |file|
            magic = file.read(MAGIC.bytesize)
            raise Error, "#{path}: invalid rbcdx magic" unless magic == MAGIC

            header_length_data = file.read(4)
            raise Error, "#{path}: missing rbcdx header length" unless header_length_data&.bytesize == 4

            header_length = header_length_data.unpack1("L<")
            header_data = file.read(header_length)
            raise Error, "#{path}: truncated rbcdx header" unless header_data&.bytesize == header_length

            header = JSON.parse(header_data)
            validate_metadata_header!(path, header)
            section_map = sections.to_h do |name|
              [name.to_s, metadata_section_bounds(path, header, name, file.size)]
            end
            FileMetadata.new(File.expand_path(path), header, header_length, file.size, section_map)
          rescue JSON::ParserError => error
            raise Error, "#{path}: malformed rbcdx header JSON: #{error.message}"
          end
        end

        def validate_metadata_header!(path, header)
          raise Error, "#{path}: rbcdx header must be a JSON object" unless header.is_a?(Hash)
          raise Error, "#{path}: unsupported rbcdx version #{header["version"]}" unless header["version"] == VERSION
          raise Error, "#{path}: unsupported rbcdx variant #{header["variant"]}" unless header["variant"] == VARIANT
        end

        def metadata_section_bounds(path, header, name, file_size)
          name = name.to_s
          offset = header.fetch("#{name}_offset")
          length = header.fetch("#{name}_length")
          unless offset.is_a?(Integer) && length.is_a?(Integer) && offset >= 0 && length >= 0
            raise Error, "#{path}: invalid rbcdx #{section_label(name)} section bounds"
          end

          bounds = SectionBounds.new(name, offset, length)
          raise Error, "#{path}: truncated rbcdx #{section_label(name)}" if bounds.finish > file_size

          bounds
        rescue KeyError
          raise Error, "#{path}: missing rbcdx #{section_label(name)} section bounds"
        end

        def section_label(name)
          SECTION_LABELS.fetch(name.to_s, name.to_s)
        end

        def base32_encode(bytes)
          buffer = 0
          bits = 0
          output = +""
          bytes.each_byte do |byte|
            buffer = (buffer << 8) | byte
            bits += 8
            while bits >= 5
              bits -= 5
              output << BASE32_ALPHABET[(buffer >> bits) & 31]
            end
          end
          output << BASE32_ALPHABET[(buffer << (5 - bits)) & 31] if bits.positive?
          output
        end

        def base32_decode(value)
          input = value.to_s.upcase
          raise ArgumentError, "base32 value must be unpadded" if input.include?("=")

          buffer = 0
          bits = 0
          output = +"".b
          input.each_char do |char|
            index = BASE32_ALPHABET.index(char)
            raise ArgumentError, "invalid base32 character #{char.inspect}" unless index

            buffer = (buffer << 5) | index
            bits += 5
            while bits >= 8
              bits -= 8
              output << ((buffer >> bits) & 0xff)
            end
          end
          if bits.positive? && (buffer & ((1 << bits) - 1)) != 0
            raise ArgumentError, "nonzero trailing base32 bits"
          end
          output
        end

        def parse_cdxj_line(source_path, line_number, line)
          urlkey, timestamp, object = read_cdxj_line(source_path, line_number, line)
          validate_cdxj_object(source_path, line_number, urlkey, object)
          [urlkey, timestamp, object]
        end

        def read_cdxj_line(source_path, line_number, line)
          stripped = line.to_s.chomp
          if stripped.start_with?("{")
            object = JSON.parse(stripped)
            urlkey = object.delete("urlkey")
            timestamp = object.delete("timestamp")
          else
            urlkey, timestamp, payload = stripped.split(" ", 3)
            object = JSON.parse(payload)
          end
          [urlkey, timestamp, object]
        rescue JSON::ParserError, NoMethodError, TypeError => error
          raise EncodeError.new(
            source_path: source_path,
            line_number: line_number,
            urlkey: nil,
            field: "line",
            value: stripped,
            reason: "malformed CDXJ line: #{error.message}"
          )
        end

        def validate_cdxj_object(source_path, line_number, urlkey, object)
          REQUIRED_FIELDS.each do |field|
            next if object.key?(field)

            raise EncodeError.new(source_path: source_path, line_number: line_number, urlkey: urlkey, field: field, value: nil, reason: "missing required field")
          end

          unknown = object.keys - KNOWN_FIELDS
          return if unknown.empty?

          field = unknown.min
          raise EncodeError.new(
            source_path: source_path,
            line_number: line_number,
            urlkey: urlkey,
            field: field,
            value: object[field],
            reason: "unknown JSON field and extras are disabled",
            suggestion: "keep this shard as CDXJ or add an extras column in a later format"
          )
        end

        def parse_timestamp(source_path, line_number, urlkey, value)
          match = /\A(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})\z/.match(value.to_s)
          raise ArgumentError unless match

          Time.utc(*match.captures.map(&:to_i)).to_i
        rescue ArgumentError => error
          raise EncodeError.new(source_path: source_path, line_number: line_number, urlkey: urlkey, field: "timestamp", value: value, reason: "cannot parse CDX UTC timestamp"), cause: error
        end

        def parse_nonnegative_integer(source_path, line_number, urlkey, field, value)
          string = value.to_s
          raise ArgumentError unless string.match?(/\A\d+\z/)

          string.to_i
        rescue ArgumentError => error
          raise EncodeError.new(source_path: source_path, line_number: line_number, urlkey: urlkey, field: field, value: value, reason: "not a nonnegative integer"), cause: error
        end

        def parse_url(source_path, line_number, urlkey, value)
          string = value.to_s
          if string.start_with?("https://")
            suffix = string.delete_prefix("https://")
            https = true
          elsif string.start_with?("http://")
            suffix = string.delete_prefix("http://")
            https = false
          else
            raise EncodeError.new(
              source_path: source_path,
              line_number: line_number,
              urlkey: urlkey,
              field: "url",
              value: value,
              reason: "rbcdx only encodes http and https schemes",
              suggestion: "keep this shard as CDXJ or add a generic URL fallback"
            )
          end

          uri = URI.parse(string)
          [suffix, https, !uri.port.nil? && uri.port != uri.default_port, !!(uri.query || uri.fragment)]
        rescue URI::InvalidURIError => error
          raise EncodeError.new(source_path: source_path, line_number: line_number, urlkey: urlkey, field: "url", value: value, reason: "cannot parse URL"), cause: error
        end

        def parse_digest(source_path, line_number, urlkey, value)
          return "\0".b * 20 if value.nil? || value.to_s.empty?

          string = value.to_s
          unless string == string.upcase && !string.include?("=")
            raise EncodeError.new(source_path: source_path, line_number: line_number, urlkey: urlkey, field: "digest", value: value, reason: "not canonical unpadded base32 SHA-1")
          end

          decoded = base32_decode(string)
          unless decoded.bytesize == 20
            raise EncodeError.new(source_path: source_path, line_number: line_number, urlkey: urlkey, field: "digest", value: value, reason: "decoded digest is not 20 bytes")
          end
          unless base32_encode(decoded) == string
            raise EncodeError.new(source_path: source_path, line_number: line_number, urlkey: urlkey, field: "digest", value: value, reason: "not canonical unpadded base32 SHA-1")
          end
          decoded
        rescue ArgumentError => error
          raise EncodeError.new(source_path: source_path, line_number: line_number, urlkey: urlkey, field: "digest", value: value, reason: "not valid base32 SHA-1"), cause: error
        end

        def parse_filename(source_path, line_number, urlkey, value, crawl_id_state)
          match = FILENAME_PATTERN.match(value)
          return unless match

          crawl_id, segment, kind, warc_time_pair, shard = match.captures
          if crawl_id_state[:crawl_id].nil?
            crawl_id_state[:crawl_id] = crawl_id
          elsif crawl_id_state[:crawl_id] != crawl_id
            raise EncodeError.new(
              source_path: source_path,
              line_number: line_number,
              urlkey: urlkey,
              field: "filename",
              value: value,
              reason: "mixed crawl ids are not supported: #{crawl_id_state[:crawl_id]} and #{crawl_id}"
            )
          end
          [crawl_id, segment, kind, warc_time_pair, shard.to_i]
        end

        def collect_value(tables, name, value)
          return if value.nil? || value == ""

          tables.fetch(name) << value.to_s
        end

        def id_for(maps, name, value)
          return 0 if value.nil? || value == ""

          maps.fetch(name).fetch(value.to_s)
        end

        def build_record(source_path, line_number, line, maps, crawl_id_state)
          urlkey, timestamp, object = parse_cdxj_line(source_path, line_number, line)
          build_record_from_parts(source_path, line_number, urlkey, timestamp, object, maps, crawl_id_state)
        end

        def build_record_from_parts(source_path, line_number, urlkey, timestamp, object, maps, crawl_id_state)
          validate_cdxj_object(source_path, line_number, urlkey, object)
          url_without_scheme, https, has_port, has_query_or_fragment = parse_url(source_path, line_number, urlkey, object.fetch("url"))
          filename = object.fetch("filename").to_s
          parsed_filename = parse_filename(source_path, line_number, urlkey, filename, crawl_id_state)
          filename_ref = if parsed_filename
            _crawl_id, segment, kind, warc_time_pair, shard = parsed_filename
            FilenameRef.new(
              kind: KIND_TO_ID.fetch(kind),
              segment_id: id_for(maps, "segment", segment),
              warc_time_pair_id: id_for(maps, "warc-time-pair", warc_time_pair),
              shard_id: shard,
              fallback_filename_id: 0
            )
          else
            FilenameRef.new(
              kind: 3,
              segment_id: 0,
              warc_time_pair_id: 0,
              shard_id: 0,
              fallback_filename_id: id_for(maps, "fallback-filename", filename)
            )
          end

          language_ids = object.fetch("languages", nil).to_s.split(",").filter_map do |language|
            language = language.strip
            id_for(maps, "language", language) unless language.empty?
          end

          Record.new(
            source_path: source_path,
            line_number: line_number,
            urlkey: urlkey,
            timestamp_epoch: parse_timestamp(source_path, line_number, urlkey, timestamp),
            url_without_scheme: url_without_scheme,
            https: https,
            has_port: has_port,
            has_query_or_fragment: has_query_or_fragment,
            status_id: id_for(maps, "status", object.fetch("status", nil)),
            mime_id: id_for(maps, "mime", object.fetch("mime", nil)),
            mime_detected_id: id_for(maps, "mime-detected", object.fetch("mime-detected", nil)),
            digest: parse_digest(source_path, line_number, urlkey, object.fetch("digest", nil)),
            length: parse_nonnegative_integer(source_path, line_number, urlkey, "length", object.fetch("length")),
            offset: parse_nonnegative_integer(source_path, line_number, urlkey, "offset", object.fetch("offset")),
            filename_ref: filename_ref,
            charset_id: id_for(maps, "charset", object.fetch("charset", nil)),
            language_ids: language_ids,
            redirect: object.fetch("redirect", nil).to_s,
            truncated_id: id_for(maps, "truncated", object.fetch("truncated", nil))
          )
        end

        def encode_dictionaries(tables)
          maps = {}
          encoded_tables = TABLE_NAMES.map do |name|
            encoded, mapping = encode_string_table(tables.fetch(name))
            maps[name] = mapping
            [name, mapping.length, encoded]
          end

          output = [encoded_tables.length].pack("L<")
          encoded_tables.each do |name, count, data|
            name_bytes = name.b
            output << [name_bytes.bytesize].pack("S<")
            output << name_bytes
            output << [count, data.bytesize].pack("L<Q<")
            output << data
          end
          [output, maps]
        end

        def decode_dictionaries(data)
          pos = 0
          table_count, pos = read_fixed(data, pos, "L<")
          tables = {}
          table_count.times do
            name_length, pos = read_fixed(data, pos, "S<")
            name_bytes, pos = read_bytes(data, pos, name_length, "dictionary table name")
            name = name_bytes.force_encoding(Encoding::UTF_8)
            count, pos = read_fixed(data, pos, "L<")
            length, pos = read_fixed(data, pos, "Q<")
            table_data, pos = read_bytes(data, pos, length, "dictionary table data")
            tables[name] = decode_front_coded_strings(table_data, count)
          end
          raise Error, "dictionary section has trailing bytes" unless pos == data.bytesize

          tables
        end

        def encode_redirects(records)
          records.each_with_object(+"".b) do |record, output|
            next if record.redirect.empty?

            data = record.redirect.b
            output << varint(data.bytesize)
            output << data
          end
        end

        def encode_languages(records)
          records.each_with_object(+"".b) do |record, output|
            next if record.language_ids.empty?

            output << varint(record.language_ids.length)
            record.language_ids.each { |id| output << varint(id) }
          end
        end

        def encode_payload(magic, records, base_timestamp, column_names, columns)
          offsets = []
          cursor = 0
          column_names.each do |name|
            offsets << cursor
            cursor += columns.fetch(name).bytesize
          end
          offsets << cursor

          output = magic.b.dup
          output << [records.length, base_timestamp, column_names.length, 0].pack("L<Q<S<S<")
          offsets.each { |offset| output << [offset].pack("L<") }
          column_names.each { |name| output << columns.fetch(name) }
          output
        end

        def decode_payload(data, magic, column_names)
          raise Error, "invalid block magic" unless data.start_with?(magic)

          pos = magic.bytesize
          raise Error, "block payload header is truncated" if data.bytesize < pos + 16

          record_count, base_timestamp, column_count, = data.byteslice(pos, 16).unpack("L<Q<S<S<")
          pos += 16
          raise Error, "unsupported column count #{column_count}" unless column_count == column_names.length
          raise Error, "block payload offset table is truncated" if data.bytesize < pos + (4 * (column_count + 1))

          offsets = data.byteslice(pos, 4 * (column_count + 1)).unpack("L<#{column_count + 1}")
          pos += 4 * (column_count + 1)
          column_data = data.byteslice(pos..)
          validate_column_offsets!(offsets, column_data.bytesize)
          columns = {}
          column_names.each_with_index do |name, index|
            columns[name] = (column_data.byteslice(offsets[index], offsets[index + 1] - offsets[index]) || +"").b
          end
          [record_count, base_timestamp, columns]
        end

        def validate_column_offsets!(offsets, column_data_length)
          previous = 0
          offsets.each do |offset|
            raise Error, "block payload column offsets are not monotonic" if offset < previous
            raise Error, "block payload column offset exceeds column data length" if offset > column_data_length

            previous = offset
          end
          raise Error, "block payload column offsets do not consume column data" unless offsets.last == column_data_length
        end

        def build_column_values(records, restart_interval)
          base_timestamp = records.map(&:timestamp_epoch).min
          record_flags = +"".b
          status_flags = +"".b
          mime_flags = +"".b
          mime_detected_flags = +"".b
          digests = +"".b
          status_ext = []
          mime_ext = []
          mime_detected_ext = []

          records.each do |record|
            flags = 0
            flags |= RECORD_FLAG_HAS_PORT if record.has_port
            flags |= RECORD_FLAG_HAS_QUERY_OR_FRAGMENT if record.has_query_or_fragment
            flags |= RECORD_FLAG_FALLBACK_FILENAME if record.filename_ref.kind == 3
            record_flags << flags

            status_code = (record.status_id > 62) ? 63 : record.status_id
            status_ext << record.status_id if record.status_id > 62
            status_code |= STATUS_FLAG_HTTPS if record.https
            status_code |= STATUS_FLAG_HAS_REDIRECT unless record.redirect.empty?
            status_flags << status_code

            mime_code = (record.mime_id > 126) ? 127 : record.mime_id
            mime_ext << record.mime_id if record.mime_id > 126
            mime_code |= MIME_FLAG_HAS_CHARSET if record.charset_id.positive?
            mime_flags << mime_code

            detected_code = (record.mime_detected_id > 62) ? 63 : record.mime_detected_id
            mime_detected_ext << record.mime_detected_id if record.mime_detected_id > 62
            detected_code |= MIME_DETECTED_FLAG_HAS_LANGUAGES unless record.language_ids.empty?
            detected_code |= MIME_DETECTED_FLAG_HAS_TRUNCATED if record.truncated_id.positive?
            mime_detected_flags << detected_code
            digests << record.digest
          end

          [
            base_timestamp,
            {
              "record_flags" => record_flags,
              "status_and_hot_flags" => status_flags,
              "mime_and_flags" => mime_flags,
              "mime_detected_and_flags" => mime_detected_flags,
              "digest" => digests,
              "urlkey_front_codes" => encode_front_coded_strings(records.map(&:urlkey), restart_interval),
              "url_without_scheme_front_codes" => encode_front_coded_strings(records.map(&:url_without_scheme), restart_interval),
              "timestamp_deltas" => pack_unsigned(records.map { |record| record.timestamp_epoch - base_timestamp }),
              "lengths" => pack_unsigned(records.map(&:length)),
              "offsets" => pack_unsigned(records.map(&:offset)),
              "filename_kind" => records.each_with_object(+"".b) { |record, output| output << record.filename_ref.kind },
              "segment_ids" => pack_unsigned(records.map { |record| record.filename_ref.segment_id }),
              "warc_time_pair_ids" => pack_unsigned(records.map { |record| record.filename_ref.warc_time_pair_id }),
              "shard_ids" => pack_unsigned(records.map { |record| record.filename_ref.shard_id }),
              "fallback_filename_ids" => pack_unsigned(records.map { |record| record.filename_ref.fallback_filename_id }),
              "status_extended_ids" => encode_varint_sequence(status_ext),
              "mime_extended_ids" => encode_varint_sequence(mime_ext),
              "mime_detected_extended_ids" => encode_varint_sequence(mime_detected_ext),
              "redirects" => encode_redirects(records),
              "charset_ids" => encode_varint_sequence(records.filter_map { |record| record.charset_id if record.charset_id.positive? }),
              "languages" => encode_languages(records),
              "truncated_ids" => encode_varint_sequence(records.filter_map { |record| record.truncated_id if record.truncated_id.positive? }),
              "extras" => +"".b
            }
          ]
        end

        def encode_split_block(records, zstd_level:, restart_interval:)
          base_timestamp, columns = build_column_values(records, restart_interval)
          hot_uncompressed = encode_payload(HOT_BLOCK_MAGIC, records, base_timestamp, HOT_COLUMN_NAMES, columns)
          cold_uncompressed = encode_payload(COLD_BLOCK_MAGIC, records, base_timestamp, COLD_COLUMN_NAMES, columns)
          [
            hot_uncompressed,
            zstd_compress(hot_uncompressed, level: zstd_level),
            cold_uncompressed,
            zstd_compress(cold_uncompressed, level: zstd_level),
            base_timestamp
          ]
        end

        def encode_directory(blocks, restart_interval)
          output = [blocks.length, restart_interval].pack("L<S<")
          previous_first = +"".b
          previous_last = +"".b
          blocks.each_with_index do |block, index|
            previous_first = +"".b if (index % restart_interval).zero?
            previous_last = +"".b if (index % restart_interval).zero?
            first = block.first_urlkey.b
            last = block.last_urlkey.b
            [[first, previous_first], [last, previous_last]].each do |value, previous|
              prefix = common_prefix(previous, value)
              suffix = value.byteslice(prefix..).to_s
              output << varint(prefix)
              output << varint(suffix.bytesize)
              output << suffix
            end
            previous_first = first
            previous_last = last
            output << [
              block.record_count,
              block.hot_compressed_offset,
              block.hot_compressed_length,
              block.hot_uncompressed_length,
              block.cold_compressed_offset,
              block.cold_compressed_length,
              block.cold_uncompressed_length,
              block.block_base_timestamp
            ].pack("Q<Q<Q<Q<Q<Q<Q<Q<")
          end
          output
        end

        def decode_directory(data)
          pos = 0
          block_count, pos = read_fixed(data, pos, "L<")
          restart_interval, pos = read_fixed(data, pos, "S<")
          raise Error, "directory has zero restart interval" if restart_interval.zero?

          previous_first = +"".b
          previous_last = +"".b
          blocks = Array.new(block_count) do |index|
            if (index % restart_interval).zero?
              previous_first = +"".b
              previous_last = +"".b
            end
            first, pos = read_front_coded_string(data, pos, previous_first)
            last, pos = read_front_coded_string(data, pos, previous_last)
            previous_first = first.b
            previous_last = last.b
            block_data, pos = read_bytes(data, pos, 64, "directory block record")
            values = block_data.unpack("Q<Q<Q<Q<Q<Q<Q<Q<")
            BlockEntry.new(
              first_urlkey: first,
              last_urlkey: last,
              record_count: values[0],
              hot_compressed_offset: values[1],
              hot_compressed_length: values[2],
              hot_uncompressed_length: values[3],
              cold_compressed_offset: values[4],
              cold_compressed_length: values[5],
              cold_uncompressed_length: values[6],
              block_base_timestamp: values[7]
            )
          end
          raise Error, "directory section has trailing bytes" unless pos == data.bytesize

          blocks
        end

        def write_file(output_path, dict_data:, directory_data:, hot_data:, cold_data:, header:)
          header = header.dup
          fixed_prefix_length = MAGIC.bytesize + 4
          hot_data_length = section_bytesize(hot_data)
          cold_data_length = section_bytesize(cold_data)
          converged = false
          10.times do
            header_json = JSON.generate(header.sort.to_h)
            dict_offset = fixed_prefix_length + header_json.bytesize
            directory_offset = dict_offset + dict_data.bytesize
            hot_blocks_offset = directory_offset + directory_data.bytesize
            cold_blocks_offset = hot_blocks_offset + hot_data_length
            updated = header.merge(
              "dict_offset" => dict_offset,
              "dict_length" => dict_data.bytesize,
              "directory_offset" => directory_offset,
              "directory_length" => directory_data.bytesize,
              "hot_blocks_offset" => hot_blocks_offset,
              "hot_blocks_length" => hot_data_length,
              "cold_blocks_offset" => cold_blocks_offset,
              "cold_blocks_length" => cold_data_length
            )
            if updated == header
              converged = true
              break
            end

            header = updated
          end
          raise Error, "rbcdx header offsets did not converge" unless converged

          header_json = JSON.generate(header.sort.to_h)
          FileUtils.mkdir_p(File.dirname(output_path))
          File.open(output_path, "wb") do |file|
            file.write(MAGIC)
            file.write([header_json.bytesize].pack("L<"))
            file.write(header_json)
            file.write(dict_data)
            file.write(directory_data)
            write_section(file, hot_data)
            write_section(file, cold_data)
          end
          header
        end

        def section_bytesize(section)
          section.bytesize
        end

        def write_section(file, section)
          if section.respond_to?(:copy_to)
            section.copy_to(file)
          else
            file.write(section)
          end
        end
        private_class_method :section_bytesize, :write_section
      end
    end
  end
end

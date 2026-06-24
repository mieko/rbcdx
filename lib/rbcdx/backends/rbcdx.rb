module CDX
  module Backends
    class Rbcdx
      INDEX_FILE_PATTERN = /\.rbcdx[0-9A-Za-z]*\z/

      attr_reader :paths

      def self.index_file?(path)
        File.basename(path).match?(INDEX_FILE_PATTERN)
      end

      def self.write(input_path, output_path, **options)
        Repacker.repack(input_path, output_path, **options)
      end

      def initialize(paths, parser_factory:)
        @paths = paths
        @manifests = RbcdxManifest.find_all(@paths)
        @reader_by_path = {}
        @paths.each { |path| reader_for(path) } if @manifests.empty?
      end

      def each_capture(matcher: nil)
        return enum_for(:each_capture, matcher: matcher) unless block_given?

        if matcher && @manifests.any?
          each_capture_with_manifests(matcher) { |capture| yield capture }
          return
        end

        paths.each do |path|
          reader = reader_for(path)
          matcher ? each_matching_capture(reader, matcher) { |capture| yield capture } : reader.each_capture { |capture| yield capture }
        end
      end

      private

      def each_capture_with_manifests(matcher)
        specs = query_specs(matcher)
        manifest_by_path = manifests_by_path
        candidates = manifest_candidate_paths(specs)

        paths.each do |path|
          next if manifest_by_path.key?(path) && !candidates.include?(path)

          each_matching_capture(reader_for(path), matcher, specs) { |capture| yield capture }
        end
      end

      def manifests_by_path
        @manifests.each_with_object({}) do |manifest, by_path|
          manifest.paths.each { |path| by_path[path] = manifest }
        end
      end

      def manifest_candidate_paths(specs)
        @manifests.each_with_object({}) do |manifest, candidates|
          specs.each do |urlkey, prefix|
            manifest.candidate_paths(urlkey, prefix: prefix).each do |path|
              candidates[path] = true
            end
          end
        end
      end

      def reader_for(path)
        @reader_by_path[path] ||= Reader.new(path)
      end

      def each_matching_capture(reader, matcher, specs = query_specs(matcher))
        specs.each do |urlkey, prefix|
          reader.captures(urlkey, prefix: prefix) do |capture|
            yield capture if matcher.match?(capture)
          end
        end
      end

      def query_specs(matcher)
        pattern = matcher.pattern.to_s
        case matcher.match
        when :domain
          host = Surt.parse_url(pattern.sub(/\A\*\./, ""))[:host]
          return [] unless host

          domain_surt = Surt.host_to_surt(host)
          [["#{domain_surt})", true], ["#{domain_surt},", true]]
        when :host
          host = Surt.parse_url(pattern)[:host]
          return [] unless host

          [["#{Surt.host_to_surt(host)})", true]]
        when :prefix
          [[Surt.from_url(pattern.sub(/\*\z/, "")), true]]
        else
          [[Surt.from_url(pattern), false]]
        end
      end

      class Reader
        attr_reader :path, :header, :tables, :blocks

        def initialize(path)
          @path = File.expand_path(path)
          @header = nil
          @tables = nil
          @blocks = nil
          @block_starts = nil
          @section_bounds = nil
          read_metadata
        end

        def each_capture
          return enum_for(:each_capture) unless block_given?

          blocks.each do |entry|
            block = read_hot_block(entry)
            block.count.times do |index|
              yield Capture.new(block, index, source_path: path)
            end
          end
        end

        def captures(urlkey, prefix: false, limit: nil)
          return enum_for(:captures, urlkey, prefix: prefix, limit: limit) unless block_given?

          query = urlkey.to_s
          emitted = 0
          candidate_blocks(query, prefix: prefix).each do |entry|
            block = read_hot_block(entry)
            block.urlkeys.each_with_index do |candidate, index|
              next unless prefix ? candidate.start_with?(query) : candidate == query

              yield Capture.new(block, index, source_path: path)
              emitted += 1
              break if limit && emitted >= limit
            end
            break if limit && emitted >= limit
          end
        end

        def table_value(name, id)
          return nil if id.nil? || id == 0

          tables.fetch(name).fetch(id - 1)
        end

        def reconstruct_filename(kind, segment_id, warc_time_pair_id, shard_id, fallback_filename_id)
          if kind == 3
            return table_value("fallback-filename", fallback_filename_id)
          end

          segment = table_value("segment", segment_id)
          warc_time_pair = table_value("warc-time-pair", warc_time_pair_id)
          "crawl-data/#{header.fetch("crawl_id")}/segments/#{segment}/#{RbcdxFormat::ID_TO_KIND.fetch(kind)}/#{warc_time_pair}-#{format("%05d", shard_id)}.warc.gz"
        end

        def read_cold_columns(entry)
          offset = block_offset("cold_blocks", entry.cold_compressed_offset, entry.cold_compressed_length)
          compressed = read_at(offset, entry.cold_compressed_length)
          data = decompress_block("cold_blocks", compressed)
          raise Error, "#{path}: cold block uncompressed length mismatch" unless data.bytesize == entry.cold_uncompressed_length

          count, base_timestamp, columns = RbcdxFormat.decode_payload(data, RbcdxFormat::COLD_BLOCK_MAGIC, RbcdxFormat::COLD_COLUMN_NAMES)
          raise Error, "#{path}: cold block record count mismatch" unless count == entry.record_count
          raise Error, "#{path}: cold block timestamp base mismatch" unless base_timestamp == entry.block_base_timestamp

          columns
        end

        private

        def read_metadata
          metadata = RbcdxFormat.read_metadata(path)
          @header = metadata.header
          @section_bounds = metadata.sections
          @tables = RbcdxFormat.decode_dictionaries(metadata.read_section("dict"))
          @blocks = RbcdxFormat.decode_directory(metadata.read_section("directory"))
          @block_starts = blocks.map(&:first_urlkey)
          validate_directory
        end

        def section_label(name)
          RbcdxFormat.section_label(name)
        end

        def block_offset(section_name, relative_offset, relative_length)
          section = @section_bounds.fetch(section_name)
          unless relative_offset.is_a?(Integer) && relative_length.is_a?(Integer) && relative_offset >= 0 && relative_length >= 0
            raise Error, "#{path}: invalid rbcdx #{section_label(section_name)} block bounds"
          end

          finish = relative_offset + relative_length
          if finish > section.length
            raise Error, "#{path}: rbcdx #{section_label(section_name)} block exceeds section bounds"
          end

          section.offset + relative_offset
        end

        def validate_directory
          previous_last = nil
          blocks.each_with_index do |block, index|
            raise Error, "#{path}: block #{index} has inverted key range" if block.first_urlkey > block.last_urlkey
            raise Error, "#{path}: block #{index} overlaps prior key range" if previous_last && block.first_urlkey < previous_last

            previous_last = block.last_urlkey
          end
        end

        def candidate_blocks(query, prefix:)
          end_key = prefix ? prefix_successor(query) : nil
          index = [upper_bound(@block_starts, query) - 1, 0].max
          index -= 1 while index.positive? && block_overlaps_query?(blocks[index - 1], query, prefix: prefix, end_key: end_key)

          candidates = []

          while index < blocks.length
            block = blocks[index]
            if block_overlaps_query?(block, query, prefix: prefix, end_key: end_key)
              candidates << block
            elsif block_after_query?(block, query, prefix: prefix, end_key: end_key)
              break
            end
            index += 1
          end

          candidates
        end

        def block_overlaps_query?(block, query, prefix:, end_key:)
          if prefix
            block.last_urlkey >= query && (end_key.nil? || block.first_urlkey < end_key)
          else
            query.between?(block.first_urlkey, block.last_urlkey)
          end
        end

        def block_after_query?(block, query, prefix:, end_key:)
          if prefix
            end_key && block.first_urlkey >= end_key
          else
            block.first_urlkey > query
          end
        end

        def prefix_successor(prefix)
          bytes = prefix.b.bytes
          index = bytes.length - 1
          index -= 1 while index >= 0 && bytes[index] == 255
          return if index.negative?

          bytes[index] += 1
          bytes[0..index].pack("C*")
        end

        def upper_bound(values, query)
          low = 0
          high = values.length
          while low < high
            mid = (low + high) / 2
            if values[mid] <= query
              low = mid + 1
            else
              high = mid
            end
          end
          low
        end

        def read_hot_block(entry)
          offset = block_offset("hot_blocks", entry.hot_compressed_offset, entry.hot_compressed_length)
          compressed = read_at(offset, entry.hot_compressed_length)
          data = decompress_block("hot_blocks", compressed)
          raise Error, "#{path}: hot block uncompressed length mismatch" unless data.bytesize == entry.hot_uncompressed_length

          count, base_timestamp, columns = RbcdxFormat.decode_payload(data, RbcdxFormat::HOT_BLOCK_MAGIC, RbcdxFormat::HOT_COLUMN_NAMES)
          raise Error, "#{path}: hot block record count mismatch" unless count == entry.record_count
          raise Error, "#{path}: hot block timestamp base mismatch" unless base_timestamp == entry.block_base_timestamp

          BlockView.new(self, entry, count, base_timestamp, columns)
        end

        def decompress_block(section_name, compressed)
          RbcdxFormat.zstd_decompress(compressed)
        rescue Error
          raise
        rescue => error
          raise Error, "#{path}: rbcdx #{section_label(section_name)} block decompression failed: #{error.message}"
        end

        def read_at(offset, length)
          File.open(path, "rb") do |file|
            file.seek(offset)
            data = file.read(length)
            raise Error, "#{path}: short read at #{offset}" unless data&.bytesize == length

            data
          end
        rescue SystemCallError => error
          raise Error, "#{path}: short read at #{offset}: #{error.message}"
        end
      end

      class BlockView
        attr_reader :reader, :entry, :count, :base_timestamp, :hot_columns

        def initialize(reader, entry, count, base_timestamp, hot_columns)
          @reader = reader
          @entry = entry
          @count = count
          @base_timestamp = base_timestamp
          @hot_columns = hot_columns
        end

        def cold_columns
          @cold_columns ||= reader.read_cold_columns(entry)
        end

        def urlkeys
          @urlkeys ||= RbcdxFormat.decode_front_coded_strings(hot_columns.fetch("urlkey_front_codes"), count)
        end

        def url_suffixes
          @url_suffixes ||= RbcdxFormat.decode_front_coded_strings(hot_columns.fetch("url_without_scheme_front_codes"), count)
        end

        def timestamp_epochs
          @timestamp_epochs ||= RbcdxFormat.unpack_unsigned(hot_columns.fetch("timestamp_deltas"), count).map { |delta| base_timestamp + delta }
        end

        def lengths
          @lengths ||= RbcdxFormat.unpack_unsigned(hot_columns.fetch("lengths"), count)
        end

        def offsets
          @offsets ||= RbcdxFormat.unpack_unsigned(hot_columns.fetch("offsets"), count)
        end

        def status_flags
          @status_flags ||= hot_columns.fetch("status_and_hot_flags").bytes
        end

        def mime_flags
          @mime_flags ||= hot_columns.fetch("mime_and_flags").bytes
        end

        def mime_detected_flags
          @mime_detected_flags ||= hot_columns.fetch("mime_detected_and_flags").bytes
        end

        def status_ids
          @status_ids ||= decode_extended_ids(status_flags, 0x3f, 63, hot_columns.fetch("status_extended_ids"))
        end

        def mime_ids
          @mime_ids ||= decode_extended_ids(mime_flags, 0x7f, 127, hot_columns.fetch("mime_extended_ids"))
        end

        def mime_detected_ids
          @mime_detected_ids ||= decode_extended_ids(mime_detected_flags, 0x3f, 63, hot_columns.fetch("mime_detected_extended_ids"))
        end

        def filename_kinds
          @filename_kinds ||= hot_columns.fetch("filename_kind").bytes
        end

        def segment_ids
          @segment_ids ||= RbcdxFormat.unpack_unsigned(hot_columns.fetch("segment_ids"), count)
        end

        def warc_time_pair_ids
          @warc_time_pair_ids ||= RbcdxFormat.unpack_unsigned(hot_columns.fetch("warc_time_pair_ids"), count)
        end

        def shard_ids
          @shard_ids ||= RbcdxFormat.unpack_unsigned(hot_columns.fetch("shard_ids"), count)
        end

        def fallback_filename_ids
          @fallback_filename_ids ||= RbcdxFormat.unpack_unsigned(hot_columns.fetch("fallback_filename_ids"), count)
        end

        def digest_bytes(index)
          cold_columns.fetch("digest").byteslice(index * 20, 20)
        end

        def charset_ids
          @charset_ids ||= decode_sparse_varints(mime_flags, RbcdxFormat::MIME_FLAG_HAS_CHARSET, cold_columns.fetch("charset_ids"))
        end

        def language_ids
          @language_ids ||= decode_sparse_varint_lists(mime_detected_flags, RbcdxFormat::MIME_DETECTED_FLAG_HAS_LANGUAGES, cold_columns.fetch("languages"))
        end

        def truncated_ids
          @truncated_ids ||= decode_sparse_varints(mime_detected_flags, RbcdxFormat::MIME_DETECTED_FLAG_HAS_TRUNCATED, cold_columns.fetch("truncated_ids"))
        end

        def redirects
          @redirects ||= decode_sparse_strings(status_flags, RbcdxFormat::STATUS_FLAG_HAS_REDIRECT, cold_columns.fetch("redirects"))
        end

        private

        def decode_extended_ids(flags, mask, sentinel, data)
          ids = []
          pos = 0
          flags.each do |flag|
            id = flag & mask
            if id == sentinel
              id, pos = RbcdxFormat.read_varint(data, pos)
            end
            ids << id
          end
          assert_consumed!(data, pos, "extended id stream")
          ids
        end

        def decode_sparse_varints(flags, bit, data)
          values = Array.new(count)
          pos = 0
          flags.each_with_index do |flag, index|
            next unless (flag & bit) != 0

            values[index], pos = RbcdxFormat.read_varint(data, pos)
          end
          assert_consumed!(data, pos, "sparse varint stream")
          values
        end

        def decode_sparse_varint_lists(flags, bit, data)
          values = Array.new(count)
          pos = 0
          flags.each_with_index do |flag, index|
            next unless (flag & bit) != 0

            item_count, pos = RbcdxFormat.read_varint(data, pos)
            values[index] = Array.new(item_count) do
              value, next_pos = RbcdxFormat.read_varint(data, pos)
              pos = next_pos
              value
            end
          end
          assert_consumed!(data, pos, "sparse varint-list stream")
          values
        end

        def decode_sparse_strings(flags, bit, data)
          values = Array.new(count)
          pos = 0
          flags.each_with_index do |flag, index|
            next unless (flag & bit) != 0

            length, pos = RbcdxFormat.read_varint(data, pos)
            raise Error, "sparse string exceeds available data" if pos + length > data.bytesize

            values[index] = data.byteslice(pos, length).force_encoding(Encoding::UTF_8)
            pos += length
          end
          assert_consumed!(data, pos, "sparse string stream")
          values
        end

        def assert_consumed!(data, pos, label)
          raise Error, "#{label} has trailing bytes" unless pos == data.bytesize
        end
      end

      class Capture < CDX::Capture
        FIELD_NAMES = %w[
          urlkey
          timestamp
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

        attr_reader :block, :index

        def initialize(block, index, source_path:)
          @block = block
          @index = index
          super({}, source_path: source_path, line_number: nil, fields: FIELD_NAMES)
        end

        def to_h
          FIELD_NAMES.each_with_object({}) do |field, result|
            value = self.field(field)
            result[field] = value unless value.nil?
          end
        end

        def with_fields(*fields)
          data = self.class.normalize_field_names(fields).each_with_object({}) do |field, result|
            value = self.field(field)
            result[field] = value unless value.nil?
          end
          CDX::Capture.new(data, source_path: source_path, line_number: line_number, fields: data.keys)
        end

        def urlkey
          block.urlkeys[index]
        end

        def timestamp
          Time.at(block.timestamp_epochs[index]).utc.strftime("%Y%m%d%H%M%S")
        end

        def url
          "#{scheme}://#{block.url_suffixes[index]}"
        end

        def scheme
          https? ? "https" : "http"
        end

        def https?
          (block.status_flags[index] & RbcdxFormat::STATUS_FLAG_HTTPS) != 0
        end

        def status
          block.reader.table_value("status", block.status_ids[index])
        end

        def mime
          block.reader.table_value("mime", block.mime_ids[index])
        end

        def mime_detected
          block.reader.table_value("mime-detected", block.mime_detected_ids[index])
        end

        def digest
          bytes = block.digest_bytes(index)
          return nil if bytes.nil? || bytes == ("\0" * 20).b

          RbcdxFormat.base32_encode(bytes)
        end

        def length
          block.lengths[index].to_s
        end

        def offset
          block.offsets[index].to_s
        end

        def filename
          block.reader.reconstruct_filename(
            block.filename_kinds[index],
            block.segment_ids[index],
            block.warc_time_pair_ids[index],
            block.shard_ids[index],
            block.fallback_filename_ids[index]
          )
        end

        def charset
          block.reader.table_value("charset", block.charset_ids[index])
        end

        def languages
          ids = block.language_ids[index]
          return nil if ids.nil? || ids.empty?

          ids.map { |id| block.reader.table_value("language", id) }.join(",")
        end

        def redirect
          block.redirects[index]
        end

        def truncated
          block.reader.table_value("truncated", block.truncated_ids[index])
        end
      end
    end
  end
end

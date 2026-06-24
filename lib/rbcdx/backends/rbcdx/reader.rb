module CDX
  module Backends
    class RbCDX
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

          each_capture_with_positions { |capture, _position| yield capture }
        end

        def each_capture_with_positions(block_index: nil, record_index: nil)
          return enum_for(:each_capture_with_positions, block_index: block_index, record_index: record_index) unless block_given?

          start_block = normalize_start_block(block_index)
          blocks.each_with_index do |entry, current_block_index|
            next if current_block_index < start_block

            block = read_hot_block(entry)
            start_record = (current_block_index == start_block) ? normalize_start_record(record_index, block) : 0
            block.count.times do |index|
              next if index < start_record

              yield Capture.new(block, index, source_path: path), {
                "block_index" => current_block_index,
                "record_index" => index
              }
            end
          end
        end

        def captures(urlkey, prefix: false, limit: nil)
          return enum_for(:captures, urlkey, prefix: prefix, limit: limit) unless block_given?

          emitted = 0
          captures_with_positions(urlkey, prefix: prefix) do |capture, _position|
            yield capture
            emitted += 1
            break if limit && emitted >= limit
          end
        end

        def captures_with_positions(urlkey, prefix: false, block_index: nil, record_index: nil)
          return enum_for(:captures_with_positions, urlkey, prefix: prefix, block_index: block_index, record_index: record_index) unless block_given?

          query = urlkey.to_s
          indexes = candidate_block_indexes(query, prefix: prefix)
          validate_candidate_start!(indexes, block_index, record_index)

          indexes.each do |current_block_index|
            next if block_index && current_block_index < block_index

            entry = blocks.fetch(current_block_index)
            block = read_hot_block(entry)
            start_record = (current_block_index == block_index) ? normalize_start_record(record_index, block) : 0
            block.urlkeys.each_with_index do |candidate, index|
              next if index < start_record
              next unless prefix ? candidate.start_with?(query) : candidate == query

              yield Capture.new(block, index, source_path: path), {
                "block_index" => current_block_index,
                "record_index" => index
              }
            end
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
          "crawl-data/#{header.fetch("crawl_id")}/segments/#{segment}/#{Format::ID_TO_KIND.fetch(kind)}/#{warc_time_pair}-#{format("%05d", shard_id)}.warc.gz"
        end

        def read_cold_columns(entry)
          offset = block_offset("cold_blocks", entry.cold_compressed_offset, entry.cold_compressed_length)
          compressed = read_at(offset, entry.cold_compressed_length)
          data = decompress_block("cold_blocks", compressed)
          raise Error, "#{path}: cold block uncompressed length mismatch" unless data.bytesize == entry.cold_uncompressed_length

          count, base_timestamp, columns = Format.decode_payload(data, Format::COLD_BLOCK_MAGIC, Format::COLD_COLUMN_NAMES)
          raise Error, "#{path}: cold block record count mismatch" unless count == entry.record_count
          raise Error, "#{path}: cold block timestamp base mismatch" unless base_timestamp == entry.block_base_timestamp

          columns
        end

        private

        def read_metadata
          metadata = Format.read_metadata(path)
          @header = metadata.header
          @section_bounds = metadata.sections
          @tables = Format.decode_dictionaries(metadata.read_section("dict"))
          @blocks = Format.decode_directory(metadata.read_section("directory"))
          @block_starts = blocks.map(&:first_urlkey)
          validate_directory
        end

        def section_label(name)
          Format.section_label(name)
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

        def normalize_start_block(block_index)
          return 0 if block_index.nil?
          raise InvalidCursor, "malformed capture cursor position" unless block_index.is_a?(Integer) && block_index >= 0
          raise InvalidCursor, "capture cursor position is outside this index file" unless block_index < blocks.length

          block_index
        end

        def normalize_start_record(record_index, block)
          return 0 if record_index.nil?
          raise InvalidCursor, "malformed capture cursor position" unless record_index.is_a?(Integer) && record_index >= 0
          raise InvalidCursor, "capture cursor position is outside this index block" unless record_index < block.count

          record_index
        end

        def validate_candidate_start!(candidate_indexes, block_index, record_index)
          return if block_index.nil?

          normalize_start_block(block_index)
          unless candidate_indexes.include?(block_index)
            raise InvalidCursor, "capture cursor position is outside this query"
          end
          normalize_start_record(record_index, read_hot_block(blocks.fetch(block_index))) unless record_index.nil?
        end

        def candidate_blocks(query, prefix:)
          candidate_block_indexes(query, prefix: prefix).map { |index| blocks.fetch(index) }
        end

        def candidate_block_indexes(query, prefix:)
          end_key = prefix ? prefix_successor(query) : nil
          index = [upper_bound(@block_starts, query) - 1, 0].max
          index -= 1 while index.positive? && block_overlaps_query?(blocks[index - 1], query, prefix: prefix, end_key: end_key)

          candidates = []

          while index < blocks.length
            block = blocks[index]
            if block_overlaps_query?(block, query, prefix: prefix, end_key: end_key)
              candidates << index
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

          count, base_timestamp, columns = Format.decode_payload(data, Format::HOT_BLOCK_MAGIC, Format::HOT_COLUMN_NAMES)
          raise Error, "#{path}: hot block record count mismatch" unless count == entry.record_count
          raise Error, "#{path}: hot block timestamp base mismatch" unless base_timestamp == entry.block_base_timestamp

          BlockView.new(self, entry, count, base_timestamp, columns)
        end

        def decompress_block(section_name, compressed)
          Format.zstd_decompress(compressed)
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
    end
  end
end

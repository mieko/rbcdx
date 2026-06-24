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

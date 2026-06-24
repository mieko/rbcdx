module CDX
  module Backends
    class RbCDX
      class Writer < CDX::Repack::Writer
        class SectionSpool
          attr_reader :bytesize

          def initialize(name, directory:)
            @tempfile = Tempfile.new(["rbcdx-#{name}.", ".section"], directory)
            @tempfile.binmode
            @bytesize = 0
            @closed = false
          end

          def write(data)
            @tempfile.write(data)
            @bytesize += data.bytesize
          end

          def copy_to(output)
            @tempfile.flush
            @tempfile.rewind
            IO.copy_stream(@tempfile, output)
          end

          def close!
            return if @closed

            @tempfile.close!
            @closed = true
          end
        end

        class PreviewDictionaryMap
          def fetch(_value)
            1
          end
        end

        def initialize(output_path, block_bytes: Format::DEFAULT_BLOCK_BYTES,
          max_records: Format::DEFAULT_MAX_RECORDS, restart_interval: Format::DEFAULT_RESTART_INTERVAL,
          zstd_level: 6, verify: true, metadata: nil, **options)
          super(output_path, **options)
          @block_bytes = decimal_option("block_bytes", block_bytes)
          @max_records = decimal_option("max_records", max_records)
          @restart_interval = decimal_option("restart_interval", restart_interval)
          @zstd_level = decimal_option("zstd_level", zstd_level)
          @verify = verify
          @metadata = metadata || {}
          @hot_blocks = nil
          @cold_blocks = nil
          validate_options
        end

        def needs_prepare?
          true
        end

        def prepare(reader, filters, progress: nil)
          tables = Format::TABLE_NAMES.to_h { |name| [name, Set.new] }
          crawl_id_state = {}
          total_records = 0
          count = 0
          raw_bytes = 0
          fingerprint = Repack.new_selected_fingerprint

          progress&.call(processed_bytes: 0, total_records: total_records, selected_records: count)
          reader.each_capture do |capture, raw_line, source_offset|
            total_records += 1
            raw_bytes += Repack.line_bytes(capture, raw_line)
            if Repack.keep?(filters, capture)
              urlkey, _timestamp, object = capture_parts(capture)
              Repack.fingerprint_selected_record(fingerprint, capture, raw_line)
              Format.validate_cdxj_object(capture.source_path, capture.line_number, urlkey, object)
              count += 1
              collect_tables(tables, capture, object, crawl_id_state)
            end
            progress&.call(processed_bytes: source_offset, total_records: total_records, selected_records: count)
          end
          progress&.call(processed_bytes: reader.bytesize, total_records: total_records, selected_records: count, final: true)

          {
            tables: tables,
            record_count: count,
            raw_bytes: raw_bytes,
            crawl_id: crawl_id_state[:crawl_id],
            selected_fingerprint: Repack.finish_selected_fingerprint(fingerprint)
          }
        end

        def preview(reader, filters, progress: nil)
          maps = Format::TABLE_NAMES.to_h { |name| [name, PreviewDictionaryMap.new] }
          crawl_id_state = {}
          summarize(reader, filters, validate: ->(capture, _raw_line) {
            build_record(capture, maps, crawl_id_state)
          }, progress: progress)
        end

        def start(prepared)
          @prepared = prepared
          @dict_data, @maps = Format.encode_dictionaries(prepared.fetch(:tables))
          @crawl_id_state = {crawl_id: prepared.fetch(:crawl_id)}
          @block_records = []
          @block_source_bytes = 0
          @blocks = []
          @length_sum = 0
          @offset_sum = 0
          @record_count = 0
          FileUtils.mkdir_p(File.dirname(output_path))
          @hot_blocks = new_section_spool("hot-blocks")
          @cold_blocks = new_section_spool("cold-blocks")
        end

        def write(capture, raw_line: nil)
          record = build_record(capture, @maps, @crawl_id_state)
          @block_records << record
          @block_source_bytes += Repack.line_bytes(capture, raw_line)
          @length_sum += record.length
          @offset_sum += record.offset
          @record_count += 1
          flush_block if @block_source_bytes >= @block_bytes || @block_records.length >= @max_records
        end

        def finish(summary:, source_signature:, filter_signature:, options_metadata:, **_options)
          flush_block
          unless summary.selected_fingerprint == @prepared.fetch(:selected_fingerprint)
            raise Error, "repack filters selected different records between passes"
          end
          unless summary.raw_bytes == @prepared.fetch(:raw_bytes)
            raise Error, "repack input changed between passes"
          end

          directory_data = Format.encode_directory(@blocks, @restart_interval)
          header = {
            "magic" => Format::MAGIC,
            "version" => Format::VERSION,
            "variant" => Format::VARIANT,
            "flags" => 0,
            "record_count" => @record_count,
            "block_count" => @blocks.length,
            "source_kind" => Format::SOURCE_KIND_COMMON_CRAWL_CDXJ,
            "crawl_id" => @crawl_id_state[:crawl_id].to_s,
            "created_at" => Time.now.to_i,
            "restart_interval" => @restart_interval,
            "raw_bytes" => summary.raw_bytes,
            "length_sum" => @length_sum,
            "offset_sum" => @offset_sum,
            "hot_column_names" => Format::HOT_COLUMN_NAMES,
            "cold_column_names" => Format::COLD_COLUMN_NAMES,
            "repack" => {
              "source" => source_signature,
              "options" => options_metadata,
              "filter_signature" => filter_signature,
              "selected_fingerprint" => summary.selected_fingerprint,
              "extra" => @metadata
            }
          }

          write_output(
            dict_data: @dict_data,
            directory_data: directory_data,
            hot_data: @hot_blocks,
            cold_data: @cold_blocks,
            header: header
          )

          Repacker::Result.new(
            output_path,
            @record_count,
            @blocks.length,
            summary.raw_bytes,
            @length_sum,
            @offset_sum,
            @hot_blocks.bytesize,
            @cold_blocks.bytesize,
            summary.selected_fingerprint,
            source_signature,
            output_signature,
            "rbcdx"
          )
        end

        def cleanup
          @hot_blocks&.close!
          @cold_blocks&.close!
        end

        def options_metadata
          {
            "block_bytes" => @block_bytes,
            "max_records" => @max_records,
            "restart_interval" => @restart_interval,
            "zstd_level" => @zstd_level
          }
        end

        private

        def validate_options
          raise ArgumentError, "block_bytes must be positive" unless @block_bytes.positive?
          raise ArgumentError, "max_records must be positive" unless @max_records.positive?
          raise ArgumentError, "restart_interval must be positive" unless @restart_interval.positive?
          raise ArgumentError, "zstd_level must be positive" unless @zstd_level.positive?
        end

        def decimal_option(name, value)
          string = value.to_s
          raise ArgumentError, "#{name} must be a decimal integer" unless string.match?(/\A\d+\z/)

          string.to_i
        end

        def collect_tables(tables, capture, object, crawl_id_state)
          Format.collect_value(tables, "status", object["status"])
          Format.collect_value(tables, "mime", object["mime"])
          Format.collect_value(tables, "mime-detected", object["mime-detected"])
          Format.collect_value(tables, "charset", object["charset"])
          Format.collect_value(tables, "truncated", object["truncated"])

          object["languages"].to_s.split(",").each do |language|
            Format.collect_value(tables, "language", language.strip)
          end

          filename = object.fetch("filename").to_s
          if (parsed = Format.parse_filename(capture.source_path, capture.line_number, capture.urlkey, filename, crawl_id_state))
            _crawl_id, segment, _kind, warc_time_pair, _shard = parsed
            Format.collect_value(tables, "segment", segment)
            Format.collect_value(tables, "warc-time-pair", warc_time_pair)
          else
            Format.collect_value(tables, "fallback-filename", filename)
          end
        end

        def build_record(capture, maps, crawl_id_state)
          urlkey, timestamp, object = capture_parts(capture)
          Format.build_record_from_parts(capture.source_path, capture.line_number, urlkey, timestamp, object, maps, crawl_id_state)
        rescue KeyError => error
          raise Error, "repack filters selected different records between passes: #{error.message}"
        end

        def capture_parts(capture)
          object = capture.to_h
          urlkey = object.delete("urlkey")
          timestamp = object.delete("timestamp")
          [urlkey, timestamp, object]
        end

        def flush_block
          return if @block_records.empty?

          hot_uncompressed, hot_compressed, cold_uncompressed, cold_compressed, base_timestamp = Format.encode_split_block(
            @block_records,
            zstd_level: @zstd_level,
            restart_interval: @restart_interval
          )
          @blocks << Format::BlockEntry.new(
            first_urlkey: @block_records.first.urlkey,
            last_urlkey: @block_records.last.urlkey,
            record_count: @block_records.length,
            hot_compressed_offset: @hot_blocks.bytesize,
            hot_compressed_length: hot_compressed.bytesize,
            hot_uncompressed_length: hot_uncompressed.bytesize,
            cold_compressed_offset: @cold_blocks.bytesize,
            cold_compressed_length: cold_compressed.bytesize,
            cold_uncompressed_length: cold_uncompressed.bytesize,
            block_base_timestamp: base_timestamp
          )
          @hot_blocks.write(hot_compressed)
          @cold_blocks.write(cold_compressed)
          @block_records.clear
          @block_source_bytes = 0
        end

        def new_section_spool(name)
          directory = File.dirname(output_path)
          directory = nil unless File.directory?(directory)
          SectionSpool.new(name, directory: directory)
        end

        def write_output(dict_data:, directory_data:, hot_data:, cold_data:, header:)
          if @atomic
            write_atomic_output(
              dict_data: dict_data,
              directory_data: directory_data,
              hot_data: hot_data,
              cold_data: cold_data,
              header: header
            )
          else
            Format.write_file(
              output_path,
              dict_data: dict_data,
              directory_data: directory_data,
              hot_data: hot_data,
              cold_data: cold_data,
              header: header
            )
            Repacker.verify_output(output_path, header.fetch("record_count")) if @verify
            @output_signature = Repack.file_signature(output_path)
          end
        end

        def write_atomic_output(dict_data:, directory_data:, hot_data:, cold_data:, header:)
          temp = temp_in_output_dir
          temp_path = temp.path
          temp.close

          Format.write_file(
            temp_path,
            dict_data: dict_data,
            directory_data: directory_data,
            hot_data: hot_data,
            cold_data: cold_data,
            header: header
          )
          Repacker.verify_output(temp_path, header.fetch("record_count")) if @verify
          publish_temp(temp_path)
          temp_path = nil
        ensure
          temp&.close
          File.unlink(temp_path) if temp_path && File.exist?(temp_path)
        end
      end
    end
  end
end

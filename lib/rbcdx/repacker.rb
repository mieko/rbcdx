require "digest"
require "fileutils"
require "json"
require "tempfile"
require "zlib"

module CDX
  class Repacker
    Result = Struct.new(
      :path,
      :record_count,
      :block_count,
      :raw_bytes,
      :length_sum,
      :offset_sum,
      :hot_bytes,
      :cold_bytes,
      :selected_fingerprint,
      :source_signature
    )

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
    private_constant :SectionSpool

    def self.repack(input_path, output_path, **options)
      new(input_path, output_path, **options).repack
    end

    def self.repack_many(inputs, output_dir:, **options)
      BatchRepacker.new(inputs, output_dir: output_dir, **options).run
    end

    def self.read_header(path)
      RbcdxFormat.read_header(path)
    end

    def self.verify_output(path, expected_record_count)
      metadata = RbcdxFormat.read_metadata(path)
      header = metadata.header
      unless header.fetch("record_count") == expected_record_count
        raise Error, "#{path}: repack verification count mismatch"
      end

      sections = RbcdxFormat::DEFAULT_SECTIONS.map { |name| metadata.section(name) }
      unless sections.first.offset == metadata.first_section_offset
        raise Error, "#{path}: rbcdx first section offset does not match header size"
      end
      sections.each_cons(2) do |left, right|
        unless left.finish == right.offset
          raise Error, "#{path}: rbcdx sections are not contiguous"
        end
      end
      unless sections.last.finish == metadata.file_size
        raise Error, "#{path}: rbcdx file has trailing bytes"
      end

      true
    end

    def initialize(input_path, output_path, block_bytes: RbcdxFormat::DEFAULT_BLOCK_BYTES,
      max_records: RbcdxFormat::DEFAULT_MAX_RECORDS, restart_interval: RbcdxFormat::DEFAULT_RESTART_INTERVAL,
      zstd_level: 6, filters: nil, where: nil, filter_signature: nil, filter_registry: RepackFilters::DEFAULT_REGISTRY,
      atomic: true, verify: true, force: false, metadata: nil)
      @input_path = File.expand_path(input_path)
      @output_path = File.expand_path(output_path)
      @block_bytes = decimal_option("block_bytes", block_bytes)
      @max_records = decimal_option("max_records", max_records)
      @restart_interval = decimal_option("restart_interval", restart_interval)
      @zstd_level = decimal_option("zstd_level", zstd_level)
      @filter_signature = filter_signature || inferred_filter_signature(filters, where)
      @filters = RepackFilters.build(filters, registry: filter_registry, where: where)
      @atomic = atomic
      @verify = verify
      @force = force
      @metadata = metadata || {}
      validate_options
    end

    def repack
      hot_blocks = nil
      cold_blocks = nil

      raise ArgumentError, "input path does not exist: #{@input_path}" unless File.file?(@input_path)
      raise ArgumentError, "input and output paths must be different: #{@input_path}" if same_input_and_output?
      raise Error, "output already exists; use force: true to overwrite: #{@output_path}" if File.exist?(@output_path) && !@force

      source_signature = current_source_signature
      collected = collect_tables
      ensure_source_unchanged!(source_signature)
      tables = collected.fetch(:tables)
      dict_data, maps = RbcdxFormat.encode_dictionaries(tables)
      FileUtils.mkdir_p(File.dirname(@output_path))
      hot_blocks = new_section_spool("hot-blocks")
      cold_blocks = new_section_spool("cold-blocks")
      result = encode_blocks(maps, collected.fetch(:crawl_id), hot_blocks: hot_blocks, cold_blocks: cold_blocks)
      ensure_source_unchanged!(source_signature)
      unless result.fetch(:selected_fingerprint) == collected.fetch(:selected_fingerprint)
        raise Error, "repack filters selected different records between passes"
      end
      unless result.fetch(:raw_bytes) == collected.fetch(:raw_bytes)
        raise Error, "repack input changed between passes"
      end
      directory_data = RbcdxFormat.encode_directory(result.fetch(:blocks), @restart_interval)
      header = {
        "magic" => RbcdxFormat::MAGIC,
        "version" => RbcdxFormat::VERSION,
        "variant" => RbcdxFormat::VARIANT,
        "flags" => 0,
        "record_count" => result.fetch(:record_count),
        "block_count" => result.fetch(:blocks).length,
        "source_kind" => RbcdxFormat::SOURCE_KIND_COMMON_CRAWL_CDXJ,
        "crawl_id" => result.fetch(:crawl_id).to_s,
        "created_at" => Time.now.to_i,
        "restart_interval" => @restart_interval,
        "raw_bytes" => result.fetch(:raw_bytes),
        "length_sum" => result.fetch(:length_sum),
        "offset_sum" => result.fetch(:offset_sum),
        "hot_column_names" => RbcdxFormat::HOT_COLUMN_NAMES,
        "cold_column_names" => RbcdxFormat::COLD_COLUMN_NAMES,
        "repack" => repack_metadata(
          source_signature: source_signature,
          selected_fingerprint: result.fetch(:selected_fingerprint)
        )
      }

      write_output(
        dict_data: dict_data,
        directory_data: directory_data,
        hot_data: hot_blocks,
        cold_data: cold_blocks,
        header: header
      )

      Result.new(
        path: @output_path,
        record_count: result.fetch(:record_count),
        block_count: result.fetch(:blocks).length,
        raw_bytes: collected.fetch(:raw_bytes),
        length_sum: result.fetch(:length_sum),
        offset_sum: result.fetch(:offset_sum),
        hot_bytes: result.fetch(:hot_bytes),
        cold_bytes: result.fetch(:cold_bytes),
        selected_fingerprint: result.fetch(:selected_fingerprint),
        source_signature: source_signature
      )
    ensure
      hot_blocks&.close!
      cold_blocks&.close!
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

    def inferred_filter_signature(filters, where)
      RepackFilters.stable_signature(filters: filters, where: where)
    rescue ArgumentError
      nil
    end

    def same_input_and_output?
      return true if @input_path == @output_path
      return false unless File.exist?(@output_path)

      File.realpath(@input_path) == File.realpath(@output_path)
    rescue SystemCallError
      false
    end

    def new_section_spool(name)
      directory = File.dirname(@output_path)
      directory = nil unless File.directory?(directory)
      SectionSpool.new(name, directory: directory)
    end

    def collect_tables
      tables = RbcdxFormat::TABLE_NAMES.to_h { |name| [name, Set.new] }
      crawl_id_state = {}
      previous_urlkey = nil
      line_count = 0
      raw_bytes = 0
      fingerprint = new_selected_fingerprint

      each_input_line do |line, line_number|
        raw_bytes += line.bytesize
        urlkey, timestamp, object = RbcdxFormat.read_cdxj_line(@input_path, line_number, line)
        if previous_urlkey && urlkey < previous_urlkey
          raise RbcdxFormat::EncodeError.new(
            source_path: @input_path,
            line_number: line_number,
            urlkey: urlkey,
            field: "urlkey",
            value: urlkey,
            reason: "input is not sorted by urlkey"
          )
        end
        previous_urlkey = urlkey
        next unless keep_record?(line_number, urlkey, timestamp, object)

        fingerprint_selected_record(fingerprint, line_number, urlkey, timestamp, line)
        RbcdxFormat.validate_cdxj_object(@input_path, line_number, urlkey, object)
        line_count += 1

        RbcdxFormat.collect_value(tables, "status", object["status"])
        RbcdxFormat.collect_value(tables, "mime", object["mime"])
        RbcdxFormat.collect_value(tables, "mime-detected", object["mime-detected"])
        RbcdxFormat.collect_value(tables, "charset", object["charset"])
        RbcdxFormat.collect_value(tables, "truncated", object["truncated"])

        object["languages"].to_s.split(",").each do |language|
          RbcdxFormat.collect_value(tables, "language", language.strip)
        end

        filename = object.fetch("filename").to_s
        if (parsed = RbcdxFormat.parse_filename(@input_path, line_number, urlkey, filename, crawl_id_state))
          _crawl_id, segment, _kind, warc_time_pair, _shard = parsed
          RbcdxFormat.collect_value(tables, "segment", segment)
          RbcdxFormat.collect_value(tables, "warc-time-pair", warc_time_pair)
        else
          RbcdxFormat.collect_value(tables, "fallback-filename", filename)
        end
      end

      {
        tables: tables,
        record_count: line_count,
        raw_bytes: raw_bytes,
        crawl_id: crawl_id_state[:crawl_id],
        selected_fingerprint: finish_selected_fingerprint(fingerprint)
      }
    end

    def encode_blocks(maps, crawl_id, hot_blocks:, cold_blocks:)
      crawl_id_state = {crawl_id: crawl_id}
      previous_urlkey = nil
      block_records = []
      block_source_bytes = 0
      blocks = []
      length_sum = 0
      offset_sum = 0
      record_count = 0
      raw_bytes = 0
      fingerprint = new_selected_fingerprint

      flush_block = lambda do
        return if block_records.empty?

        hot_uncompressed, hot_compressed, cold_uncompressed, cold_compressed, base_timestamp = RbcdxFormat.encode_split_block(
          block_records,
          zstd_level: @zstd_level,
          restart_interval: @restart_interval
        )
        blocks << RbcdxFormat::BlockEntry.new(
          first_urlkey: block_records.first.urlkey,
          last_urlkey: block_records.last.urlkey,
          record_count: block_records.length,
          hot_compressed_offset: hot_blocks.bytesize,
          hot_compressed_length: hot_compressed.bytesize,
          hot_uncompressed_length: hot_uncompressed.bytesize,
          cold_compressed_offset: cold_blocks.bytesize,
          cold_compressed_length: cold_compressed.bytesize,
          cold_uncompressed_length: cold_uncompressed.bytesize,
          block_base_timestamp: base_timestamp
        )
        hot_blocks.write(hot_compressed)
        cold_blocks.write(cold_compressed)
        block_records.clear
        block_source_bytes = 0
      end

      each_input_line do |line, line_number|
        raw_bytes += line.bytesize
        urlkey, timestamp, object = RbcdxFormat.read_cdxj_line(@input_path, line_number, line)
        if previous_urlkey && urlkey < previous_urlkey
          raise RbcdxFormat::EncodeError.new(
            source_path: @input_path,
            line_number: line_number,
            urlkey: urlkey,
            field: "urlkey",
            value: urlkey,
            reason: "input is not sorted by urlkey"
          )
        end
        previous_urlkey = urlkey
        next unless keep_record?(line_number, urlkey, timestamp, object)

        fingerprint_selected_record(fingerprint, line_number, urlkey, timestamp, line)
        record = build_record_for_second_pass(line_number, urlkey, timestamp, object, maps, crawl_id_state)
        block_records << record
        block_source_bytes += line.bytesize
        length_sum += record.length
        offset_sum += record.offset
        record_count += 1
        flush_block.call if block_source_bytes >= @block_bytes || block_records.length >= @max_records
      end
      flush_block.call

      {
        crawl_id: crawl_id_state[:crawl_id],
        blocks: blocks,
        hot_bytes: hot_blocks.bytesize,
        cold_bytes: cold_blocks.bytesize,
        record_count: record_count,
        raw_bytes: raw_bytes,
        length_sum: length_sum,
        offset_sum: offset_sum,
        selected_fingerprint: finish_selected_fingerprint(fingerprint)
      }
    end

    def build_record_for_second_pass(line_number, urlkey, timestamp, object, maps, crawl_id_state)
      RbcdxFormat.build_record_from_parts(@input_path, line_number, urlkey, timestamp, object, maps, crawl_id_state)
    rescue KeyError => error
      raise Error, "repack filters selected different records between passes: #{error.message}"
    end

    def current_source_signature
      stat = File.stat(@input_path)
      {
        "path" => @input_path,
        "basename" => File.basename(@input_path),
        "bytes" => stat.size,
        "mtime" => stat.mtime.to_i,
        "mtime_nsec" => stat.mtime.nsec
      }
    end

    def ensure_source_unchanged!(expected)
      return if current_source_signature == expected

      raise Error, "repack input changed while processing: #{@input_path}"
    end

    def repack_metadata(source_signature:, selected_fingerprint:)
      {
        "source" => source_signature,
        "options" => repack_options_metadata,
        "filter_signature" => @filter_signature,
        "selected_fingerprint" => selected_fingerprint,
        "extra" => @metadata
      }
    end

    def repack_options_metadata
      {
        "block_bytes" => @block_bytes,
        "max_records" => @max_records,
        "restart_interval" => @restart_interval,
        "zstd_level" => @zstd_level
      }
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
        RbcdxFormat.write_file(
          @output_path,
          dict_data: dict_data,
          directory_data: directory_data,
          hot_data: hot_data,
          cold_data: cold_data,
          header: header
        )
        verify_output(@output_path, header.fetch("record_count")) if @verify
      end
    end

    def write_atomic_output(dict_data:, directory_data:, hot_data:, cold_data:, header:)
      FileUtils.mkdir_p(File.dirname(@output_path))
      temp = Tempfile.new(["#{File.basename(@output_path)}.", ".tmp"], File.dirname(@output_path))
      temp_path = temp.path
      temp.close

      RbcdxFormat.write_file(
        temp_path,
        dict_data: dict_data,
        directory_data: directory_data,
        hot_data: hot_data,
        cold_data: cold_data,
        header: header
      )
      verify_output(temp_path, header.fetch("record_count")) if @verify
      File.rename(temp_path, @output_path)
      temp_path = nil
    ensure
      temp&.close
      File.unlink(temp_path) if temp_path && File.exist?(temp_path)
    end

    def verify_output(path, expected_record_count)
      self.class.verify_output(path, expected_record_count)
    end

    def new_selected_fingerprint
      {
        count: 0,
        first: nil,
        last: nil,
        sha256: Digest::SHA256.new
      }
    end

    def fingerprint_selected_record(fingerprint, line_number, urlkey, timestamp, line)
      identity = {
        "line_number" => line_number,
        "urlkey" => urlkey.to_s,
        "timestamp" => timestamp.to_s
      }
      fingerprint[:first] ||= identity
      fingerprint[:last] = identity
      fingerprint[:count] += 1
      digest = fingerprint.fetch(:sha256)
      digest << [line_number].pack("Q<")
      digest_string(digest, urlkey)
      digest_string(digest, timestamp)
      digest_string(digest, line)
    end

    def finish_selected_fingerprint(fingerprint)
      {
        "count" => fingerprint.fetch(:count),
        "first" => fingerprint[:first],
        "last" => fingerprint[:last],
        "sha256" => fingerprint.fetch(:sha256).hexdigest
      }
    end

    def digest_string(digest, value)
      data = value.to_s.b
      digest << [data.bytesize].pack("Q<")
      digest << data
    end

    def keep_record?(line_number, urlkey, timestamp, object)
      return true if @filters.empty?

      record = RepackFilters.record(
        source_path: @input_path,
        line_number: line_number,
        urlkey: urlkey,
        timestamp: timestamp,
        fields: object
      )
      RepackFilters.keep?(@filters, record)
    end

    def each_input_line
      if @input_path.end_with?(".gz")
        each_gzip_line { |line, line_number| yield line, line_number }
      else
        File.open(@input_path, "r:utf-8") do |file|
          file.each_line.with_index(1) { |line, line_number| yield line, line_number }
        end
      end
    end

    def each_gzip_line
      File.open(@input_path, "rb") do |file|
        unused = nil
        line_number = 0
        until file.eof? && unused.to_s.empty?
          gzip = Zlib::GzipReader.new(Backends::Cdx::PrependedIO.new(unused, file))
          gzip.each_line do |line|
            line_number += 1
            yield line, line_number
          end
          unused = gzip.unused
          gzip.finish
        end
      end
    end
  end
end

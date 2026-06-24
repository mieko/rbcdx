require "digest"
require "fileutils"
require "json"
require "tempfile"

module CDX
  module Repack
    Summary = Struct.new(
      :record_count,
      :total_records,
      :filtered_count,
      :raw_bytes,
      :selected_fingerprint
    )

    class Writer
      attr_reader :output_path, :output_signature

      def initialize(output_path, atomic:, force:, **_options)
        @output_path = File.expand_path(output_path)
        @atomic = atomic
        @force = force
      end

      def needs_prepare?
        false
      end

      def prepare(_reader, _filters)
        nil
      end

      def preview(reader, filters)
        summarize(reader, filters)
      end

      def cleanup
      end

      private

      def summarize(reader, filters, validate: nil)
        total_records = 0
        record_count = 0
        raw_bytes = 0
        fingerprint = Repack.new_selected_fingerprint

        reader.each_capture do |capture, raw_line|
          total_records += 1
          raw_bytes += Repack.line_bytes(capture, raw_line)
          next unless Repack.keep?(filters, capture)

          validate&.call(capture, raw_line)
          Repack.fingerprint_selected_record(fingerprint, capture, raw_line)
          record_count += 1
        end

        Summary.new(
          record_count: record_count,
          total_records: total_records,
          filtered_count: total_records - record_count,
          raw_bytes: raw_bytes,
          selected_fingerprint: Repack.finish_selected_fingerprint(fingerprint)
        )
      end

      def temp_in_output_dir
        FileUtils.mkdir_p(File.dirname(output_path))
        temp = Tempfile.new(["#{File.basename(output_path)}.", ".tmp"], File.dirname(output_path))
        temp.binmode
        temp
      end

      def publish_temp(temp_path)
        if @force
          File.rename(temp_path, output_path)
        else
          begin
            File.link(temp_path, output_path)
            File.unlink(temp_path)
          rescue Errno::EEXIST
            raise Error, "output already exists; use force: true to overwrite: #{output_path}"
          end
        end
        @output_signature = Repack.file_signature(output_path)
      end
    end

    module_function

    def keep?(filters, capture)
      filters.empty? || RepackFilters.keep?(filters, capture)
    end

    def line_bytes(capture, raw_line)
      (raw_line || canonical_cdxj(capture)).bytesize
    end

    def canonical_cdxj(capture)
      data = capture.to_h
      urlkey = data.delete("urlkey")
      timestamp = data.delete("timestamp")
      "#{urlkey} #{timestamp} #{JSON.generate(data)}\n"
    end

    def new_selected_fingerprint
      {
        count: 0,
        first: nil,
        last: nil,
        sha256: Digest::SHA256.new
      }
    end

    def fingerprint_selected_record(fingerprint, capture, raw_line)
      identity = {
        "line_number" => capture.line_number,
        "urlkey" => capture.urlkey.to_s,
        "timestamp" => capture.timestamp.to_s
      }
      fingerprint[:first] ||= identity
      fingerprint[:last] = identity
      fingerprint[:count] += 1
      digest = fingerprint.fetch(:sha256)
      digest << [capture.line_number.to_i].pack("Q<")
      digest_string(digest, capture.urlkey)
      digest_string(digest, capture.timestamp)
      digest_string(digest, raw_line || canonical_cdxj(capture))
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

    def file_signature(path)
      stat = File.stat(path)
      {
        "path" => File.expand_path(path),
        "bytes" => stat.size,
        "mtime" => stat.mtime.to_i,
        "mtime_nsec" => stat.mtime.nsec,
        "ctime" => stat.ctime.to_i,
        "ctime_nsec" => stat.ctime.nsec,
        "dev" => stat.dev,
        "ino" => stat.ino
      }
    end
  end

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
      :source_signature,
      :output_signature,
      :output_format
    )
    Preview = Struct.new(
      :path,
      :input_path,
      :record_count,
      :total_records,
      :filtered_count,
      :raw_bytes,
      :selected_fingerprint,
      :source_signature
    )

    def self.repack(input_path, output_path, **options)
      new(input_path, output_path, **options).repack
    end

    def self.preview(input_path, output_path, **options)
      new(input_path, output_path, **options).preview
    end

    def self.repack_many(inputs, output_dir:, **options)
      BatchRepacker.new(inputs, output_dir: output_dir, **options).run
    end

    def self.writers
      {
        "rbcdx" => Backends::RbCDX::Writer,
        "cdxj" => Backends::CDXJ::Writer
      }
    end

    def self.output_formats
      writers.keys
    end

    def self.read_header(path)
      Backends::RbCDX::Format.read_header(path)
    end

    def self.verify_output(path, expected_record_count)
      metadata = Backends::RbCDX::Format.read_metadata(path)
      header = metadata.header
      unless header.fetch("record_count") == expected_record_count
        raise Error, "#{path}: repack verification count mismatch"
      end

      sections = Backends::RbCDX::Format::DEFAULT_SECTIONS.map { |name| metadata.section(name) }
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

    def initialize(input_path, output_path, output_format: "rbcdx",
      block_bytes: Backends::RbCDX::Format::DEFAULT_BLOCK_BYTES, max_records: Backends::RbCDX::Format::DEFAULT_MAX_RECORDS,
      restart_interval: Backends::RbCDX::Format::DEFAULT_RESTART_INTERVAL, zstd_level: 6,
      filters: nil, where: nil, filter_signature: nil, filter_registry: RepackFilters::DEFAULT_REGISTRY,
      atomic: true, verify: true, force: false, metadata: nil)
      @input_path = File.expand_path(input_path)
      @output_path = File.expand_path(output_path)
      @output_format = output_format.to_s
      @writer_class = self.class.writers.fetch(@output_format) do
        raise ArgumentError, "unsupported output format: #{output_format.inspect}"
      end
      @filter_signature = filter_signature || inferred_filter_signature(filters, where)
      @filters = RepackFilters.build(filters, registry: filter_registry, where: where)
      @force = force
      @writer_options = {
        block_bytes: block_bytes,
        max_records: max_records,
        restart_interval: restart_interval,
        zstd_level: zstd_level,
        atomic: atomic,
        verify: verify,
        force: force,
        metadata: metadata || {}
      }
    end

    def repack
      raise ArgumentError, "input path does not exist: #{@input_path}" unless File.file?(@input_path)
      raise ArgumentError, "input and output paths must be different: #{@input_path}" if same_input_and_output?
      raise Error, "output already exists; use force: true to overwrite: #{@output_path}" if File.exist?(@output_path) && !@force

      reader = Backends::CDXJ::RepackReader.new(@input_path)
      writer = @writer_class.new(@output_path, **@writer_options)
      source_signature = current_source_signature
      prepared = writer.prepare(reader, @filters) if writer.needs_prepare?
      ensure_source_unchanged!(source_signature) if writer.needs_prepare?

      writer.start(prepared)
      summary = stream_to_writer(reader, writer)
      ensure_source_unchanged!(source_signature)
      writer.finish(
        summary: summary,
        source_signature: source_signature,
        filter_signature: @filter_signature,
        options_metadata: repack_options_metadata(writer)
      )
    rescue
      writer&.cleanup
      raise
    ensure
      writer&.cleanup
    end

    def preview
      raise ArgumentError, "input path does not exist: #{@input_path}" unless File.file?(@input_path)
      raise ArgumentError, "input and output paths must be different: #{@input_path}" if same_input_and_output?
      raise Error, "output already exists; use force: true to overwrite: #{@output_path}" if File.exist?(@output_path) && !@force

      reader = Backends::CDXJ::RepackReader.new(@input_path)
      writer = @writer_class.new(@output_path, **@writer_options)
      source_signature = current_source_signature
      summary = writer.preview(reader, @filters)
      ensure_source_unchanged!(source_signature)
      Preview.new(
        @output_path,
        @input_path,
        summary.record_count,
        summary.total_records,
        summary.filtered_count,
        summary.raw_bytes,
        summary.selected_fingerprint,
        source_signature
      )
    end

    private

    def inferred_filter_signature(filters, where)
      RepackFilters.stable_signature(filters: filters, where: where)
    rescue ArgumentError
      nil
    end

    def stream_to_writer(reader, writer)
      total_records = 0
      record_count = 0
      raw_bytes = 0
      fingerprint = Repack.new_selected_fingerprint

      reader.each_capture do |capture, raw_line|
        total_records += 1
        raw_bytes += Repack.line_bytes(capture, raw_line)
        next unless Repack.keep?(@filters, capture)

        Repack.fingerprint_selected_record(fingerprint, capture, raw_line)
        writer.write(capture, raw_line: raw_line)
        record_count += 1
      end

      Repack::Summary.new(
        record_count: record_count,
        total_records: total_records,
        filtered_count: total_records - record_count,
        raw_bytes: raw_bytes,
        selected_fingerprint: Repack.finish_selected_fingerprint(fingerprint)
      )
    end

    def same_input_and_output?
      return true if @input_path == @output_path
      return true if existing_same_file?(@input_path, @output_path)

      input_dir = canonical_directory(File.dirname(@input_path))
      output_dir = canonical_directory(File.dirname(@output_path))
      input_dir == output_dir && File.basename(@input_path) == File.basename(@output_path)
    end

    def existing_same_file?(left, right)
      return false unless File.exist?(left) && File.exist?(right)

      left_stat = File.stat(left)
      right_stat = File.stat(right)
      left_stat.dev == right_stat.dev && left_stat.ino == right_stat.ino
    rescue SystemCallError
      false
    end

    def canonical_directory(path)
      File.realpath(path)
    rescue SystemCallError
      File.expand_path(path)
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

    def repack_options_metadata(writer)
      writer.respond_to?(:options_metadata) ? writer.options_metadata : {}
    end
  end
end

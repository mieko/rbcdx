require "csv"
require "json"
require "optparse"

module CDX
  class CLI
    FORMATS = %w[jsonl text csv].freeze
    DATA_FORMATS = %w[text jsonl].freeze
    REPACK_LOG_FORMAT = "rbcdx-repack-log"
    REPACK_LOG_VERSION = 1
    REPACK_LOG_FILENAME = "rbcdx-repack-log.json"
    RepackPlanEntry = Struct.new(:input_path, :output_path)

    def self.start(argv = ARGV, out: $stdout, err: $stderr, data_client: nil)
      new(argv.dup, out: out, err: err, data_client: data_client).run
    rescue Interrupt
      err.puts "rbcdx: interrupted"
      130
    rescue ArgumentError, Error, OptionParser::ParseError => error
      err.puts "rbcdx: #{error.message}"
      1
    end

    def initialize(argv, out:, err:, data_client: nil)
      @argv = argv
      @out = out
      @err = err
      @data_client = data_client || CommonCrawlData.new
      @repack_log_loaded = false
    end

    def run
      command = @argv.shift

      case command
      when "captures"
        run_captures
      when "count"
        run_count
      when "repack"
        run_repack
      when "data"
        run_data
      when "--version", "-v"
        @out.puts CDX::VERSION
        0
      when "help", "--help", "-h", nil
        @out.puts usage
        0
      else
        raise ArgumentError, "unknown command #{command.inspect}\n\n#{usage}"
      end
    end

    private

    def run_captures
      options = parse_options
      return show_help(options) if options[:help]

      url = url_pattern
      index = build_index(options)
      fields = split_fields(options[:fields])

      case options[:format]
      when "jsonl"
        index.captures(url, **query_options(options)) do |capture|
          data = fields ? capture.with_fields(*fields).to_h : capture.to_h
          @out.puts JSON.generate(data)
        end
      when "text"
        index.captures(url, **query_options(options)) do |capture|
          @out.puts [capture.status, capture.timestamp, capture.url].compact.join(" ")
        end
      when "csv"
        csv = CSV.new(@out)
        header = fields || %w[urlkey timestamp url status mime digest length offset filename]
        csv << header
        index.captures(url, **query_options(options)) do |capture|
          csv << header.map { |field| capture.field(field) }
        end
      else
        raise ArgumentError, "unsupported format #{options[:format].inspect}"
      end

      0
    end

    def run_count
      options = parse_options
      return show_help(options) if options[:help]

      url = url_pattern
      index = build_index(options)
      @out.puts index.captures(url, **query_options(options).merge(limit: nil)).count
      0
    end

    def run_repack
      options = parse_repack_options
      return show_help(options) if options[:help]

      if options[:output] && !options[:resume]
        run_repack_one(options)
      else
        run_repack_many(options)
      end
    end

    def run_repack_one(options)
      raise ArgumentError, "choose --output or --output-dir, not both" if options[:output] && options[:output_dir]
      raise ArgumentError, "--delete-when-processed requires --output-dir" if options[:delete_when_processed]
      raise ArgumentError, "--resume requires --output-dir" if options[:resume]

      input = @argv.shift
      raise ArgumentError, "missing input CDXJ path" unless input
      raise ArgumentError, "options must appear before the input path: #{@argv.join(" ")}" unless @argv.empty?
      raise ArgumentError, "provide --output PATH or --output-dir DIR" unless options[:output]

      if options[:dry_run]
        preview = CDX::Repacker.preview(
          input,
          options.fetch(:output),
          output_format: options.fetch(:output_format, "rbcdx"),
          block_bytes: options.fetch(:block_bytes, CDX::Backends::RbCDX::Format::DEFAULT_BLOCK_BYTES),
          max_records: options.fetch(:max_records, CDX::Backends::RbCDX::Format::DEFAULT_MAX_RECORDS),
          restart_interval: options.fetch(:restart_interval, CDX::Backends::RbCDX::Format::DEFAULT_RESTART_INTERVAL),
          zstd_level: options.fetch(:zstd_level, 6),
          filters: options.fetch(:filters),
          where: options.fetch(:where),
          only_url_files: options[:only_url_files],
          collapse: options[:collapse],
          collapse_order: options[:collapse_order],
          force: options.fetch(:force, false)
        )
        entry = RepackPlanEntry.new(File.expand_path(input), File.expand_path(options.fetch(:output)))
        progress = RepackProgress.new(@out)
        progress.call(:planned, entry: entry, index: 1, total: 1)
        progress.call(:preview, entry: entry, index: 1, total: 1, preview: preview)
        return 0
      end

      entry = RepackPlanEntry.new(File.expand_path(input), File.expand_path(options.fetch(:output)))
      progress = RepackProgress.new(@err)
      progress.call(:start, entry: entry, index: 1, total: 1)
      result = CDX::Repacker.repack(
        input,
        options.fetch(:output),
        output_format: options.fetch(:output_format, "rbcdx"),
        block_bytes: options.fetch(:block_bytes, CDX::Backends::RbCDX::Format::DEFAULT_BLOCK_BYTES),
        max_records: options.fetch(:max_records, CDX::Backends::RbCDX::Format::DEFAULT_MAX_RECORDS),
        restart_interval: options.fetch(:restart_interval, CDX::Backends::RbCDX::Format::DEFAULT_RESTART_INTERVAL),
        zstd_level: options.fetch(:zstd_level, 6),
        filters: options.fetch(:filters),
        where: options.fetch(:where),
        only_url_files: options[:only_url_files],
        collapse: options[:collapse],
        collapse_order: options[:collapse_order],
        force: options.fetch(:force, false),
        progress: ->(event, **payload) { progress.call(event, entry: entry, index: 1, total: 1, **payload) }
      )
      progress.call(:finish, entry: entry, index: 1, total: 1)
      @out.puts result.path
      0
    rescue
      progress&.call(:fail, entry: entry, index: 1, total: 1)
      raise
    end

    def run_repack_many(options)
      apply_repack_log!(options)
      raise ArgumentError, "choose --output or --output-dir, not both" if options[:output]
      validate_repack_options!(options)
      inputs = @argv.empty? ? ["."] : @argv.dup

      progress_io = options[:dry_run] ? @out : @err
      log_path = nil
      results = begin
        log_path = prepare_repack_log(options, inputs) unless options[:dry_run]
        CDX::Repacker.repack_many(
          inputs,
          output_dir: options.fetch(:output_dir, "."),
          output_format: options.fetch(:output_format, "rbcdx"),
          block_bytes: options.fetch(:block_bytes, CDX::Backends::RbCDX::Format::DEFAULT_BLOCK_BYTES),
          max_records: options.fetch(:max_records, CDX::Backends::RbCDX::Format::DEFAULT_MAX_RECORDS),
          restart_interval: options.fetch(:restart_interval, CDX::Backends::RbCDX::Format::DEFAULT_RESTART_INTERVAL),
          zstd_level: options.fetch(:zstd_level, 6),
          filters: options.fetch(:filters),
          where: options.fetch(:where),
          only_url_files: options[:only_url_files],
          collapse: options[:collapse],
          collapse_order: options[:collapse_order],
          resume: options.fetch(:resume, false),
          force: options.fetch(:force, false),
          dry_run: options.fetch(:dry_run, false),
          delete_when_processed: options.fetch(:delete_when_processed, false),
          manifest: options.fetch(:manifest, true),
          progress: RepackProgress.new(progress_io)
        )
      rescue Interrupt
        report_repack_resume(log_path)
        raise
      rescue
        report_repack_resume(log_path)
        raise
      end
      remove_repack_log(log_path)
      results.each { |result| @out.puts result.output_path } unless options[:dry_run]
      0
    end

    def run_data
      command = @argv.shift

      case command
      when "list"
        run_data_list
      when "download"
        run_data_download
      when "help", "--help", "-h", nil
        @out.puts data_usage
        0
      else
        raise ArgumentError, "unknown data command #{command.inspect}\n\n#{data_usage}"
      end
    end

    def run_data_list
      options = parse_data_list_options
      return show_help(options) if options[:help]

      ensure_no_arguments!
      crawls = @data_client.crawls.first(options[:limit])
      crawls.each do |crawl|
        case options[:format]
        when "text"
          @out.puts [crawl.id, crawl.name, "#{crawl.from}..#{crawl.to}"].compact.join("  ")
        when "jsonl"
          @out.puts JSON.generate(crawl.to_h)
        else
          raise ArgumentError, "unsupported format #{options[:format].inspect}"
        end
      end
      0
    end

    def run_data_download
      options = parse_data_download_options
      return show_help(options) if options[:help]

      ensure_no_arguments!
      validate_data_download_options(options)
      crawl_id = selected_crawl_id(options)

      if options[:dry_run]
        @data_client.index_files(crawl_id, limit: options[:limit], zipnum: options.fetch(:zipnum, true)).each do |file|
          if options[:output]
            @out.puts "#{file.url} -> #{file.destination(options[:output])}"
          else
            @out.puts file.url
          end
        end
        return 0
      end

      @data_client.download_indexes(
        crawl_id: crawl_id,
        output_dir: options.fetch(:output),
        limit: options[:limit],
        force: options.fetch(:force, false),
        zipnum: options.fetch(:zipnum, true),
        progress: DownloadProgress.new(@err)
      ).each do |result|
        @out.puts result.destination
      end
      0
    end

    def parse_options
      options = {
        indexes: [],
        filters: [],
        format: "jsonl"
      }

      parser = OptionParser.new do |opts|
        opts.banner = usage
        opts.on("-h", "--help", "Show help") do
          options[:help] = opts
        end
        opts.on("-i", "--index PATH", "Local CDX/CDXJ file, glob, or directory") do |path|
          options[:indexes] << path
        end
        opts.on("-l", "--limit N", Integer, "Maximum captures to emit") do |limit|
          options[:limit] = limit
        end
        opts.on("--from TIMESTAMP", "Lower CDX timestamp bound") do |timestamp|
          options[:from] = timestamp
        end
        opts.on("--to TIMESTAMP", "Upper CDX timestamp bound") do |timestamp|
          options[:to] = timestamp
        end
        opts.on("--closest TIMESTAMP", "Sort by closeness to a CDX timestamp") do |timestamp|
          options[:closest] = timestamp
        end
        opts.on("--filter FILTER", "CDX field filter or named filter expression") do |filter|
          options[:filters].concat(query_filter_terms(filter))
        end
        opts.on("--fields FIELDS", "Comma-separated fields for jsonl/csv output") do |fields|
          options[:fields] = fields
        end
        opts.on("--format FORMAT", FORMATS, "jsonl, text, or csv") do |format|
          options[:format] = format
        end
        opts.on("--match TYPE", "exact, prefix, domain, or host") do |match|
          options[:match] = match.to_sym
        end
        opts.on("--sort SORT", "timestamp or reverse_timestamp") do |sort|
          options[:sort] = sort.to_sym
        end
        opts.on("--collapse FIELD", "Collapse captures: urlkey") do |collapse|
          options[:collapse] = collapse.to_sym
        end
        opts.on("--collapse-order ORDER", "Collapse order: latest") do |collapse_order|
          options[:collapse_order] = collapse_order.to_sym
        end
      end

      parser.order!(@argv)
      options
    end

    def parse_data_list_options
      options = {
        format: "text",
        limit: 10
      }

      parser = OptionParser.new do |opts|
        opts.banner = data_list_usage
        opts.on("-h", "--help", "Show help") do
          options[:help] = opts
        end
        opts.on("--limit N", Integer, "Maximum crawls to list") do |limit|
          options[:limit] = limit
        end
        opts.on("--format FORMAT", DATA_FORMATS, "text or jsonl") do |format|
          options[:format] = format
        end
      end

      parser.order!(@argv)
      validate_positive_integer!(options[:limit], "--limit")
      options
    end

    def parse_data_download_options
      options = {}

      parser = OptionParser.new do |opts|
        opts.banner = data_download_usage
        opts.on("-h", "--help", "Show help") do
          options[:help] = opts
        end
        opts.on("--crawl CRAWL", "Common Crawl crawl id") do |crawl|
          options[:crawl] = crawl
        end
        opts.on("--latest", "Use the latest crawl") do
          options[:latest] = true
        end
        opts.on("--output DIR", "Directory to write index files") do |output|
          options[:output] = output
        end
        opts.on("--limit N", Integer, "Download only the first N CDX shards") do |limit|
          options[:limit] = limit
        end
        opts.on("--force", "Overwrite existing files") do
          options[:force] = true
        end
        opts.on("--dry-run", "Print planned downloads without writing files") do
          options[:dry_run] = true
        end
        opts.on("--[no-]zipnum", "Download ZipNum lookup data") do |zipnum|
          options[:zipnum] = zipnum
        end
      end

      parser.order!(@argv)
      validate_positive_integer!(options[:limit], "--limit") if options[:limit]
      options
    end

    def parse_repack_options
      filter_expressions = []
      options = {
        filters: [],
        where: [],
        output_format: "rbcdx",
        manifest: true
      }

      parser = OptionParser.new do |opts|
        opts.banner = repack_usage
        opts.on("-h", "--help", "Show help") do
          options[:help] = opts
        end
        opts.on("--output PATH", "Path for the output") do |output|
          options[:output] = output
        end
        opts.on("--output-dir DIR", "Directory for batch outputs") do |output_dir|
          options[:output_dir] = output_dir
        end
        opts.on("--output-format FORMAT", "Output format: rbcdx or cdxj") do |output_format|
          options[:output_format] = output_format
        end
        opts.on("--block-bytes N", Integer, "Source bytes per compressed block") do |block_bytes|
          options[:block_bytes] = block_bytes
        end
        opts.on("--max-records N", Integer, "Maximum records per compressed block") do |max_records|
          options[:max_records] = max_records
        end
        opts.on("--restart-interval N", Integer, "Front-coded string restart interval") do |restart_interval|
          options[:restart_interval] = restart_interval
        end
        opts.on("--zstd-level N", Integer, "Zstandard compression level") do |zstd_level|
          options[:zstd_level] = zstd_level
        end
        opts.on("--filter EXPR", "Filter expression, for example '+status_200,-asset_like'") do |filter|
          filter_expressions << filter
        end
        opts.on("--where FILTER", "CDX field filter, for example '=status:200'") do |filter|
          options[:where] << filter
        end
        opts.on("--only-url-file FILE", "Allow only URL or host/path prefixes listed in FILE") do |file|
          options[:only_url_files] ||= []
          options[:only_url_files] << file
        end
        opts.on("--collapse FIELD", "Collapse captures before writing: urlkey") do |collapse|
          options[:collapse] = collapse.to_sym
        end
        opts.on("--collapse-order ORDER", "Collapse order: latest") do |collapse_order|
          options[:collapse_order] = collapse_order.to_sym
        end
        opts.on("--resume", "Resume a batch repack") do
          options[:resume] = true
        end
        opts.on("--force", "Overwrite outputs and batch state") do
          options[:force] = true
        end
        opts.on("--dry-run", "Preview repack outputs and filter counts without writing files") do
          options[:dry_run] = true
        end
        opts.on("--delete-when-processed", "Delete each source after written batch output") do
          options[:delete_when_processed] = true
        end
        opts.on("--[no-]manifest", "Write rbcdx-manifest.json for batch outputs") do |manifest|
          options[:manifest] = manifest
        end
      end

      parser.order!(@argv)
      options[:filters] = filter_expressions.flat_map { |filter| repack_filter_terms(filter) } unless options[:resume]
      validate_repack_options!(options) unless options[:resume]
      options
    end

    def show_help(options)
      @out.puts options[:help]
      0
    end

    def url_pattern
      url = @argv.shift
      raise ArgumentError, "missing URL pattern" unless url

      unless @argv.empty?
        raise ArgumentError, "options must appear before the URL pattern: #{@argv.join(" ")}"
      end

      url
    end

    def ensure_no_arguments!
      return if @argv.empty?

      raise ArgumentError, "unexpected arguments: #{@argv.join(" ")}"
    end

    def build_index(options)
      raise ArgumentError, "provide at least one --index path" if options[:indexes].empty?

      CDX::Index.open(options[:indexes])
    end

    def query_filter_terms(filter)
      if filter.include?(",") && filter.include?(":")
        parts = split_filter_expression(filter)
        if query_named_filter_expression?(parts.first)
          return parts.flat_map { |part| part.include?(":") ? part : CaptureFilters.parse_expression(part, label: "query filter") }
        end
      end

      return [filter] if filter.include?(":")

      CaptureFilters.parse_expression(filter, label: "query filter")
    end

    def repack_filter_terms(filter)
      CaptureFilters.parse_expression(filter, label: "repack filter")
    end

    def split_filter_expression(filter)
      filter.to_s.split(",").map(&:strip).reject(&:empty?)
    end

    def query_named_filter_expression?(filter)
      return false unless filter
      return false if filter.include?(":")

      CaptureFilters.parse_expression(filter, label: "query filter")
      true
    rescue ArgumentError
      false
    end

    def query_options(options)
      {
        limit: options[:limit],
        from: options[:from],
        to: options[:to],
        closest: options[:closest],
        filters: options[:filters],
        match: options[:match],
        sort: options[:sort],
        collapse: options[:collapse],
        collapse_order: options[:collapse_order]
      }.compact
    end

    def split_fields(fields)
      return unless fields

      fields.split(",").map(&:strip).reject(&:empty?)
    end

    def validate_data_download_options(options)
      if options[:crawl] && options[:latest]
        raise ArgumentError, "choose --crawl or --latest, not both"
      end

      return if options[:dry_run]
      return if options[:output]

      raise ArgumentError, "provide --output DIR"
    end

    def selected_crawl_id(options)
      return options[:crawl] if options[:crawl]

      @data_client.latest_crawl.id
    end

    def validate_positive_integer!(value, option)
      raise ArgumentError, "#{option} must be greater than 0" unless value.positive?
    end

    def validate_repack_output_format!(format)
      return if CDX::Repacker.output_formats.include?(format.to_s)

      raise ArgumentError, "unsupported output format: #{format.inspect}"
    end

    def validate_repack_options!(options)
      validate_repack_output_format!(options.fetch(:output_format))
      validate_cdxj_repack_options!(options) if options.fetch(:output_format) == "cdxj"
      validate_positive_integer!(options[:block_bytes], "--block-bytes") if options[:block_bytes]
      validate_positive_integer!(options[:max_records], "--max-records") if options[:max_records]
      validate_positive_integer!(options[:restart_interval], "--restart-interval") if options[:restart_interval]
      validate_positive_integer!(options[:zstd_level], "--zstd-level") if options[:zstd_level]
    end

    def validate_cdxj_repack_options!(options)
      {
        block_bytes: "--block-bytes",
        max_records: "--max-records",
        restart_interval: "--restart-interval",
        zstd_level: "--zstd-level"
      }.each do |key, flag|
        raise ArgumentError, "#{flag} only applies to --output-format rbcdx" if options.key?(key)
      end
    end

    def apply_repack_log!(options)
      return unless options[:resume]
      if options[:output_dir] || !@argv.empty?
        raise Error, "repack --resume uses #{REPACK_LOG_FILENAME}; run `rbcdx repack --resume` without input paths or --output-dir"
      end
      unless File.file?(repack_log_path)
        raise Error, "no repack log found; rerun the original repack command to start a new batch: #{repack_log_path}"
      end

      log = read_repack_log
      @repack_log_loaded = true
      @err.puts "resuming from #{repack_log_path}"
      request = log["request"]
      unless request.is_a?(Hash)
        raise Error, "#{repack_log_path}: invalid repack log request"
      end
      inputs = request["inputs"]
      unless inputs.is_a?(Array)
        raise Error, "#{repack_log_path}: invalid repack log inputs"
      end
      unless !inputs.empty? && inputs.all? { |input| input.is_a?(String) && !input.empty? }
        raise Error, "#{repack_log_path}: invalid repack log input path"
      end
      log_options = request["options"]
      unless log_options.is_a?(Hash)
        raise Error, "#{repack_log_path}: invalid repack log options"
      end
      output_dir = log_options["output_dir"]
      unless output_dir.is_a?(String) && !output_dir.empty?
        raise Error, "#{repack_log_path}: invalid repack log output_dir"
      end
      output_format = log_options.fetch("output_format", "rbcdx")
      unless output_format.is_a?(String)
        raise Error, "#{repack_log_path}: invalid repack log output_format"
      end
      filters = log_options.fetch("filters", [])
      unless filters.is_a?(Array) && filters.all? { |filter| filter.is_a?(String) }
        raise Error, "#{repack_log_path}: invalid repack log filters"
      end
      where = log_options.fetch("where", [])
      unless where.is_a?(Array) && where.all? { |filter| filter.is_a?(String) }
        raise Error, "#{repack_log_path}: invalid repack log where"
      end
      only_url_files = log_options["only_url_files"]
      if !only_url_files.nil? && !(only_url_files.is_a?(Array) && only_url_files.all? { |file| file.is_a?(String) && !file.empty? })
        raise Error, "#{repack_log_path}: invalid repack log only_url_files"
      end
      only_url_signature = log_options["only_url_signature"]
      if only_url_files.nil?
        raise Error, "#{repack_log_path}: invalid repack log only_url_signature" unless only_url_signature.nil?
      elsif !only_url_signature.is_a?(Hash) || OnlyUrlFilter.from_files(only_url_files).signature != only_url_signature
        raise Error, "#{repack_log_path}: only-url files changed since the repack log was written"
      end
      delete_when_processed = log_options.fetch("delete_when_processed", false)
      unless delete_when_processed == true || delete_when_processed == false
        raise Error, "#{repack_log_path}: invalid repack log delete_when_processed"
      end
      manifest = log_options.fetch("manifest", true)
      unless manifest == true || manifest == false
        raise Error, "#{repack_log_path}: invalid repack log manifest"
      end
      collapse = log_options.fetch("collapse", nil)
      unless collapse.nil? || collapse.is_a?(String)
        raise Error, "#{repack_log_path}: invalid repack log collapse"
      end
      collapse_order = log_options.fetch("collapse_order", nil)
      unless collapse_order.nil? || collapse_order.is_a?(String)
        raise Error, "#{repack_log_path}: invalid repack log collapse_order"
      end

      @argv.replace(inputs)
      options.delete(:output)
      options[:output_dir] = output_dir
      options[:output_format] = output_format
      restore_optional_log_option!(options, log_options, :block_bytes, "block_bytes")
      restore_optional_log_option!(options, log_options, :max_records, "max_records")
      restore_optional_log_option!(options, log_options, :restart_interval, "restart_interval")
      restore_optional_log_option!(options, log_options, :zstd_level, "zstd_level")
      options[:filters] = filters.flat_map { |filter| repack_filter_terms(filter) }
      options[:where] = where
      options[:only_url_files] = only_url_files
      options[:delete_when_processed] = delete_when_processed
      options[:manifest] = manifest
      options[:collapse] = collapse&.to_sym
      options[:collapse_order] = collapse_order&.to_sym
    end

    def restore_optional_log_option!(options, log_options, option_key, log_key)
      if log_options.key?(log_key)
        options[option_key] = log_options[log_key]
      else
        options.delete(option_key)
      end
    end

    def prepare_repack_log(options, inputs)
      path = repack_log_path
      return path if @repack_log_loaded
      return nil if options[:resume]

      if File.file?(path) && !options[:resume] && !options[:force]
        raise Error, "repack log already exists; use --resume to continue or --force to start over: #{path}"
      end

      write_repack_log(path, options, inputs)
      @err.puts "created resume log #{path}"
      @err.puts "if interrupted, run: rbcdx repack --resume"
      path
    end

    def write_repack_log(path, options, inputs)
      data = {
        "format" => REPACK_LOG_FORMAT,
        "version" => REPACK_LOG_VERSION,
        "created_at" => Time.now.to_i,
        "updated_at" => Time.now.to_i,
        "state_path" => File.join(File.expand_path(options.fetch(:output_dir, ".")), CDX::BatchRepacker::STATE_FILENAME),
        "request" => {
          "cwd" => Dir.pwd,
          "inputs" => inputs.map { |input| File.expand_path(input) },
          "options" => repack_log_options(options)
        }
      }
      atomic_write_json(path, data)
    end

    def read_repack_log
      data = JSON.parse(File.read(repack_log_path))
      raise Error, "#{repack_log_path}: invalid repack log format" unless data.is_a?(Hash) && data["format"] == REPACK_LOG_FORMAT
      raise Error, "#{repack_log_path}: unsupported repack log version #{data["version"]}" unless data["version"] == REPACK_LOG_VERSION

      data
    rescue JSON::ParserError => error
      raise Error, "#{repack_log_path}: malformed repack log JSON: #{error.message}"
    end

    def remove_repack_log(path)
      return unless path && File.file?(path)

      File.delete(path)
      @err.puts "removed resume log #{path}"
    end

    def report_repack_resume(path)
      return unless path && File.file?(path)

      @err.puts "resume log kept #{path}"
      @err.puts "resume with: rbcdx repack --resume"
    end

    def repack_log_options(options)
      data = {
        "output_dir" => File.expand_path(options.fetch(:output_dir, ".")),
        "output_format" => options.fetch(:output_format, "rbcdx"),
        "block_bytes" => options[:block_bytes],
        "max_records" => options[:max_records],
        "restart_interval" => options[:restart_interval],
        "zstd_level" => options[:zstd_level],
        "filters" => CaptureFilters.stable_terms(options.fetch(:filters), label: "repack filter"),
        "where" => options.fetch(:where),
        "only_url_files" => options[:only_url_files]&.map { |file| File.expand_path(file) },
        "delete_when_processed" => options.fetch(:delete_when_processed, false),
        "manifest" => options.fetch(:manifest, true),
        "collapse" => options[:collapse]&.to_s,
        "collapse_order" => options[:collapse_order]&.to_s
      }.compact
      if options[:only_url_files]
        data["only_url_signature"] = OnlyUrlFilter.from_files(options[:only_url_files]).signature
      end
      data
    end

    def repack_log_path
      File.join(Dir.pwd, REPACK_LOG_FILENAME)
    end

    def atomic_write_json(path, data)
      temp_path = "#{path}.tmp-#{$$}"
      File.write(temp_path, "#{JSON.pretty_generate(data)}\n")
      File.rename(temp_path, path)
    ensure
      File.delete(temp_path) if temp_path && File.file?(temp_path)
    end

    def usage
      <<~USAGE
        Usage:
          rbcdx captures --index PATH [--limit N] [--filter '=status:200'] URL
          rbcdx count --index PATH URL
          rbcdx repack --output PATH INPUT.cdxj[.gz]
          rbcdx repack [--output-dir DIR] [INPUT...]
          rbcdx data list [--limit N]
          rbcdx data download --output DIR [--crawl CRAWL]

        PATH may be a CDX/CDXJ file, a .rbcdx file, a .gz file, a glob, or a directory.
      USAGE
    end

    def repack_usage
      <<~USAGE
        Usage:
          rbcdx repack --output PATH [options] INPUT.cdxj[.gz]
          rbcdx repack [--output-dir DIR] [options] [INPUT...]

        When --output is not given, repack runs in batch mode. The default input
        and output directory are both the current directory.
        Batch mode records a resume log; run `rbcdx repack --resume` to continue.

        Options:
          --output PATH           Path for the output
          --output-dir DIR        Directory for batch outputs
          --output-format FORMAT  Output format: rbcdx or cdxj
          --block-bytes N         Source bytes per compressed block (rbcdx)
          --max-records N         Maximum records per compressed block (rbcdx)
          --restart-interval N    Front-coded string restart interval (rbcdx)
          --zstd-level N          Zstandard compression level (rbcdx)
          --filter EXPR           Filter expression, for example '+status_200,-asset_like'
          --where FILTER          CDX field filter, for example '=status:200'
          --only-url-file FILE    Allow only URL or host/path prefixes listed in FILE
          --collapse FIELD        Collapse captures before writing: urlkey
          --collapse-order ORDER  Collapse order: latest
          --resume                Resume a batch repack
          --force                 Overwrite outputs and batch state
          --dry-run               Preview outputs and filter counts without writing files
          --delete-when-processed Delete each source after written batch output
          --no-manifest           Do not write rbcdx-manifest.json for rbcdx batch outputs
          -h, --help              Show help
      USAGE
    end

    def data_usage
      <<~USAGE
        Usage:
          rbcdx data list [--limit N] [--format text|jsonl]
          rbcdx data download --output DIR [--crawl CRAWL] [--limit N] [--dry-run] [--no-zipnum]

        Commands:
          list      List available Common Crawl crawls
          download  Download Common Crawl index files
      USAGE
    end

    def data_list_usage
      <<~USAGE
        Usage:
          rbcdx data list [--limit N] [--format text|jsonl]
      USAGE
    end

    def data_download_usage
      <<~USAGE
        Usage:
          rbcdx data download --output DIR [--crawl CRAWL] [--limit N] [--dry-run] [--no-zipnum]
      USAGE
    end

    class DownloadProgress
      REPORT_INTERVAL_BYTES = 64 * 1024 * 1024

      def initialize(io)
        @io = io
        @last_reported_bytes = {}
      end

      def call(event, file:, destination:, index:, total:, downloaded_bytes: nil, total_bytes: nil)
        case event
        when :start
          @last_reported_bytes[destination] = 0
          @io.puts "downloading [#{index}/#{total}] #{file.filename}"
        when :progress
          report_progress(file, destination, index, total, downloaded_bytes, total_bytes)
        when :finish
          @io.puts "downloaded [#{index}/#{total}] #{file.filename} -> #{destination}"
        when :skip
          @io.puts "skipped [#{index}/#{total}] #{file.filename} -> #{destination}"
        end
      end

      private

      def report_progress(file, destination, index, total, downloaded_bytes, total_bytes)
        return unless downloaded_bytes

        last_reported = @last_reported_bytes.fetch(destination, 0)
        return if downloaded_bytes - last_reported < REPORT_INTERVAL_BYTES

        @last_reported_bytes[destination] = downloaded_bytes
        if total_bytes&.positive?
          percent = (downloaded_bytes * 100 / total_bytes)
          @io.puts "progress [#{index}/#{total}] #{file.filename} #{format_bytes(downloaded_bytes)} / #{format_bytes(total_bytes)} (#{percent}%)"
        else
          @io.puts "progress [#{index}/#{total}] #{file.filename} #{format_bytes(downloaded_bytes)}"
        end
      end

      def format_bytes(bytes)
        format("%.1f MiB", bytes / 1024.0 / 1024)
      end
    end

    class RepackProgress
      def initialize(io)
        @io = io
        @progress_starts = {}
      end

      def call(event, entry: nil, index: nil, total: nil, preview: nil, path: nil, entries: nil,
        phase: nil, processed_bytes: nil, total_bytes: nil, total_records: nil, selected_records: nil)
        case event
        when :state_start
          @io.puts "creating repack state #{path}"
        when :state_finish
          @io.puts "created repack state #{path} for #{entries} input(s)"
        when :state_resume
          @io.puts "loaded repack state #{path} with #{entries} input(s)"
        when :planned
          @io.puts "would create [#{index}/#{total}] #{entry.output_path} from #{entry.input_path}"
        when :delete_planned
          @io.puts "would delete after written output [#{index}/#{total}] #{entry.input_path}"
        when :preview
          @io.puts "filtered [#{index}/#{total}] #{entry.input_path}: #{preview.record_count} of #{preview.total_records} records selected"
        when :start
          @io.puts "processing [#{index}/#{total}] #{entry.input_path} -> #{entry.output_path}"
        when :progress
          @io.puts progress_line(
            entry,
            index,
            total,
            phase,
            processed_bytes,
            total_bytes,
            total_records,
            selected_records
          )
        when :finish
          @io.puts "written [#{index}/#{total}] #{entry.input_path} -> #{entry.output_path}"
        when :skip
          @io.puts "skipped [#{index}/#{total}] #{entry.input_path} -> #{entry.output_path}"
        when :delete
          @io.puts "deleted [#{index}/#{total}] #{entry.input_path}"
        when :fail
          @io.puts "failed [#{index}/#{total}] #{entry.input_path} -> #{entry.output_path}"
        end
      end

      private

      def progress_line(entry, index, total, phase, processed_bytes, total_bytes, total_records, selected_records)
        line = "progress [#{index}/#{total}] #{entry.input_path}"
        line << " #{phase}" if phase
        line << " #{format_bytes(processed_bytes)}"
        if total_bytes.to_i.positive?
          line << " / #{format_bytes(total_bytes)} (#{processed_bytes.to_i * 100 / total_bytes.to_i}%)"
          eta = eta_for([entry.input_path, phase], processed_bytes.to_i, total_bytes.to_i)
          line << " eta #{eta}" if eta
        end
        line << " #{selected_records.to_i} of #{total_records.to_i} records selected" if total_records
        line
      end

      def eta_for(key, processed_bytes, total_bytes)
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        started_at, started_bytes = (@progress_starts[key] ||= [now, processed_bytes])
        elapsed = now - started_at
        done = processed_bytes - started_bytes
        return nil unless elapsed.positive? && done.positive? && processed_bytes < total_bytes

        format_duration(((total_bytes - processed_bytes) / (done / elapsed)).round)
      end

      def format_duration(seconds)
        if seconds >= 3600
          format("%dh%02dm", seconds / 3600, (seconds % 3600) / 60)
        elsif seconds >= 60
          format("%dm%02ds", seconds / 60, seconds % 60)
        else
          "#{seconds}s"
        end
      end

      def format_bytes(bytes)
        format("%.1f MiB", bytes.to_i / 1024.0 / 1024)
      end
    end
  end
end

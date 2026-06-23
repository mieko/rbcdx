require "csv"
require "json"
require "optparse"

module CDX
  class CLI
    FORMATS = %w[jsonl text csv].freeze
    DATA_FORMATS = %w[text jsonl].freeze

    def self.start(argv = ARGV, out: $stdout, err: $stderr, data_client: nil)
      new(argv.dup, out: out, err: err, data_client: data_client).run
    rescue ArgumentError, Error, OptionParser::ParseError => error
      err.puts "rbcdx: #{error.message}"
      1
    end

    def initialize(argv, out:, err:, data_client: nil)
      @argv = argv
      @out = out
      @err = err
      @data_client = data_client || CommonCrawlData.new
    end

    def run
      command = @argv.shift

      case command
      when "captures"
        run_captures
      when "count"
        run_count
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
          data = fields ? capture.slice(*fields) : capture.to_h
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
          csv << header.map { |field| capture[field] }
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
        opts.on("--filter FILTER", "pywb-style filter, for example '=status:200'") do |filter|
          options[:filters] << filter
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

    def query_options(options)
      {
        limit: options[:limit],
        from: options[:from],
        to: options[:to],
        closest: options[:closest],
        filters: options[:filters],
        match: options[:match],
        sort: options[:sort]
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

    def usage
      <<~USAGE
        Usage:
          rbcdx captures --index PATH [--limit N] [--filter '=status:200'] URL
          rbcdx count --index PATH URL
          rbcdx data list [--limit N]
          rbcdx data download --output DIR [--crawl CRAWL]

        PATH may be a CDX/CDXJ file, a .gz file, a glob, or a directory.
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
  end
end

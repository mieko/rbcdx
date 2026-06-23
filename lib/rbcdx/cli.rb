require "csv"
require "json"
require "optparse"

module CDX
  class CLI
    FORMATS = %w[jsonl text csv].freeze

    def self.start(argv = ARGV, out: $stdout, err: $stderr)
      new(argv.dup, out: out, err: err).run
    rescue ArgumentError, Error, OptionParser::ParseError => error
      err.puts "rbcdx: #{error.message}"
      1
    end

    def initialize(argv, out:, err:)
      @argv = argv
      @out = out
      @err = err
    end

    def run
      command = @argv.shift

      case command
      when "captures"
        run_captures
      when "count"
        run_count
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

    def usage
      <<~USAGE
        Usage:
          rbcdx captures --index PATH [--limit N] [--filter '=status:200'] URL
          rbcdx count --index PATH URL

        PATH may be a CDX/CDXJ file, a .gz file, a glob, or a directory.
      USAGE
    end
  end
end

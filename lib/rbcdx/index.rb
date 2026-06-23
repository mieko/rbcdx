require "zlib"

module CDX
  class Index
    include Enumerable

    INDEX_FILE_PATTERN = /(?:\.(?:cdx|cdxj)(?:\.gz)?|\Acdx-\d+\.gz)\z/i

    attr_reader :paths

    def self.open(*paths, **options)
      index = new(paths.flatten, **options)
      return index unless block_given?

      yield index
    end

    def initialize(paths, parser: nil)
      @paths = expand_paths(paths)
      raise ArgumentError, "no local CDX/CDXJ paths were provided" if @paths.empty?

      @parser_factory = parser || -> { Parser.new }
    end

    def each
      return enum_for(:each) unless block_given?

      each_capture { |capture| yield capture }
      self
    end

    def captures(url = nil, limit: nil, from: nil, to: nil, filters: nil, fields: nil,
      closest: nil, match: nil, sort: nil, &block)
      enum = Enumerator.new do |yielder|
        run_query(
          yielder,
          url: url,
          limit: limit,
          from: from,
          to: to,
          filters: filters,
          fields: fields,
          closest: closest,
          match: match,
          sort: sort
        )
      end

      return enum unless block

      enum.each(&block)
      self
    end

    private

    def run_query(yielder, url:, limit:, from:, to:, filters:, fields:, closest:, match:, sort:)
      matcher = UrlMatcher.new(url, match: match) if url
      checks = Filter.build(filter_list(filters))
      limit = Integer(limit) if limit
      sort = validate_sort(sort)

      if closest || sort
        captures = matching_captures(matcher, checks, from, to)
        captures = sort_captures(captures, closest: closest, sort: sort)
        captures = captures.first(limit) if limit
        captures.each { |capture| yielder << project(capture, fields) }
        return
      end

      yielded = 0
      each_capture do |capture|
        next unless capture_matches?(capture, matcher, checks, from, to)

        yielder << project(capture, fields)
        yielded += 1
        break if limit && yielded >= limit
      end
    end

    def matching_captures(matcher, checks, from, to)
      matches = []
      each_capture do |capture|
        matches << capture if capture_matches?(capture, matcher, checks, from, to)
      end
      matches
    end

    def filter_list(filters)
      case filters
      when nil
        []
      when Array
        filters
      else
        [filters]
      end
    end

    def sort_captures(captures, closest:, sort:)
      if closest
        target = Timestamp.to_time(closest)
        return captures.sort_by do |capture|
          timestamp = Timestamp.to_time(capture.timestamp)
          [(timestamp - target).abs, capture.timestamp.to_s]
        end
      end

      case sort&.to_sym
      when :timestamp
        captures.sort_by { |capture| capture.timestamp.to_s }
      when :reverse_timestamp
        captures.sort_by { |capture| capture.timestamp.to_s }.reverse
      when nil
        captures
      else
        raise ArgumentError, "unsupported sort: #{sort.inspect}"
      end
    end

    def project(capture, fields)
      fields ? capture.with_fields(*Array(fields)) : capture
    end

    def validate_sort(sort)
      return nil if sort.nil?

      sort = sort.to_sym
      return sort if %i[timestamp reverse_timestamp].include?(sort)

      raise ArgumentError, "unsupported sort: #{sort.inspect}"
    end

    def capture_matches?(capture, matcher, checks, from, to)
      return false if matcher && !matcher.match?(capture)
      return false unless Timestamp.in_range?(capture.timestamp, from: from, to: to)

      checks.all? { |check| check.call(capture) }
    end

    def each_capture
      paths.each do |path|
        parser = @parser_factory.call
        open_path(path) do |io|
          io.each_line.with_index(1) do |line, line_number|
            data = parser.parse(line)
            next unless data

            yield Capture.new(data, source_path: path, line_number: line_number)
          end
        end
      end
    end

    def open_path(path)
      if path.end_with?(".gz")
        Zlib::GzipReader.open(path) { |gzip| yield gzip }
      else
        File.open(path, "r:utf-8") { |file| yield file }
      end
    end

    def expand_paths(paths)
      Array(paths).flatten.compact.flat_map do |path|
        string = path.to_s
        expanded = Dir.glob(File.expand_path(string))
        if expanded.empty? || !glob_pattern?(string)
          expand_explicit_path(File.expand_path(string))
        else
          expanded.flat_map { |entry| expand_discovered_entry(entry) }
        end
      end.uniq.sort
    end

    def glob_pattern?(path)
      path.match?(/[*?\[\]{}]/)
    end

    def expand_explicit_path(entry)
      if File.directory?(entry)
        expand_directory(entry)
      elsif File.file?(entry)
        validate_index_file!(entry)
        [entry]
      else
        raise ArgumentError, "CDX/CDXJ path does not exist: #{entry}"
      end
    end

    def expand_discovered_entry(entry)
      if File.directory?(entry)
        expand_directory(entry)
      elsif File.file?(entry)
        index_file?(entry) ? [entry] : []
      else
        []
      end
    end

    def expand_directory(entry)
      Dir.glob(File.join(entry, "**", "*")).select do |path|
        File.file?(path) && index_file?(path)
      end
    end

    def validate_index_file!(path)
      return if index_file?(path)

      raise ArgumentError, "not a supported CDX/CDXJ index file: #{path}"
    end

    def index_file?(path)
      File.basename(path).match?(INDEX_FILE_PATTERN)
    end
  end
end

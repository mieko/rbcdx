require "stringio"
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
      @zipnum_indexes = ZipNumIndex.find_all(@paths)
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
      each_capture(matcher: matcher) do |capture|
        next unless capture_matches?(capture, matcher, checks, from, to)

        yielder << project(capture, fields)
        yielded += 1
        break if limit && yielded >= limit
      end
    end

    def matching_captures(matcher, checks, from, to)
      matches = []
      each_capture(matcher: matcher) do |capture|
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

    def each_capture(matcher: nil)
      if matcher && @zipnum_indexes.any?
        zipnum_by_path = @zipnum_indexes.each_with_object({}) do |index, indexes|
          index.paths.each { |path| indexes[path] = index }
        end
        paths.each do |path|
          if (index = zipnum_by_path[path])
            index.captures_for(matcher, parser_factory: @parser_factory, path: path) { |capture| yield capture }
          else
            each_capture_from_paths([path]) { |capture| yield capture }
          end
        end
      else
        each_capture_from_paths(paths) { |capture| yield capture }
      end
    end

    def each_capture_from_paths(paths)
      paths.each do |path|
        parser = @parser_factory.call
        line_number = 0
        open_path(path) do |io|
          io.each_line do |line|
            line_number += 1
            data = parser.parse(line)
            next unless data

            yield Capture.new(data, source_path: path, line_number: line_number)
          end
        end
      end
    end

    def open_path(path)
      if path.end_with?(".gz")
        open_gzip_path(path) { |gzip| yield gzip }
      else
        File.open(path, "r:utf-8") { |file| yield file }
      end
    end

    def open_gzip_path(path)
      File.open(path, "rb") do |file|
        unused = nil
        until file.eof? && unused.to_s.empty?
          gzip = Zlib::GzipReader.new(PrependedIO.new(unused, file))
          yield gzip
          unused = gzip.unused
          gzip.finish
        end
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

    class PrependedIO
      def initialize(prefix, io)
        @prefix = StringIO.new(prefix.to_s)
        @io = io
      end

      def read(length = nil, outbuf = nil)
        data = length ? read_length(length) : @prefix.read.to_s + @io.read.to_s
        outbuf.replace(data) if outbuf && data
        data
      end

      def readpartial(length, outbuf = nil)
        data = read(length)
        raise EOFError unless data

        outbuf&.replace(data)
        data
      end

      def eof?
        @prefix.eof? && @io.eof?
      end

      private

      def read_length(length)
        data = +""
        while data.bytesize < length
          source = @prefix.eof? ? @io : @prefix
          chunk = source.read(length - data.bytesize)
          break unless chunk

          data << chunk
        end
        data.empty? ? nil : data
      end
    end
  end
end

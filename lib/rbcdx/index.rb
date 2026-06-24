module CDX
  class Index
    include Enumerable

    BACKENDS = [
      Backends::CDXJ,
      Backends::RbCDX
    ].freeze
    CURSOR_UNSET = Object.new.freeze

    attr_reader :paths

    def self.open(*paths, **options)
      index = new(paths.flatten, **options)
      return index unless block_given?

      yield index
    end

    def initialize(paths, parser: nil)
      @paths = expand_paths(paths)
      raise ArgumentError, "no local index paths were provided" if @paths.empty?

      @parser_factory = parser || -> { Backends::CDXJ::Parser.new }
      @backend = backend_for(@paths).new(@paths, parser_factory: @parser_factory)
    end

    def each
      return enum_for(:each) unless block_given?

      each_capture { |capture| yield capture }
      self
    end

    def captures(url = nil, limit: nil, from: nil, to: nil, filters: nil, fields: nil,
      closest: nil, match: nil, sort: nil, page_size: nil, cursor: CURSOR_UNSET,
      filter_signature: nil, &block)
      unless page_size.nil?
        page = run_page_query(
          url: url,
          limit: limit,
          from: from,
          to: to,
          filters: filters,
          fields: fields,
          closest: closest,
          match: match,
          sort: sort,
          page_size: page_size,
          cursor: cursor,
          filter_signature: filter_signature
        )
        return page unless block

        page.each(&block)
        return page
      end

      raise ArgumentError, "cursor requires page_size" unless cursor.equal?(CURSOR_UNSET)
      raise ArgumentError, "filter_signature requires page_size" unless filter_signature.nil?

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

    def run_page_query(url:, limit:, from:, to:, filters:, fields:, closest:, match:, sort:, page_size:, cursor:, filter_signature:)
      raise ArgumentError, "choose limit or page_size, not both" unless limit.nil?
      raise UnsupportedPageQuery, "sort is not supported for cursor pages" unless sort.nil?
      raise UnsupportedPageQuery, "closest is not supported for cursor pages" unless closest.nil?
      raise UnsupportedPageQuery, "cursor pages are only supported for .rbcdx indexes" unless @backend.capture_pages_supported?

      page_size = normalize_page_size(page_size)
      matcher = UrlMatcher.new(url, match: match) if url
      stable_filters = stable_filter_signature(filters, filter_signature)
      checks = Filter.build(filter_list(filters))
      query_digest = CaptureCursor.digest(page_query_signature(url, matcher, from, to, stable_filters))
      index_digest = CaptureCursor.digest(@backend.capture_page_fingerprint)
      cursor = cursor.equal?(CURSOR_UNSET) ? nil : CaptureCursor.coerce(cursor)
      position = page_cursor_position(cursor, index_digest, query_digest)

      captures = []
      next_cursor = nil
      @backend.each_page_candidate(matcher: matcher, position: position) do |capture, candidate_position|
        next unless capture_matches?(capture, matcher, checks, from, to)

        if captures.length < page_size
          captures << project(capture, fields)
        else
          next_cursor = build_capture_cursor(index_digest, query_digest, candidate_position)
          break
        end
      end

      CapturePage.new(captures, next_cursor: next_cursor)
    end

    def normalize_page_size(page_size)
      string = page_size.to_s
      raise ArgumentError, "page_size must be a positive integer" unless string.match?(/\A\d+\z/)

      value = string.to_i
      raise ArgumentError, "page_size must be a positive integer" unless value.positive?

      value
    end

    def run_query(yielder, url:, limit:, from:, to:, filters:, fields:, closest:, match:, sort:)
      matcher = UrlMatcher.new(url, match: match) if url
      checks = Filter.build(filter_list(filters))
      limit = normalize_limit(limit)
      sort = validate_sort(sort)
      return if limit&.zero?

      if closest || sort
        captures = sorted_matching_captures(matcher, checks, from, to, closest: closest, sort: sort, limit: limit)
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

    def each_matching_capture(matcher, checks, from, to)
      return enum_for(:each_matching_capture, matcher, checks, from, to) unless block_given?

      each_capture(matcher: matcher) do |capture|
        next unless capture_matches?(capture, matcher, checks, from, to)

        yield capture
      end
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

    def stable_filter_signature(filters, filter_signature)
      stable = []
      unstable = false

      filter_list(filters).each do |filter|
        term = stable_filter_term(filter)
        if term
          stable << term
        else
          unstable = true
        end
      end

      if unstable && filter_signature.nil?
        raise UnsupportedPageQuery, "filter_signature is required for Proc or custom filters in cursor pages"
      end

      signature = {"stable" => stable}
      signature["unstable_count"] = filter_list(filters).length - stable.length
      signature["custom"] = CaptureCursor.canonical_value(filter_signature) unless filter_signature.nil?
      signature
    end

    def stable_filter_term(filter)
      case filter
      when Filter
        expression = stable_filter_value(filter.expression)
        return unless expression

        {"type" => "filter", "field" => filter.field, "modifier" => filter.modifier, "expression" => expression}
      when String
        stable_filter_term(Filter.parse(filter))
      when Hash
        entries = []
        filter.each do |field, expected|
          value = stable_filter_value(expected)
          unless value
            entries = nil
            break
          end

          entries << [field.to_s, value]
        end
        return unless entries

        {"type" => "hash", "entries" => entries.sort_by(&:first)}
      when Proc
        nil
      end
    end

    def stable_filter_value(value)
      case value
      when Regexp
        {"type" => "regexp", "source" => value.source, "options" => value.options}
      when Array
        values = value.map { |item| stable_filter_value(item) }
        return if values.any?(&:nil?)

        {"type" => "array", "values" => values}
      when String, Symbol, Integer, Float, TrueClass, FalseClass, NilClass
        {"type" => "value", "value" => value.to_s}
      end
    end

    def page_query_signature(url, matcher, from, to, stable_filters)
      {
        "cursor_version" => CaptureCursor::VERSION,
        "url" => url&.to_s,
        "match" => matcher&.match&.to_s,
        "from" => Timestamp.normalize(from),
        "to" => Timestamp.normalize(to, high: true),
        "filters" => stable_filters
      }
    end

    def page_cursor_position(cursor, index_digest, query_digest)
      return unless cursor

      CaptureCursor.__send__(
        :extract_position,
        cursor,
        backend: @backend.capture_page_backend,
        backend_version: @backend.capture_page_cursor_version,
        index_digest: index_digest,
        query_digest: query_digest
      )
    end

    def build_capture_cursor(index_digest, query_digest, position)
      CaptureCursor.new(
        "version" => CaptureCursor::VERSION,
        "backend" => @backend.capture_page_backend,
        "backend_version" => @backend.capture_page_cursor_version,
        "index" => index_digest,
        "query" => query_digest,
        "position" => position
      )
    end

    def sort_captures(captures, closest:, sort:)
      key = sort_key_for(closest: closest, sort: sort)
      return captures.sort_by(&key) if closest

      case sort&.to_sym
      when :timestamp
        captures.sort_by(&key)
      when :reverse_timestamp
        captures.sort_by(&key).reverse
      when nil
        captures
      else
        raise ArgumentError, "unsupported sort: #{sort.inspect}"
      end
    end

    def sorted_matching_captures(matcher, checks, from, to, closest:, sort:, limit:)
      captures = each_matching_capture(matcher, checks, from, to)
      key = sort_key_for(closest: closest, sort: sort)
      return sort_captures(captures.to_a, closest: closest, sort: sort) unless limit
      return limited_reverse_sorted_captures(captures, limit, key) if sort&.to_sym == :reverse_timestamp && !closest

      captures.each_with_index
        .min_by(limit) { |capture, sequence| [key.call(capture), sequence] }
        .sort_by { |capture, sequence| [key.call(capture), sequence] }
        .map(&:first)
    end

    def limited_reverse_sorted_captures(captures, limit, key)
      captures.each_with_index
        .max_by(limit) { |capture, sequence| [key.call(capture), sequence] }
        .sort_by { |capture, sequence| [key.call(capture), sequence] }
        .reverse
        .map(&:first)
    end

    def sort_key_for(closest:, sort:)
      if closest
        target = Timestamp.to_time(closest)
        return lambda do |capture|
          timestamp = Timestamp.to_time(capture.timestamp)
          [(timestamp - target).abs, capture.timestamp.to_s]
        end
      end

      case sort&.to_sym
      when :timestamp, :reverse_timestamp
        ->(capture) { capture.timestamp.to_s }
      when nil
        -> {}
      else
        raise ArgumentError, "unsupported sort: #{sort.inspect}"
      end
    end

    def normalize_limit(limit)
      return nil if limit.nil?

      string = limit.to_s
      raise ArgumentError, "limit must be a non-negative integer" unless string.match?(/\A\d+\z/)

      string.to_i
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
      @backend.each_capture(matcher: matcher) { |capture| yield capture }
    end

    def expand_paths(paths)
      expanded = Array(paths).flatten.compact.flat_map do |path|
        string = path.to_s
        expanded = Dir.glob(File.expand_path(string))
        if expanded.empty? || !glob_pattern?(string)
          expand_explicit_path(File.expand_path(string))
        else
          expanded.flat_map { |entry| expand_discovered_entry(entry) }
        end
      end.uniq.sort
      validate_backend_mix!(expanded)
      expanded
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
        raise ArgumentError, "index path does not exist: #{entry}"
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
      files = Dir.glob(File.join(entry, "**", "*")).select { |path| File.file?(path) }
      validate_local_directory_mix!(files)
      files.select do |path|
        index_file?(path)
      end
    end

    def validate_index_file!(path)
      return if index_file?(path)

      raise ArgumentError, "not a supported local index file: #{path}"
    end

    def index_file?(path)
      BACKENDS.any? { |backend| backend.index_file?(path) }
    end

    def backend_for(paths)
      matching_backends = BACKENDS.select do |backend|
        paths.any? { |path| backend.index_file?(path) }
      end

      return matching_backends.first if matching_backends.length == 1

      names = matching_backends.map { |backend| backend.name.split("::").last }.join(", ")
      raise ArgumentError, "cannot mix local index formats in one CDX::Index: #{names}"
    end

    def validate_backend_mix!(paths)
      return if paths.empty?

      backend_for(paths)
    end

    def validate_local_directory_mix!(files)
      files.group_by { |path| File.dirname(path) }.each do |dir, dir_files|
        has_cdx_gzip = dir_files.any? { |path| Backends::CDXJ.index_file?(path) && File.basename(path).end_with?(".gz") }
        has_rbcdx = dir_files.any? { |path| Backends::RbCDX.index_file?(path) }
        next unless has_cdx_gzip && has_rbcdx

        raise ArgumentError, "cannot mix CDX .gz and .rbcdx index files in the same directory: #{dir}"
      end
    end
  end
end

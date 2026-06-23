require "uri"

module CDX
  module HTTP
    COMMON_CRAWL_BASE_URL = "https://data.commoncrawl.org"
    COMMON_CRAWL_PATTERN = %r{(?:\A|/)(?:crawl-data|cc-index/collections)/CC-MAIN-\d{4}-\d{2}(?:/|\z)}

    class UnrequestableCapture < CDX::Error
      attr_reader :capture, :missing_fields

      def initialize(capture, missing_fields)
        @capture = capture
        @missing_fields = missing_fields
        super("capture cannot be fetched as an HTTP range request; missing or invalid fields: #{missing_fields.join(", ")}")
      end
    end

    class RemoteArchive
      attr_reader :index

      def initialize(index, base_url: nil)
        @index = index
        @base_uri = base_url ? normalize_base_url(base_url) : infer_base_uri_from_index
      end

      def requests(url = nil, limit: nil, from: nil, to: nil, filters: nil, fields: nil,
        closest: nil, match: nil, sort: nil, on_missing: :raise, &block)
        raise ArgumentError, "fields is not supported for HTTP requests" unless fields.nil?

        on_missing = validate_on_missing(on_missing)
        enum = Enumerator.new do |yielder|
          index.captures(
            url,
            limit: limit,
            from: from,
            to: to,
            filters: filters,
            closest: closest,
            match: match,
            sort: sort
          ).each do |capture|
            request = request_for(capture, on_missing: on_missing)
            yielder << request if request
          end
        end

        return enum unless block

        enum.each(&block)
        self
      end

      private

      def normalize_base_url(base_url)
        uri = URI(base_url.to_s)
        unless uri.is_a?(URI::HTTP) && uri.host
          raise ArgumentError, "base_url must be an absolute http or https URL"
        end

        if uri.query || uri.fragment
          raise ArgumentError, "base_url must not include a query string or fragment"
        end

        uri.path = normalized_base_path(uri.path)
        uri
      rescue URI::InvalidURIError
        raise ArgumentError, "base_url must be an absolute http or https URL"
      end

      def normalized_base_path(path)
        path = path.to_s.sub(%r{/+\z}, "")
        path.empty? ? "" : path
      end

      def validate_on_missing(on_missing)
        value = on_missing.to_sym
        return value if %i[raise skip].include?(value)

        raise ArgumentError, "unsupported on_missing: #{on_missing.inspect}"
      rescue NoMethodError
        raise ArgumentError, "unsupported on_missing: #{on_missing.inspect}"
      end

      def request_for(capture, on_missing:)
        Request.new(capture: capture, base_uri: base_uri_for(capture))
      rescue UnrequestableCapture => error
        raise error if on_missing == :raise
      rescue ArgumentError
        error = unrequestable_error(capture)
        raise unless error
        raise error if on_missing == :raise
      end

      def base_uri_for(capture)
        return @base_uri if @base_uri
        return common_crawl_base_uri if common_crawl_capture?(capture)

        raise ArgumentError, "base_url is required for captures that are not recognized as Common Crawl records"
      end

      def infer_base_uri_from_index
        return unless index.respond_to?(:paths)
        return unless index.paths.any? { |path| common_crawl_path?(path) }

        common_crawl_base_uri
      end

      def common_crawl_capture?(capture)
        common_crawl_path?(capture.filename)
      end

      def common_crawl_path?(path)
        path.to_s.match?(COMMON_CRAWL_PATTERN)
      end

      def common_crawl_base_uri
        normalize_base_url(COMMON_CRAWL_BASE_URL)
      end

      def unrequestable_error(capture)
        missing_fields = Request.missing_fields(capture)
        return if missing_fields.empty?

        UnrequestableCapture.new(capture, missing_fields)
      end
    end

    class Request
      HTTP_METHOD = "GET"

      attr_reader :capture, :filename, :offset, :length, :range, :range_header_value,
        :url, :origin, :scheme, :host, :port, :path, :query, :request_uri, :headers

      def initialize(capture:, base_uri:)
        @capture = capture
        validate_capture!

        @filename = capture.filename.to_s.dup.freeze
        @offset = capture.warc_offset
        @length = capture.warc_length
        @range = offset..(offset + length - 1)
        @range_header_value = "bytes=#{range.begin}-#{range.end}".freeze
        @headers = {"Range" => range_header_value}.freeze
        @uri = build_uri(base_uri, filename).freeze
        cache_uri_parts
        freeze
      end

      def uri
        @uri.dup
      end

      def https?
        scheme == "https"
      end

      def http_method
        HTTP_METHOD
      end

      def to_h
        {
          method: http_method,
          url: url,
          uri: uri,
          scheme: scheme,
          host: host,
          port: port,
          origin: origin,
          path: path,
          query: query,
          request_uri: request_uri,
          https: https?,
          headers: headers,
          filename: filename,
          offset: offset,
          length: length,
          range: range,
          range_header_value: range_header_value
        }
      end

      def self.missing_fields(capture)
        missing_fields = []
        missing_fields << "filename" if capture.filename.to_s.empty?
        missing_fields << "offset" unless capture.warc_offset && capture.warc_offset >= 0
        missing_fields << "length" unless capture.warc_length&.positive?
        missing_fields
      end

      private

      def validate_capture!
        missing_fields = self.class.missing_fields(capture)
        return if missing_fields.empty?

        raise UnrequestableCapture.new(capture, missing_fields)
      end

      def cache_uri_parts
        @url = @uri.to_s.freeze
        @scheme = @uri.scheme.dup.freeze
        @host = @uri.host.dup.freeze
        @port = @uri.port
        @path = @uri.path.dup.freeze
        @query = @uri.query&.dup&.freeze
        @request_uri = @uri.request_uri.dup.freeze
        @origin = build_origin(@uri).freeze
      end

      def build_uri(base_uri, filename)
        uri = base_uri.dup
        uri.path = join_paths(base_uri.path, filename)
        uri
      end

      def build_origin(uri)
        origin_uri = uri.dup
        origin_uri.path = ""
        origin_uri.query = nil
        origin_uri.fragment = nil
        origin_uri.to_s
      end

      def join_paths(base_path, filename)
        parts = [base_path, filename].map { |part| part.to_s.sub(%r{\A/+}, "").sub(%r{/+\z}, "") }.reject(&:empty?)
        "/#{parts.join("/")}"
      end
    end
  end
end

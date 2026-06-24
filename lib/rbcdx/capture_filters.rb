require "uri"

module CDX
  module CaptureFilters
    VOCABULARY_VERSION = 1

    TEXT_LIKE_MIME_TYPES = %w[
      text/plain
      text/html
      text/xml
      application/xml
      application/xhtml+xml
      application/rss+xml
      application/atom+xml
      application/rdf+xml
      text/markdown
      text/x-markdown
      text/x-web-markdown
    ].freeze

    XML_LIKE_MIME_TYPES = %w[
      text/xml
      application/xml
    ].freeze

    ASSET_MIME_TYPES = %w[
      application/javascript
      application/ecmascript
      application/font-woff
      application/font-woff2
      application/pdf
      application/vnd.ms-fontobject
      application/x-font-ttf
      application/x-javascript
      image/svg+xml
      text/css
      text/javascript
      text/ecmascript
    ].freeze

    ASSET_MIME_PREFIXES = %w[
      audio/
      font/
      image/
      video/
    ].freeze

    ASSET_PATH_EXTENSIONS = %w[
      .7z
      .avi
      .avif
      .bmp
      .br
      .css
      .eot
      .gif
      .gz
      .ico
      .jpeg
      .jpg
      .js
      .json
      .map
      .mjs
      .mov
      .mp3
      .mp4
      .otf
      .pdf
      .png
      .rar
      .svg
      .tar
      .tgz
      .ttf
      .wasm
      .webm
      .webp
      .woff
      .woff2
      .zip
    ].freeze

    SITE_METADATA_BASENAMES = %w[
      ads.txt
      app-ads.txt
      browserconfig.xml
      humans.txt
      manifest.json
      opensearch.xml
      robots.txt
      security.txt
      site.webmanifest
    ].freeze

    NAME_PATTERN = /\A[a-z][a-z0-9_]*\z/

    class Term
      attr_reader :name, :polarity

      def initialize(name:, polarity: true)
        @name = name.to_s
        @polarity = polarity == false ? false : true
        freeze
      end

      def positive?
        polarity
      end

      def stable_name
        positive? ? name : "-#{name}"
      end
    end

    DEFAULT_REGISTRY = {
      "status_200" => ->(record) { record.status.to_s == "200" },
      "html" => ->(record) { CaptureFilters.mime_types(record).include?("text/html") },
      "text_like" => ->(record) { CaptureFilters.text_like?(record) },
      "asset_like" => ->(record) { CaptureFilters.asset_like?(record) },
      "site_metadata" => ->(record) { CaptureFilters.site_metadata?(record) },
      "warc" => ->(record) { CaptureFilters.warc?(record) },
      "extractable_text" => ->(record) { CaptureFilters.extractable_text?(record) }
    }.freeze

    module_function

    def parse_expression(expression, registry: DEFAULT_REGISTRY, label: "capture filter")
      expression.to_s.split(",").map(&:strip).reject(&:empty?).map do |term|
        parse_term(term, registry: registry, label: label)
      end
    end

    def parse_term(term, registry: DEFAULT_REGISTRY, label: "capture filter")
      polarity = true
      name = term.to_s
      case name[0]
      when "+"
        name = name[1..].to_s
      when "-"
        polarity = false
        name = name[1..].to_s
      end
      raise ArgumentError, "empty #{label} term in #{term.inspect}" if name.empty?

      named_term(name, polarity: polarity, registry: registry, label: label)
    end

    def symbol_term(symbol, registry: DEFAULT_REGISTRY, label: "capture filter")
      named_term(symbol.to_s, registry: registry, label: label)
    end

    def named_term(name, polarity: true, registry: DEFAULT_REGISTRY, label: "capture filter")
      validate_name!(name, registry: registry, label: label)
      Term.new(name: name, polarity: polarity)
    end

    def build(filters, registry: DEFAULT_REGISTRY, label: "capture filter")
      Array(filters).compact.flat_map do |filter|
        case filter
        when Term
          [predicate(filter, registry: registry, label: label)]
        when Proc
          filter
        when String
          parse_expression(filter, registry: registry, label: label).map do |term|
            predicate(term, registry: registry, label: label)
          end
        when Symbol
          [predicate(symbol_term(filter, registry: registry, label: label), registry: registry, label: label)]
        else
          raise ArgumentError, "unsupported #{label}: #{filter.inspect}"
        end
      end
    end

    def stable_terms(values, label: "capture filter", registry: DEFAULT_REGISTRY)
      Array(values).compact.flat_map do |value|
        case value
        when Term
          validate_name!(value.name, registry: registry, label: label)
          value.stable_name
        when String
          parse_expression(value, registry: registry, label: label).map(&:stable_name)
        when Symbol
          symbol_term(value, registry: registry, label: label).stable_name
        else
          raise ArgumentError, "#{label} needs an explicit filter_signature for resumable repack"
        end
      end
    end

    def stable_terms?(values, registry: DEFAULT_REGISTRY)
      stable_terms(values, registry: registry)
      true
    rescue ArgumentError
      false
    end

    def predicate(term, registry: DEFAULT_REGISTRY, label: "capture filter")
      filter = named_filter(term.name, registry: registry, label: label)
      term.positive? ? filter : ->(record) { !filter.call(record) }
    end

    def names(registry = DEFAULT_REGISTRY)
      registry.keys.sort
    end

    def extractable_text?(record)
      record.status.to_s == "200" &&
        warc?(record) &&
        text_like?(record) &&
        !asset_like?(record) &&
        !site_metadata?(record)
    end

    def text_like?(record)
      mime_types(record).any? { |mime| TEXT_LIKE_MIME_TYPES.include?(mime) }
    end

    def asset_like?(record)
      mime_types(record).any? { |mime| asset_mime_type?(mime) } ||
        ASSET_PATH_EXTENSIONS.include?(File.extname(url_path(record)).downcase)
    end

    def asset_mime_type?(mime)
      ASSET_MIME_TYPES.include?(mime) ||
        ASSET_MIME_PREFIXES.any? { |prefix| mime.start_with?(prefix) }
    end

    def site_metadata?(record)
      path = url_path(record)
      basename = File.basename(path).downcase
      SITE_METADATA_BASENAMES.include?(basename) ||
        sitemap?(basename, record) ||
        path.downcase.start_with?("/.well-known/")
    end

    def sitemap?(basename, record)
      return false unless basename.include?("sitemap")

      basename.match?(/\.xml(?:\.gz)?\z/) || mime_types(record).any? { |mime| xml_like_mime_type?(mime) }
    end

    def xml_like_mime_type?(mime)
      XML_LIKE_MIME_TYPES.include?(mime) || mime.end_with?("+xml")
    end

    def warc?(record)
      record.filename.to_s.include?("/warc/")
    end

    def mime_types(record)
      [record.mime, record.mime_detected]
        .compact
        .map { |mime| mime.to_s.split(";", 2).first.to_s.strip.downcase }
        .reject(&:empty?)
    end

    def url_path(record)
      URI.parse(record.url.to_s).path.to_s
    rescue URI::InvalidURIError
      record.url.to_s.split(/[?#]/, 2).first.to_s
    end

    def keep?(filters, record)
      filters.all? { |filter| filter.call(record) }
    end

    def named_filter(name, registry: DEFAULT_REGISTRY, label: "capture filter")
      validate_name!(name, registry: registry, label: label)
      filter = registry.fetch(name.to_s)
      raise ArgumentError, "#{label} #{name.inspect} is not callable" unless filter.respond_to?(:call)

      filter
    end

    def validate_name!(name, registry: DEFAULT_REGISTRY, label: "capture filter")
      string = name.to_s
      unless string.match?(NAME_PATTERN) && registry.key?(string)
        raise ArgumentError, "unknown #{label} #{string.inspect}; available filters: #{names(registry).join(", ")}"
      end
    end
  end
end

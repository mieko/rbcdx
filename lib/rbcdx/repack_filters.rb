require "uri"

module CDX
  module RepackFilters
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

    DEFAULT_REGISTRY = {
      "status-200" => ->(record) { record.status.to_s == "200" },
      "html" => ->(record) { RepackFilters.mime_types(record).include?("text/html") },
      "text-like" => ->(record) { RepackFilters.text_like?(record) },
      "asset-like" => ->(record) { RepackFilters.asset_like?(record) },
      "site-metadata" => ->(record) { RepackFilters.site_metadata?(record) },
      "warc" => ->(record) { RepackFilters.warc?(record) },
      "extractable-text" => ->(record) { RepackFilters.extractable_text?(record) }
    }.freeze

    module_function

    def build(filters, registry: DEFAULT_REGISTRY, where: nil)
      Array(filters).compact.flat_map do |filter|
        case filter
        when Proc
          filter
        when String, Symbol
          parse_expression(filter.to_s, registry)
        else
          raise ArgumentError, "unsupported repack filter: #{filter.inspect}"
        end
      end + build_where(where)
    end

    def build_where(filters)
      Filter.build(filters).map { |filter| ->(record) { filter.call(record) } }
    end

    def stable_signature(filters: nil, where: nil, filter_signature: nil)
      return filter_signature if filter_signature

      {
        "filters" => stable_terms(filters, "repack filter"),
        "where" => stable_terms(where, "where filter")
      }
    end

    def stable_signature?(filters: nil, where: nil)
      stable_terms?(filters) && stable_terms?(where)
    end

    def stable_terms(values, label)
      Array(values).compact.map do |value|
        case value
        when String, Symbol
          value.to_s
        else
          raise ArgumentError, "#{label} needs an explicit filter_signature for resumable repack"
        end
      end
    end

    def stable_terms?(values)
      Array(values).compact.all? { |value| value.is_a?(String) || value.is_a?(Symbol) }
    end

    def parse_expression(expression, registry)
      expression.split(",").map(&:strip).reject(&:empty?).map do |term|
        parse_term(term, registry)
      end
    end

    def parse_term(term, registry)
      polarity = true
      name = term
      case term[0]
      when "+"
        name = term[1..].to_s
      when "-"
        polarity = false
        name = term[1..].to_s
      end
      raise ArgumentError, "empty repack filter term in #{term.inspect}" if name.empty?

      filter = named_filter(name, registry)
      polarity ? filter : ->(record) { !filter.call(record) }
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

    def named_filter(name, registry)
      filter = registry.fetch(name) do
        raise ArgumentError, "unknown repack filter #{name.inspect}; available filters: #{names(registry).join(", ")}"
      end
      raise ArgumentError, "repack filter #{name.inspect} is not callable" unless filter.respond_to?(:call)

      filter
    end
  end
end

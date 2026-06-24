module CDX
  module RepackFilters
    DEFAULT_REGISTRY = CaptureFilters::DEFAULT_REGISTRY

    module_function

    def build(filters, registry: DEFAULT_REGISTRY, where: nil, only_url_files: nil, only_url_filter: nil)
      checks = CaptureFilters.build(filters, registry: registry, label: "repack filter") + build_where(where)
      only_urls = only_url_filter || only_url_filter_from_files(only_url_files)
      checks << only_urls if only_urls
      checks
    end

    def build_where(filters)
      Filter.build(filters).map { |filter| ->(record) { filter.call(record) } }
    end

    def stable_signature(filters: nil, where: nil, filter_signature: nil, registry: DEFAULT_REGISTRY, only_url_files: nil, only_url_filter: nil)
      only_urls = only_url_filter || only_url_filter_from_files(only_url_files)
      if filter_signature
        return filter_signature unless only_urls

        return {
          "custom" => filter_signature,
          "only_url_files" => only_urls.signature
        }
      end

      filter_terms = stable_terms(filters, "repack filter", registry: registry)
      signature = {
        "filters" => filter_terms,
        "where" => stable_terms(where, "where filter")
      }
      signature["only_url_files"] = only_urls.signature if only_urls
      signature["named_filter_version"] = CaptureFilters::VOCABULARY_VERSION if filter_terms.any? && registry.equal?(DEFAULT_REGISTRY)
      signature
    end

    def stable_signature?(filters: nil, where: nil, registry: DEFAULT_REGISTRY, only_url_files: nil)
      stable_signature(filters: filters, where: where, registry: registry, only_url_files: only_url_files)
      true
    rescue ArgumentError
      false
    end

    def stable_terms(values, label, registry: DEFAULT_REGISTRY)
      return CaptureFilters.stable_terms(values, label: label, registry: registry) if label == "repack filter"

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
      stable_terms(values, "repack filter")
      true
    rescue ArgumentError
      false
    end

    def only_url_filter_from_files(only_url_files)
      return if only_url_files.nil?

      OnlyUrlFilter.from_files(only_url_files)
    end

    def parse_expression(expression, registry)
      CaptureFilters.parse_expression(expression, registry: registry, label: "repack filter").map do |term|
        CaptureFilters.predicate(term, registry: registry, label: "repack filter")
      end
    end

    def parse_term(term, registry)
      parsed = CaptureFilters.parse_term(term, registry: registry, label: "repack filter")
      CaptureFilters.predicate(parsed, registry: registry, label: "repack filter")
    end

    def names(registry = DEFAULT_REGISTRY)
      CaptureFilters.names(registry)
    end

    def extractable_text?(record)
      CaptureFilters.extractable_text?(record)
    end

    def text_like?(record)
      CaptureFilters.text_like?(record)
    end

    def asset_like?(record)
      CaptureFilters.asset_like?(record)
    end

    def asset_mime_type?(mime)
      CaptureFilters.asset_mime_type?(mime)
    end

    def site_metadata?(record)
      CaptureFilters.site_metadata?(record)
    end

    def sitemap?(basename, record)
      CaptureFilters.sitemap?(basename, record)
    end

    def xml_like_mime_type?(mime)
      CaptureFilters.xml_like_mime_type?(mime)
    end

    def warc?(record)
      CaptureFilters.warc?(record)
    end

    def mime_types(record)
      CaptureFilters.mime_types(record)
    end

    def url_path(record)
      CaptureFilters.url_path(record)
    end

    def keep?(filters, record)
      CaptureFilters.keep?(filters, record)
    end

    def named_filter(name, registry)
      CaptureFilters.named_filter(name, registry: registry, label: "repack filter")
    end
  end
end

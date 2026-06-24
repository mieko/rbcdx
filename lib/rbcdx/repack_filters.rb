module CDX
  module RepackFilters
    Record = Struct.new(:source_path, :line_number, :urlkey, :timestamp, :fields) do
      def [](field)
        case field.to_s
        when "urlkey"
          urlkey
        when "timestamp"
          timestamp
        else
          fields[field.to_s]
        end
      end

      def fetch(field, *fallback, &block)
        return self[field] if key?(field)
        return fallback.first unless fallback.empty?
        return yield field if block

        raise KeyError, "key not found: #{field.inspect}"
      end

      def key?(field)
        %w[urlkey timestamp].include?(field.to_s) || fields.key?(field.to_s)
      end

      def to_h
        fields.merge(
          "urlkey" => urlkey,
          "timestamp" => timestamp
        )
      end

      def field(field)
        self[CDX::Capture.field_name_for(field)]
      end
    end

    DEFAULT_REGISTRY = {
      "status-200" => ->(record) { record["status"].to_s == "200" },
      "html" => lambda { |record|
        [record["mime"], record["mime-detected"]].compact.any? do |mime|
          mime.to_s.split(";", 2).first == "text/html"
        end
      },
      "warc" => ->(record) { record["filename"].to_s.include?("/warc/") }
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

    def record(source_path:, line_number:, urlkey:, timestamp:, fields:)
      Record.new(source_path, line_number, urlkey, timestamp, fields.freeze)
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

module CDX
  module CaptureCollapse
    Config = Struct.new(:field, :order) do
      def signature
        {"field" => field.to_s, "order" => order.to_s}
      end
    end

    module_function

    def build(collapse:, collapse_order:)
      if collapse.nil?
        raise ArgumentError, "collapse_order requires collapse" unless collapse_order.nil?

        return nil
      end

      field = normalize(collapse, "collapse")
      order = normalize(collapse_order || :latest, "collapse_order")
      raise ArgumentError, "unsupported collapse: #{collapse.inspect}" unless field == "urlkey"
      raise ArgumentError, "unsupported collapse_order: #{collapse_order.inspect}" unless order == "latest"

      Config.new(field, order)
    end

    def better?(candidate, current, config)
      return true unless current

      case config.order.to_sym
      when :latest
        candidate.timestamp.to_s >= current.timestamp.to_s
      else
        raise ArgumentError, "unsupported collapse_order: #{config.order.inspect}"
      end
    end

    def normalize(value, label)
      case value
      when String, Symbol
        value.to_s
      else
        raise ArgumentError, "unsupported #{label}: #{value.inspect}"
      end
    end
    private_class_method :normalize
  end
end

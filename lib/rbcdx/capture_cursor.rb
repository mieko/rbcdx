require "base64"
require "digest"
require "json"

module CDX
  class CaptureCursor
    PREFIX = "cdxcur1_"
    VERSION = 1

    def self.coerce(cursor)
      case cursor
      when nil
        nil
      when self
        cursor
      when String
        parse(cursor)
      else
        raise InvalidCursor, "cursor must be a CDX::CaptureCursor or serialized cursor string"
      end
    end

    def self.parse(serialized)
      string = serialized.to_s
      raise InvalidCursor, "malformed capture cursor" unless string.start_with?(PREFIX)

      decoded = Base64.urlsafe_decode64(string.delete_prefix(PREFIX))
      wrapper = JSON.parse(decoded)
      raise InvalidCursor, "malformed capture cursor" unless wrapper.is_a?(Hash)

      payload = wrapper.fetch("payload")
      checksum = wrapper.fetch("checksum")
      raise InvalidCursor, "malformed capture cursor" unless checksum == digest(payload)

      new(payload)
    rescue InvalidCursor
      raise
    rescue ArgumentError, JSON::ParserError, KeyError, TypeError
      raise InvalidCursor, "malformed capture cursor"
    end

    def self.digest(value)
      Digest::SHA256.hexdigest(canonical_json(value))
    end

    def self.extract_position(cursor, backend:, backend_version:, index_digest:, query_digest:)
      payload = cursor.__send__(:payload)
      unless payload["backend"] == backend
        raise InvalidCursor, "capture cursor does not match this index backend"
      end
      unless payload["backend_version"] == backend_version
        raise InvalidCursor, "capture cursor does not match this backend cursor format"
      end
      unless payload["index"] == index_digest
        raise InvalidCursor, "capture cursor does not match this index"
      end
      unless payload["query"] == query_digest
        raise InvalidCursor, "capture cursor does not match this query"
      end

      payload.fetch("position")
    rescue KeyError, TypeError
      raise InvalidCursor, "malformed capture cursor"
    end

    def self.canonical_json(value)
      JSON.generate(canonical_value(value))
    end

    def self.canonical_value(value)
      case value
      when Hash
        value.keys.map(&:to_s).sort.each_with_object({}) do |key, result|
          result[key] = canonical_value(value.fetch(key) { value.fetch(key.to_sym) })
        end
      when Array
        value.map { |item| canonical_value(item) }
      when Symbol
        value.to_s
      else
        value
      end
    end

    def initialize(payload)
      @payload = deep_freeze(self.class.canonical_value(payload))
      version = @payload["version"]
      raise InvalidCursor, "unsupported capture cursor version #{version.inspect}" unless version == VERSION
    end

    def to_s
      wrapper = {
        "payload" => payload,
        "checksum" => self.class.digest(payload)
      }
      "#{PREFIX}#{Base64.urlsafe_encode64(JSON.generate(wrapper), padding: false)}"
    end

    private

    attr_reader :payload

    private_class_method :extract_position

    def deep_freeze(value)
      case value
      when Hash
        value.each_value { |item| deep_freeze(item) }
      when Array
        value.each { |item| deep_freeze(item) }
      end
      value.freeze
    end
  end
end

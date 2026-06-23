require "json"

module CDX
  class Parser
    FIELD_CODES = {
      "N" => "urlkey",
      "b" => "timestamp",
      "a" => "url",
      "m" => "mime",
      "s" => "status",
      "k" => "digest",
      "r" => "redirect",
      "M" => "meta",
      "S" => "length",
      "V" => "offset",
      "g" => "filename"
    }.freeze

    DEFAULT_CDX11_FIELDS = %w[
      urlkey timestamp url mime status digest redirect meta length offset filename
    ].freeze

    attr_reader :fields

    def initialize(fields: nil)
      @fields = fields || DEFAULT_CDX11_FIELDS
    end

    def parse(line)
      stripped = line.to_s.strip
      return nil if stripped.empty? || stripped.start_with?("#")

      if (match = stripped.match(/\A\s*CDX\s+(.+)\z/))
        @fields = match[1].split(/\s+/).map { |code| FIELD_CODES.fetch(code, code) }
        return nil
      end

      if stripped.start_with?("{")
        return JSON.parse(stripped)
      end

      if (data = parse_cdxj(stripped))
        return data
      end

      parse_cdx11(stripped)
    rescue JSON::ParserError => error
      raise ParseError, "invalid JSON in CDX row: #{error.message}"
    end

    private

    def parse_cdxj(line)
      urlkey, timestamp, json = line.split(/\s+/, 3)
      return nil unless json&.start_with?("{")

      data = JSON.parse(json)
      data["urlkey"] ||= urlkey
      data["timestamp"] ||= timestamp
      data
    end

    def parse_cdx11(line)
      values = line.split(/\s+/, @fields.length)
      if values.length < [2, @fields.length].min
        raise ParseError, "not enough fields in CDX row: #{line.inspect}"
      end

      @fields.zip(values).each_with_object({}) do |(field, value), data|
        data[field] = value unless field.nil? || value.nil?
      end
    end
  end
end

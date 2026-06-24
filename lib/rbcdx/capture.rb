module CDX
  class Capture
    FIELD_METHODS = {
      "urlkey" => :urlkey,
      "timestamp" => :timestamp,
      "url" => :url,
      "mime" => :mime,
      "mime-detected" => :mime_detected,
      "status" => :status,
      "digest" => :digest,
      "redirect" => :redirect,
      "meta" => :meta,
      "length" => :length,
      "offset" => :offset,
      "filename" => :filename
    }.freeze

    FIELD_NAMES_BY_METHOD = FIELD_METHODS.invert.freeze
    BUILTIN_METHOD_OWNERS = [BasicObject, Kernel, Object].freeze

    attr_reader :source_path, :line_number

    def self.field_name_for(field)
      value = field.to_s.strip
      return "" if value.empty?

      FIELD_NAMES_BY_METHOD.fetch(value.to_sym, value)
    end

    def self.field_names_for_method(method_name)
      name = method_name.to_s
      candidates = []
      candidates << FIELD_NAMES_BY_METHOD[method_name.to_sym]
      candidates << name
      candidates << name.tr("_", "-") if name.include?("_")
      candidates.compact.uniq
    end

    def self.method_name_for(field)
      field_name = field_name_for(field)
      return if field_name.empty?

      method_name = FIELD_METHODS.fetch(field_name, field_name.tr("-", "_").to_sym)
      method_name if method_name.to_s.match?(/\A[a-z_]\w*[!?]?\z/)
    end

    def self.known_field?(field)
      FIELD_METHODS.key?(field_name_for(field))
    end

    def self.normalize_field_names(fields)
      fields.flatten.flat_map { |field| field.to_s.split(",") }
        .map { |field| field_name_for(field) }
        .reject(&:empty?)
    end

    def initialize(data, source_path: nil, line_number: nil, fields: nil)
      @data = data.each_with_object({}) do |(key, value), normalized|
        normalized[key.to_s] = value
      end
      @field_names = self.class.normalize_field_names(fields || @data.keys)
      @source_path = source_path
      @line_number = line_number
    end

    def to_h
      @field_names.each_with_object({}) do |field, result|
        next unless field_materializable?(field)

        result[field] = self.field(field)
      end
    end

    def with_fields(*fields)
      data = self.class.normalize_field_names(fields).each_with_object({}) do |field, result|
        next unless field_materializable?(field)

        result[field] = self.field(field)
      end
      self.class.new(data, source_path: source_path, line_number: line_number, fields: data.keys)
    end

    def field(field)
      field = self.class.field_name_for(field)
      return if field.empty?
      return read_field(field) if field_available?(field)
      return unless method_field_materializable?(field)

      method_name = self.class.method_name_for(field)
      public_send(method_name)
    end

    def revisit?
      mime == "warc/revisit" || status == "-"
    end

    def urlkey
      read_field("urlkey")
    end

    def timestamp
      read_field("timestamp")
    end

    def url
      read_field("url")
    end

    def status
      read_field("status")
    end

    def mime
      read_field("mime")
    end

    def mime_detected
      read_field("mime-detected")
    end

    def digest
      read_field("digest")
    end

    def redirect
      read_field("redirect")
    end

    def meta
      read_field("meta")
    end

    def filename
      read_field("filename")
    end

    def offset
      read_field("offset")
    end

    def length
      read_field("length")
    end

    def warc_offset
      integer_or_nil(offset)
    end

    def warc_length
      integer_or_nil(length)
    end

    def warc_url(base_url: "https://data.commoncrawl.org")
      return unless filename

      "#{base_url.to_s.sub(%r{/+\z}, "")}/#{filename.to_s.sub(%r{\A/+}, "")}"
    end

    def byte_range
      return unless warc_offset && warc_length

      start = warc_offset
      finish = start + warc_length - 1
      start..finish
    end

    def respond_to_missing?(method_name, include_private = false)
      field_for_method(method_name) || super
    end

    private

    def field_materializable?(field)
      field = self.class.field_name_for(field)
      return false if field.empty?
      return true if field_available?(field)

      method_field_materializable?(field)
    end

    def method_field_materializable?(field)
      method_name = self.class.method_name_for(field)
      return false unless callable_field_method?(method_name)

      method_owner(method_name) != Capture || (self.class != Capture && self.class.known_field?(field))
    end

    def callable_field_method?(method_name)
      return false unless method_name && respond_to?(method_name)

      !BUILTIN_METHOD_OWNERS.include?(method_owner(method_name))
    rescue NameError
      false
    end

    def method_owner(method_name)
      method(method_name).owner
    end

    def method_missing(method_name, *arguments, &block)
      field = field_for_method(method_name)
      return read_field(field) if field && arguments.empty? && block.nil?

      super
    end

    def field_for_method(method_name)
      self.class.field_names_for_method(method_name).find { |field| field_available?(field) }
    end

    def field_available?(field)
      @data.key?(field.to_s)
    end

    def read_field(field)
      @data[field.to_s]
    end

    def integer_or_nil(value)
      return if value.nil?

      string = value.to_s
      return unless string.match?(/\A-?\d+\z/)

      string.to_i
    end
  end
end

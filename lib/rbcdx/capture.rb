module CDX
  class Capture
    include Enumerable

    attr_reader :source_path, :line_number

    def initialize(data, source_path: nil, line_number: nil)
      @data = data.each_with_object({}) do |(key, value), normalized|
        normalized[key.to_s] = value
      end
      @source_path = source_path
      @line_number = line_number
    end

    def [](key)
      @data[key.to_s]
    end

    def fetch(key, *default, &block)
      @data.fetch(key.to_s, *default, &block)
    end

    def key?(key)
      @data.key?(key.to_s)
    end
    alias_method :has_key?, :key?

    def each
      return enum_for(:each) unless block_given?

      @data.each { |key, value| yield key, value }
      self
    end

    def to_h
      @data.dup
    end
    alias_method :fields, :to_h

    def slice(*fields)
      wanted = fields.flatten.flat_map { |field| field.to_s.split(",") }.map(&:strip).reject(&:empty?)
      wanted.each_with_object({}) do |field, result|
        result[field] = @data[field] if @data.key?(field)
      end
    end

    def with_fields(*fields)
      self.class.new(slice(*fields), source_path: source_path, line_number: line_number)
    end

    def revisit?
      self["mime"] == "warc/revisit" || self["status"] == "-"
    end

    def urlkey
      self["urlkey"]
    end

    def timestamp
      self["timestamp"]
    end

    def url
      self["url"]
    end

    def status
      self["status"]
    end

    def mime
      self["mime"]
    end

    def mime_detected
      self["mime-detected"]
    end

    def digest
      self["digest"]
    end

    def filename
      self["filename"]
    end

    def offset
      self["offset"]
    end

    def warc_offset
      integer_or_nil(offset)
    end

    def warc_length
      integer_or_nil(self["length"])
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

    private

    def integer_or_nil(value)
      Integer(value)
    rescue ArgumentError, TypeError
      nil
    end
  end
end

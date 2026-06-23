module CDX
  class Filter
    PATTERN = /\A(?<modifier>!~|!=|=|~|!)?(?<field>[^:]+):(?<expression>.*)\z/

    def self.build(filters)
      Array(filters).compact.flat_map do |filter|
        case filter
        when self
          filter
        when String
          parse(filter)
        when Hash
          filter.map { |field, expected| from_hash(field, expected) }
        when Proc
          filter
        else
          raise ArgumentError, "unsupported filter: #{filter.inspect}"
        end
      end
    end

    def self.parse(filter)
      match = filter.match(PATTERN)
      raise ArgumentError, "invalid filter: #{filter.inspect}" unless match

      new(match[:field], match[:modifier] || "", match[:expression])
    end

    def self.from_hash(field, expected)
      case expected
      when Regexp
        new(field, "~", expected)
      when Array
        proc { |capture| expected.map(&:to_s).include?(capture[field].to_s) }
      else
        new(field, "=", expected.to_s)
      end
    end

    attr_reader :field, :modifier, :expression

    def initialize(field, modifier, expression)
      @field = field.to_s
      @modifier = modifier.to_s
      @expression = expression
    end

    def call(capture)
      value = capture[field].to_s

      case modifier
      when ""
        value.include?(expression.to_s)
      when "!"
        !value.include?(expression.to_s)
      when "="
        value == expression.to_s
      when "!="
        value != expression.to_s
      when "~"
        regexp.match?(value)
      when "!~"
        !regexp.match?(value)
      else
        raise ArgumentError, "unsupported filter modifier: #{modifier.inspect}"
      end
    end

    private

    def regexp
      @regexp ||= expression.is_a?(Regexp) ? expression : Regexp.new(expression.to_s)
    end
  end
end

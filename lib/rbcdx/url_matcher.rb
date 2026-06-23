require "uri"

module CDX
  class UrlMatcher
    MATCHES = %i[exact prefix domain host].freeze

    attr_reader :pattern, :match

    def initialize(pattern, match: nil)
      @pattern = pattern.to_s
      @match = (match || infer_match).to_sym
      validate_match!
      @query = Surt.parse_url(clean_pattern)
      @surt = Surt.from_url(clean_pattern)
      @domain_surt = Surt.host_to_surt(@query[:host]) if @query[:host]
    end

    def match?(capture)
      if capture.url
        return match_url?(capture.url)
      end

      match_urlkey?(capture.urlkey.to_s)
    end

    private

    def infer_match
      return :domain if pattern.start_with?("*.")
      return :prefix if pattern.end_with?("*")

      :exact
    end

    def validate_match!
      return if MATCHES.include?(match)

      raise ArgumentError, "unsupported match: #{match.inspect}"
    end

    def clean_pattern
      case match
      when :domain
        pattern.sub(/\A\*\./, "")
      when :prefix
        pattern.sub(/\*\z/, "")
      else
        pattern
      end
    end

    def match_url?(url)
      candidate = Surt.parse_url(url)
      return false unless candidate[:host]
      return false if @query[:scheme] && candidate[:scheme] != @query[:scheme]

      case match
      when :domain
        host_matches_domain?(candidate[:host])
      when :prefix
        candidate[:host] == @query[:host] && candidate[:path].start_with?(@query[:path])
      when :host
        candidate[:host] == @query[:host]
      else
        candidate[:host] == @query[:host] && normalize_path(candidate[:path]) == normalize_path(@query[:path])
      end
    end

    def match_urlkey?(urlkey)
      case match
      when :domain
        urlkey.start_with?("#{@domain_surt})", "#{@domain_surt},")
      when :prefix
        urlkey.start_with?(@surt.to_s)
      when :host
        urlkey.start_with?("#{@domain_surt})")
      else
        urlkey == @surt
      end
    end

    def host_matches_domain?(host)
      host == @query[:host] || host.end_with?(".#{@query[:host]}")
    end

    def normalize_path(path)
      normalized = path.to_s
      normalized.empty? ? "/" : normalized
    end
  end
end

require "uri"

module CDX
  module Surt
    module_function

    def from_url(url)
      parts = parse_url(url)
      return unless parts[:host]

      "#{host_to_surt(parts[:host])})#{parts[:path]}"
    end

    def host_to_surt(host)
      canonical_host(host).split(".").reverse.join(",")
    end

    def canonical_host(host)
      host.to_s.downcase.sub(/\.\z/, "").sub(/\Awww\./, "")
    end

    def parse_url(url)
      string = url.to_s.strip
      string = string.sub(/\A\*\./, "")
      string = string.sub(/\*\z/, "")

      explicit_scheme = string.match?(%r{\A[a-z][a-z0-9+\-.]*://}i)
      uri = URI.parse(explicit_scheme ? string : "http://#{string}")
      path = uri.path.to_s
      path = "/" if path.empty?
      path = "#{path}?#{uri.query}" if uri.query

      {
        scheme: explicit_scheme ? uri.scheme&.downcase : nil,
        host: canonical_host(uri.host),
        path: path
      }
    rescue URI::InvalidURIError
      fallback_parse(string)
    end

    def fallback_parse(string)
      host, path = string.split("/", 2)
      {
        scheme: nil,
        host: canonical_host(host),
        path: path ? "/#{path}" : "/"
      }
    end
  end
end

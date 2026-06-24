require "digest"
require "json"
require "uri"

module CDX
  class OnlyUrlFilter
    Rule = Struct.new(:host, :path, :match) do
      def to_h
        data = {"host" => host, "path" => path}
        data["match"] = match unless match == "host"
        data
      end
    end

    def self.from_files(paths)
      paths = Array(paths).flatten.compact.map(&:to_s)
      rules = paths.flat_map { |path| rules_from_file(path) }
      new(rules)
    end

    def self.rules_from_file(path)
      expanded = File.expand_path(path)
      raise ArgumentError, "only-url file does not exist: #{expanded}" unless File.file?(expanded)

      rules = []
      File.foreach(expanded).with_index(1) do |line, line_number|
        rule = parse_line(line, path: expanded, line_number: line_number)
        rules << rule if rule
      end
      rules
    end

    def self.parse_line(line, path:, line_number:)
      entry = line.to_s.strip
      return nil if entry.empty? || entry.start_with?("#")

      parse_entry(entry)
    rescue URI::InvalidURIError, ArgumentError
      raise ArgumentError, "#{path}:#{line_number}: invalid only-url entry #{entry.inspect}"
    end

    def self.parse_entry(entry)
      uri = URI.parse(explicit_scheme?(entry) ? entry : "http://#{entry}")
      raw_host = uri.host.to_s
      match = "host"
      if raw_host.start_with?("*.")
        match = "domain"
        raw_host = raw_host.delete_prefix("*.")
      end
      host = Surt.canonical_host(raw_host)
      raise ArgumentError if host.empty? || host.match?(/\s/) || host.include?("*")

      Rule.new(host, normalize_path(uri.path), match)
    end

    def self.explicit_scheme?(entry)
      entry.match?(%r{\A[a-z][a-z0-9+\-.]*://}i)
    end

    def self.normalize_path(path)
      value = path.to_s
      value = "/" if value.empty?
      value.start_with?("/") ? value : "/#{value}"
    end

    def initialize(rules)
      @rules = rules.map { |rule| Rule.new(rule.host, rule.path, rule.match || "host") }
      @canonical_rules = @rules.map(&:to_h).uniq.sort_by { |rule| [rule.fetch("host"), rule.fetch("path"), rule.fetch("match", "host")] }
      @rules_by_host = {}
      @domain_rules_by_host = {}
      @canonical_rules.each do |rule|
        rules_by_host = (rule.fetch("match", "host") == "domain") ? @domain_rules_by_host : @rules_by_host
        rules_by_host[rule.fetch("host")] ||= []
        rules_by_host[rule.fetch("host")] << rule.fetch("path")
      end
    end

    def empty?
      @canonical_rules.empty?
    end

    def call(capture)
      return false if empty?

      parts = capture_parts(capture)
      return false unless parts

      paths = matching_paths_for(parts.fetch(:host))
      return false if paths.empty?

      paths.any? { |path| path == "/" || parts.fetch(:path).start_with?(path) }
    end

    def signature
      data = JSON.generate(@canonical_rules)
      {
        "count" => @canonical_rules.length,
        "sha256" => Digest::SHA256.hexdigest(data),
        "rules" => @canonical_rules
      }
    end

    private

    def capture_parts(capture)
      from_url(capture.url) || from_urlkey(capture.urlkey)
    end

    def matching_paths_for(host)
      paths = Array(@rules_by_host[host])
      domain_candidates(host).each do |candidate|
        paths.concat(Array(@domain_rules_by_host[candidate]))
      end
      paths
    end

    def domain_candidates(host)
      labels = host.to_s.split(".")
      labels.each_index.map { |index| labels[index..].join(".") }
    end

    def from_url(url)
      value = url.to_s
      return if value.empty?

      uri = URI.parse(value)
      host = Surt.canonical_host(uri.host)
      return if host.empty?

      {host: host, path: self.class.normalize_path(uri.path)}
    rescue URI::InvalidURIError
      nil
    end

    def from_urlkey(urlkey)
      value = urlkey.to_s
      match = value.match(/\A(?<host>[^)]+)\)(?<path>.*)\z/)
      return unless match

      host = Surt.canonical_host(match[:host].split(",").reverse.join("."))
      return if host.empty?

      path = match[:path].to_s.split(/[?#]/, 2).first
      {host: host, path: self.class.normalize_path(path)}
    end
  end
end

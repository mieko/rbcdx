module CDX
  module Backends
    class RbCDX
      INDEX_FILE_PATTERN = /\.rbcdx[0-9A-Za-z]*\z/

      attr_reader :paths

      def self.index_file?(path)
        File.basename(path).match?(INDEX_FILE_PATTERN)
      end

      def self.write(input_path, output_path, **options)
        Repacker.repack(input_path, output_path, **options.merge(output_format: "rbcdx"))
      end

      def initialize(paths, parser_factory:)
        @paths = paths
        @manifests = Manifest.find_all(@paths)
        @reader_by_path = {}
        @paths.each { |path| reader_for(path) } if @manifests.empty?
      end

      def each_capture(matcher: nil)
        return enum_for(:each_capture, matcher: matcher) unless block_given?

        if matcher && @manifests.any?
          each_capture_with_manifests(matcher) { |capture| yield capture }
          return
        end

        paths.each do |path|
          reader = reader_for(path)
          matcher ? each_matching_capture(reader, matcher) { |capture| yield capture } : reader.each_capture { |capture| yield capture }
        end
      end

      private

      def each_capture_with_manifests(matcher)
        specs = query_specs(matcher)
        manifest_by_path = manifests_by_path
        candidates = manifest_candidate_paths(specs)

        paths.each do |path|
          next if manifest_by_path.key?(path) && !candidates.include?(path)

          each_matching_capture(reader_for(path), matcher, specs) { |capture| yield capture }
        end
      end

      def manifests_by_path
        @manifests.each_with_object({}) do |manifest, by_path|
          manifest.paths.each { |path| by_path[path] = manifest }
        end
      end

      def manifest_candidate_paths(specs)
        @manifests.each_with_object({}) do |manifest, candidates|
          specs.each do |urlkey, prefix|
            manifest.candidate_paths(urlkey, prefix: prefix).each do |path|
              candidates[path] = true
            end
          end
        end
      end

      def reader_for(path)
        @reader_by_path[path] ||= Reader.new(path)
      end

      def each_matching_capture(reader, matcher, specs = query_specs(matcher))
        specs.each do |urlkey, prefix|
          reader.captures(urlkey, prefix: prefix) do |capture|
            yield capture if matcher.match?(capture)
          end
        end
      end

      def query_specs(matcher)
        pattern = matcher.pattern.to_s
        case matcher.match
        when :domain
          host = Surt.parse_url(pattern.sub(/\A\*\./, ""))[:host]
          return [] unless host

          domain_surt = Surt.host_to_surt(host)
          [["#{domain_surt})", true], ["#{domain_surt},", true]]
        when :host
          host = Surt.parse_url(pattern)[:host]
          return [] unless host

          [["#{Surt.host_to_surt(host)})", true]]
        when :prefix
          [[Surt.from_url(pattern.sub(/\*\z/, "")), true]]
        else
          [[Surt.from_url(pattern), false]]
        end
      end
    end
  end
end

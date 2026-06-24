module CDX
  module Backends
    class RbCDX
      INDEX_FILE_PATTERN = /\.rbcdx[0-9A-Za-z]*\z/
      CAPTURE_PAGE_CURSOR_VERSION = 1

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

      def capture_pages_supported?
        true
      end

      def capture_page_backend
        "rbcdx"
      end

      def capture_page_cursor_version
        CAPTURE_PAGE_CURSOR_VERSION
      end

      def capture_page_fingerprint
        {
          "backend" => capture_page_backend,
          "cursor_version" => capture_page_cursor_version,
          "paths" => paths.map { |path| Repack.file_signature(path) },
          "manifests" => @manifests.map { |manifest| Repack.file_signature(manifest.manifest_path) if manifest.manifest_path }.compact
        }
      end

      def each_page_candidate(matcher:, position: nil)
        return enum_for(:each_page_candidate, matcher: matcher, position: position) unless block_given?

        resuming = !position.nil?
        specs = matcher ? query_specs(matcher) : [[nil, false]]
        cursor = normalize_cursor_position(position, specs.length)
        manifest_by_path = matcher ? manifests_by_path : {}
        candidates = matcher ? manifest_candidate_paths(specs) : {}

        paths.each_with_index do |path, path_index|
          next if path_index < cursor.fetch("path_index")
          next if matcher && @manifests.any? && manifest_by_path.key?(path) && !candidates.include?(path)

          specs.each_with_index do |(urlkey, prefix), spec_index|
            next if path_index == cursor.fetch("path_index") && spec_index < cursor.fetch("spec_index")

            at_cursor = resuming && path_index == cursor.fetch("path_index") && spec_index == cursor.fetch("spec_index")
            start_block = at_cursor ? cursor.fetch("block_index") : nil
            start_record = at_cursor ? cursor.fetch("record_index") : nil

            reader = reader_for(path)
            iterator = if matcher
              reader.captures_with_positions(urlkey, prefix: prefix, block_index: start_block, record_index: start_record)
            else
              reader.each_capture_with_positions(block_index: start_block, record_index: start_record)
            end

            iterator.each do |capture, reader_position|
              yield capture, {
                "path_index" => path_index,
                "spec_index" => spec_index,
                "block_index" => reader_position.fetch("block_index"),
                "record_index" => reader_position.fetch("record_index")
              }
            end
          end
        end
      end

      def validate_urlkey_collapse!(matcher)
        previous_last = nil
        collapse_candidate_paths(matcher).each do |path|
          range = reader_for(path).key_range
          next unless range

          first, last = range
          if previous_last && first < previous_last
            raise UnsupportedCollapse, "collapse: :urlkey requires globally urlkey-grouped .rbcdx files"
          end
          previous_last = last
        end
        true
      end

      private

      def collapse_candidate_paths(matcher)
        return paths unless matcher

        manifest_by_path = manifests_by_path
        specs = query_specs(matcher)
        candidates = @manifests.any? ? manifest_candidate_paths(specs) : {}
        paths.select do |path|
          if manifest_by_path.key?(path)
            candidates.include?(path)
          else
            range_overlaps_specs?(reader_for(path).key_range, specs)
          end
        end
      end

      def range_overlaps_specs?(range, specs)
        return false unless range

        specs.any? do |urlkey, prefix|
          range_overlaps_query?(range, urlkey.to_s, prefix: prefix)
        end
      end

      def range_overlaps_query?(range, query, prefix:)
        first, last = range
        if prefix
          end_key = prefix_successor(query)
          last >= query && (end_key.nil? || first < end_key)
        else
          query.between?(first, last)
        end
      end

      def prefix_successor(prefix)
        bytes = prefix.b.bytes
        index = bytes.length - 1
        index -= 1 while index >= 0 && bytes[index] == 255
        return if index.negative?

        bytes[index] += 1
        bytes[0..index].pack("C*")
      end

      def normalize_cursor_position(position, spec_count)
        return {"path_index" => 0, "spec_index" => 0, "block_index" => 0, "record_index" => 0} unless position
        raise InvalidCursor, "malformed capture cursor position" unless position.is_a?(Hash)

        cursor = %w[path_index spec_index block_index record_index].to_h do |key|
          [key, cursor_position_integer(position, key)]
        end

        raise InvalidCursor, "capture cursor position is outside this index" unless cursor.fetch("path_index") < paths.length
        raise InvalidCursor, "capture cursor position is outside this query" unless cursor.fetch("spec_index") < spec_count

        cursor
      end

      def cursor_position_integer(position, key)
        value = position.fetch(key)
        raise InvalidCursor, "malformed capture cursor position" unless value.is_a?(Integer) && value >= 0

        value
      rescue KeyError
        raise InvalidCursor, "malformed capture cursor position"
      end

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

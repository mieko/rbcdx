require "json"

module CDX
  module Backends
    class RbCDX
      class Manifest
        FORMAT = "rbcdx-manifest"
        VERSION = 1
        FILENAME = "rbcdx-manifest.json"

        Entry = Struct.new(
          :path,
          :absolute_path,
          :bytes,
          :version,
          :variant,
          :crawl_id,
          :record_count,
          :block_count,
          :first_urlkey,
          :last_urlkey
        ) do
          def to_h
            {
              "path" => path,
              "bytes" => bytes,
              "version" => version,
              "variant" => variant,
              "crawl_id" => crawl_id,
              "record_count" => record_count,
              "block_count" => block_count,
              "first_urlkey" => first_urlkey,
              "last_urlkey" => last_urlkey
            }
          end
        end

        attr_reader :entries, :root, :created_at

        def self.build(paths, root: nil, created_at: Time.now.to_i)
          new(paths, root: root, created_at: created_at)
        end

        def self.write(paths, output_path, root: File.dirname(File.expand_path(output_path)), **options)
          build(paths, root: root, **options).write(output_path)
        end

        def self.read(manifest_path, paths: nil)
          data = JSON.parse(File.read(manifest_path))
          manifest = allocate
          manifest.send(:load, manifest_path, data, paths: paths)
          manifest
        end

        def self.find_all(paths)
          paths.group_by { |path| File.dirname(path) }.filter_map do |dir, dir_paths|
            manifest_path = File.join(dir, FILENAME)
            next unless File.file?(manifest_path)

            manifest = read(manifest_path, paths: dir_paths)
            manifest if manifest.usable?
          rescue Error, JSON::ParserError, KeyError, TypeError, ArgumentError
            nil
          end
        end

        def initialize(paths, root: nil, created_at: Time.now.to_i)
          @manifest_path = nil
          @root = root && File.expand_path(root)
          @created_at = created_at.to_i
          @entries = expand_paths(paths).filter_map { |path| build_entry(path) }
          @entries.sort_by! { |entry| [entry.first_urlkey.to_s, entry.last_urlkey.to_s, entry.path] }
        end

        attr_reader :manifest_path

        def paths
          entries.map(&:absolute_path)
        end

        def usable?
          entries.any?
        end

        def covers?(path)
          paths.include?(File.expand_path(path))
        end

        def candidate_paths(urlkey, prefix: false)
          query = urlkey.to_s
          entries.select do |entry|
            entry_overlaps_query?(entry, query, prefix: prefix)
          end.map(&:absolute_path)
        end

        def write(output_path)
          File.write(output_path, "#{JSON.pretty_generate(to_h)}\n")
          self
        end

        def to_h
          {
            "format" => FORMAT,
            "version" => VERSION,
            "created_at" => created_at,
            "files" => entries.map(&:to_h)
          }
        end

        def to_json(*args)
          to_h.to_json(*args)
        end

        private

        def load(manifest_path, data, paths:)
          raise Error, "#{manifest_path}: invalid rbcdx manifest format" unless data.fetch("format") == FORMAT
          raise Error, "#{manifest_path}: unsupported rbcdx manifest version #{data["version"]}" unless data.fetch("version") == VERSION

          @manifest_path = File.expand_path(manifest_path)
          @root = File.dirname(@manifest_path)
          @created_at = data.fetch("created_at").to_i
          allowed_paths = Array(paths).map { |path| File.expand_path(path) }
          @entries = data.fetch("files").filter_map do |entry_data|
            entry = entry_from_h(entry_data)
            next if allowed_paths.any? && !allowed_paths.include?(entry.absolute_path)
            next unless current_entry?(entry)

            entry
          end
          @entries.sort_by! { |entry| [entry.first_urlkey.to_s, entry.last_urlkey.to_s, entry.path] }
        end

        def entry_from_h(data)
          path = data.fetch("path")
          Entry.new(
            path: path,
            absolute_path: absolute_manifest_path(path),
            bytes: data.fetch("bytes").to_i,
            version: data.fetch("version"),
            variant: data.fetch("variant"),
            crawl_id: data.fetch("crawl_id", nil),
            record_count: data.fetch("record_count").to_i,
            block_count: data.fetch("block_count").to_i,
            first_urlkey: data.fetch("first_urlkey"),
            last_urlkey: data.fetch("last_urlkey")
          )
        end

        def absolute_manifest_path(path)
          return File.expand_path(path) if absolute_path?(path)

          File.expand_path(path, File.dirname(manifest_path))
        end

        def absolute_path?(path)
          path.start_with?(File::SEPARATOR)
        end

        def current_entry?(entry)
          return false unless File.file?(entry.absolute_path)

          current = build_entry(entry.absolute_path)
          current && same_entry_metadata?(current, entry)
        rescue Error, JSON::ParserError, KeyError, TypeError, ArgumentError
          # Keep unreadable files covered by their manifest range so noncandidate
          # queries can still avoid opening them; matching queries will hit the
          # reader and surface the corruption.
          true
        end

        def same_entry_metadata?(left, right)
          left.to_h.except("path") == right.to_h.except("path")
        end

        def entry_overlaps_query?(entry, query, prefix:)
          if prefix
            end_key = prefix_successor(query)
            entry.last_urlkey >= query && (end_key.nil? || entry.first_urlkey < end_key)
          else
            query.between?(entry.first_urlkey, entry.last_urlkey)
          end
        end

        def expand_paths(paths)
          expanded = Array(paths).flatten.compact.flat_map do |path|
            string = path.to_s
            matches = Dir.glob(File.expand_path(string))
            if matches.empty? || !glob_pattern?(string)
              expand_explicit_path(File.expand_path(string))
            else
              matches.flat_map { |match| expand_discovered_path(match) }
            end
          end.uniq.sort
          raise ArgumentError, "no rbcdx paths were provided" if expanded.empty?

          expanded
        end

        def glob_pattern?(path)
          path.match?(/[*?\[\]{}]/)
        end

        def expand_explicit_path(path)
          if File.directory?(path)
            expand_directory(path)
          elsif File.file?(path)
            validate_rbcdx_path!(path)
            [path]
          else
            raise ArgumentError, "rbcdx path does not exist: #{path}"
          end
        end

        def expand_discovered_path(path)
          if File.directory?(path)
            expand_directory(path)
          elsif File.file?(path) && Backends::RbCDX.index_file?(path)
            [path]
          else
            []
          end
        end

        def expand_directory(path)
          Dir.glob(File.join(path, "**", "*")).select do |entry|
            File.file?(entry) && Backends::RbCDX.index_file?(entry)
          end
        end

        def validate_rbcdx_path!(path)
          return if Backends::RbCDX.index_file?(path)

          raise ArgumentError, "not an rbcdx file: #{path}"
        end

        def build_entry(path)
          metadata = read_metadata(path)
          header = metadata.header
          blocks = Format.decode_directory(metadata.read_section("directory"))
          validate_directory!(path, blocks)
          first = blocks.first
          last = blocks.last
          return unless first && last

          stat = File.stat(path)
          Entry.new(
            path: manifest_entry_path(path),
            absolute_path: path,
            bytes: stat.size,
            version: header.fetch("version"),
            variant: header.fetch("variant"),
            crawl_id: header.fetch("crawl_id", nil),
            record_count: header.fetch("record_count"),
            block_count: header.fetch("block_count"),
            first_urlkey: first&.first_urlkey,
            last_urlkey: last&.last_urlkey
          )
        end

        def read_metadata(path)
          Format.read_metadata(path, sections: ["directory"])
        end

        def validate_directory!(path, blocks)
          previous_last = nil
          blocks.each_with_index do |block, index|
            raise Error, "#{path}: block #{index} has inverted key range" if block.first_urlkey > block.last_urlkey
            raise Error, "#{path}: block #{index} overlaps prior key range" if previous_last && block.first_urlkey < previous_last

            previous_last = block.last_urlkey
          end
        end

        def manifest_entry_path(path)
          expanded = File.expand_path(path)
          return expanded unless root

          relative_path(expanded, root) || expanded
        end

        def relative_path(path, base)
          path_prefix = "#{base}#{File::SEPARATOR}"
          return "." if path == base

          path.delete_prefix(path_prefix) if path.start_with?(path_prefix)
        end

        def prefix_successor(prefix)
          bytes = prefix.b.bytes
          index = bytes.length - 1
          index -= 1 while index >= 0 && bytes[index] == 255
          return if index.negative?

          bytes[index] += 1
          bytes[0..index].pack("C*")
        end
      end
    end
  end
end

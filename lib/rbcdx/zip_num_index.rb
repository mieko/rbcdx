require "stringio"
require "zlib"

module CDX
  class ZipNumIndex
    BLOCK_LINE_COUNT = 3000

    Entry = Struct.new(:key, :filename, :offset, :length, :part)

    attr_reader :cluster_path, :shard_paths

    def self.find_all(paths)
      paths.group_by { |path| File.dirname(path) }.filter_map do |dir, dir_paths|
        cluster_path = File.join(dir, "cluster.idx")
        next unless File.file?(cluster_path)

        index = new(cluster_path, dir_paths)
        index if index.usable?
      end
    end

    def initialize(cluster_path, paths)
      @cluster_path = cluster_path
      @shard_paths = paths.each_with_object({}) do |path, by_filename|
        by_filename[File.basename(path)] = path
      end
      @entries = nil
      @entries_by_filename = nil
    end

    def paths
      covered_filenames.map { |filename| shard_paths[filename] }.compact
    end

    def usable?
      File.foreach(cluster_path) do |line|
        return true if parse_entry(line)
      end
      false
    end

    def captures_for(matcher, parser_factory:, path: nil)
      return enum_for(:captures_for, matcher, parser_factory: parser_factory, path: path) unless block_given?

      target_filename = File.basename(path) if path
      seen_blocks = {}
      matcher.index_key_ranges.each do |start_key, end_key|
        candidate_entries(start_key, end_key).each do |entry|
          next if target_filename && entry.filename != target_filename
          next unless covered_filename?(entry.filename)

          block_key = [entry.filename, entry.offset, entry.length]
          next if seen_blocks[block_key]

          seen_blocks[block_key] = true
          path = shard_paths[entry.filename]
          next unless path

          parser = parser_factory.call
          line_number = block_start_line(entry)
          each_block_line(path, entry.offset, entry.length) do |line|
            line_number += 1
            data = parser.parse(line)
            yield Capture.new(data, source_path: path, line_number: line_number) if data
          end
        end
      end
    end

    private

    def entries
      load_entries
      @entries
    end

    def entries_by_filename
      load_entries
      @entries_by_filename
    end

    def load_entries
      return if @entries

      by_filename = {}
      @entries = File.readlines(cluster_path, chomp: true).filter_map do |line|
        entry = parse_entry(line)
        (by_filename[entry.filename] ||= []) << entry if entry
        entry
      end
      @entries_by_filename = by_filename
    end

    def covered_filenames
      @covered_filenames ||= entries_by_filename.filter_map do |filename, filename_entries|
        filename if fully_covered?(filename, filename_entries)
      end
    end

    def covered_filename?(filename)
      covered_filename_lookup.key?(filename)
    end

    def covered_filename_lookup
      @covered_filename_lookup ||= covered_filenames.each_with_object({}) do |filename, lookup|
        lookup[filename] = true
      end
    end

    def parse_entry(line)
      key, filename, offset, length, part = line.chomp.split("\t", 5)
      return unless key && filename && offset && length
      return unless offset.match?(/\A\d+\z/) && length.match?(/\A\d+\z/)
      return if part && !part.match?(/\A\d+\z/)

      Entry.new(key, filename, offset.to_i, length.to_i, part&.to_i)
    end

    def candidate_entries(start_key, end_key)
      entries = self.entries
      return [] if entries.empty?

      first = [lower_bound(entries, start_key) - 1, 0].max
      last = end_key ? lower_bound(entries, end_key) : entries.length
      entries[first...last] || []
    end

    def lower_bound(entries, key)
      low = 0
      high = entries.length
      while low < high
        mid = (low + high) / 2
        if entries[mid].key < key
          low = mid + 1
        else
          high = mid
        end
      end
      low
    end

    def block_start_line(entry)
      return 0 unless entry.part

      (entry.part - 1) * BLOCK_LINE_COUNT
    end

    def fully_covered?(filename, filename_entries = entries_by_filename.fetch(filename, []))
      path = shard_paths[filename]
      return false unless path && File.file?(path)

      target_size = File.size(path)
      position = 0
      ranges = filename_entries.map do |entry|
        [entry.offset, entry.offset + entry.length]
      end.sort

      ranges.each do |start_byte, finish_byte|
        return false if start_byte > position

        position = [position, finish_byte].max
        return true if position >= target_size
      end

      position >= target_size
    end

    def each_block_line(path, offset, length)
      File.open(path, "rb") do |file|
        file.seek(offset)
        block = file.read(length)
        Zlib::GzipReader.wrap(StringIO.new(block)) do |gzip|
          gzip.each_line { |line| yield line }
        end
      end
    end
  end
end

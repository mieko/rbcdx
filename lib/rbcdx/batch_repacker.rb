require "fileutils"
require "json"
require "tempfile"

module CDX
  class BatchRepacker
    FORMAT = "rbcdx-repack-state"
    VERSION = 1
    STATE_FILENAME = "rbcdx-repack-state.json"

    Result = Struct.new(:input_path, :output_path, :status, :result, :message)
    Entry = Struct.new(:input_path, :output_path, :source_signature, :status, :updated_at) do
      def self.from_h(data)
        new(
          input_path: data.fetch("input_path"),
          output_path: data.fetch("output_path"),
          source_signature: data.fetch("source_signature"),
          status: data.fetch("status"),
          updated_at: data["updated_at"]
        )
      end

      def to_h
        {
          "input_path" => input_path,
          "output_path" => output_path,
          "source_signature" => source_signature,
          "status" => status,
          "updated_at" => updated_at
        }.compact
      end

      def mark(status, time: Time.now.to_i)
        self.status = status
        self.updated_at = time
        self
      end

      def [](key)
        to_h[key.to_s]
      end

      def fetch(key, *fallback, &block)
        hash = to_h
        return hash.fetch(key.to_s) if hash.key?(key.to_s)
        return fallback.first unless fallback.empty?
        return yield key if block

        raise KeyError, "key not found: #{key.inspect}"
      end
    end
    private_constant :Entry

    def initialize(inputs, output_dir:, block_bytes: RbcdxFormat::DEFAULT_BLOCK_BYTES,
      max_records: RbcdxFormat::DEFAULT_MAX_RECORDS, restart_interval: RbcdxFormat::DEFAULT_RESTART_INTERVAL,
      zstd_level: 6, filters: nil, where: nil, filter_signature: nil, resume: false, force: false,
      dry_run: false, delete_when_processed: false, manifest: true, progress: nil)
      @input_specs = Array(inputs).flatten.compact.map(&:to_s)
      @output_dir = File.expand_path(output_dir)
      @block_bytes = decimal_option("block_bytes", block_bytes)
      @max_records = decimal_option("max_records", max_records)
      @restart_interval = decimal_option("restart_interval", restart_interval)
      @zstd_level = decimal_option("zstd_level", zstd_level)
      @filters = filters
      @where = where
      @filter_signature = filter_signature || inferred_filter_signature(resume: resume, delete_when_processed: delete_when_processed)
      @resume = resume
      @force = force
      @dry_run = dry_run
      @delete_when_processed = delete_when_processed
      @manifest = manifest
      @progress = progress
      validate_options
    end

    def run
      raise ArgumentError, "provide at least one input path" if @input_specs.empty?

      state = load_state
      @allow_missing_inputs = @resume && state
      discovered_entries = discover_entries
      entries = entries_for_run(discovered_entries, state)
      raise ArgumentError, "no CDX/CDXJ input files were found" if entries.empty?

      return dry_run(entries) if @dry_run

      FileUtils.mkdir_p(@output_dir)
      write_initial_state(entries) unless state && @resume
      results = []
      entries.each_with_index do |entry, index|
        results << process_entry(entry, index + 1, entries.length)
      end
      rebuild_manifest(entries) if @manifest
      results
    end

    private

    def validate_options
      raise ArgumentError, "block_bytes must be positive" unless @block_bytes.positive?
      raise ArgumentError, "max_records must be positive" unless @max_records.positive?
      raise ArgumentError, "restart_interval must be positive" unless @restart_interval.positive?
      raise ArgumentError, "zstd_level must be positive" unless @zstd_level.positive?
    end

    def decimal_option(name, value)
      string = value.to_s
      raise ArgumentError, "#{name} must be a decimal integer" unless string.match?(/\A\d+\z/)

      string.to_i
    end

    def inferred_filter_signature(resume:, delete_when_processed:)
      RepackFilters.stable_signature(filters: @filters, where: @where)
    rescue ArgumentError
      raise if resume || delete_when_processed
    end

    def discover_entries
      paths = @input_specs.flat_map { |input| expand_input(input) }.uniq.sort
      validate_output_directory!(paths)
      outputs = {}
      paths.map do |input_path|
        output_path = File.join(@output_dir, output_basename(input_path))
        if outputs.key?(output_path)
          raise ArgumentError, "multiple inputs would write #{output_path}: #{outputs.fetch(output_path)} and #{input_path}"
        end

        outputs[output_path] = input_path
        Entry.new(
          input_path: input_path,
          output_path: output_path,
          source_signature: source_signature(input_path),
          status: "pending"
        )
      end
    end

    def expand_input(input)
      expanded = Dir.glob(File.expand_path(input))
      if expanded.empty? || !glob_pattern?(input)
        expand_explicit_input(File.expand_path(input))
      else
        expanded.flat_map { |entry| expand_discovered_input(entry) }
      end
    end

    def expand_explicit_input(path)
      if File.directory?(path)
        expand_input_directory(path)
      elsif File.file?(path)
        validate_input_file!(path)
        [path]
      else
        return [] if @allow_missing_inputs

        raise ArgumentError, "input path does not exist: #{path}"
      end
    end

    def expand_discovered_input(path)
      if File.directory?(path)
        expand_input_directory(path)
      elsif File.file?(path) && input_file?(path)
        [path]
      else
        []
      end
    end

    def expand_input_directory(path)
      Dir.glob(File.join(path, "**", "*")).select { |entry| File.file?(entry) && input_file?(entry) }
    end

    def validate_input_file!(path)
      return if input_file?(path)

      raise ArgumentError, "not a supported CDX/CDXJ input file: #{path}"
    end

    def input_file?(path)
      Backends::Cdx.index_file?(path)
    end

    def validate_output_directory!(paths)
      paths.map { |path| File.dirname(path) }.uniq.each do |dir|
        next unless related_directories?(@output_dir, dir)

        raise ArgumentError, "batch output directory must be separate from input directories: #{@output_dir}"
      end

      input_tree_directories.each do |dir|
        next unless related_directories?(@output_dir, dir)

        raise ArgumentError, "batch output directory must be separate from input directories: #{@output_dir}"
      end
    end

    def input_tree_directories
      @input_specs.filter_map do |input|
        path = File.expand_path(input)
        if glob_pattern?(input)
          glob_static_directory(path)
        elsif File.directory?(path)
          path
        end
      end
    end

    def glob_static_directory(pattern)
      match = pattern.match(/[*?\[\]{}]/)
      return unless match

      prefix = pattern[0...match.begin(0)]
      dir = prefix.end_with?(File::SEPARATOR) ? prefix.delete_suffix(File::SEPARATOR) : File.dirname(prefix)
      File.expand_path(dir.empty? ? "." : dir)
    end

    def related_directories?(left, right)
      same_or_descendant?(left, right) || same_or_descendant?(right, left)
    end

    def same_or_descendant?(path, base)
      path = canonical_directory(path)
      base = canonical_directory(base)
      path == base || path.start_with?("#{base}#{File::SEPARATOR}")
    end

    def canonical_directory(path)
      path = File.expand_path(path)
      return File.realpath(path) if File.exist?(path)

      parent = File.dirname(path)
      return path if parent == path

      File.join(canonical_directory(parent), File.basename(path))
    rescue SystemCallError
      File.expand_path(path)
    end

    def output_basename(input_path)
      basename = File.basename(input_path)
      stem = case basename
      when /\A(cdx-\d+)\.gz\z/i
        $1
      when /\A(.+)\.(?:cdx|cdxj)(?:\.gz)?\z/i
        $1
      else
        basename.sub(/\.gz\z/i, "")
      end
      "#{stem}.rbcdx"
    end

    def glob_pattern?(path)
      path.match?(/[*?\[\]{}]/)
    end

    def entries_for_run(discovered_entries, state)
      if state
        return entries_from_state(discovered_entries, state) if @resume
        return discovered_entries if @force

        raise Error, "repack state already exists; use --resume to continue or --force to start over"
      end

      discovered_entries
    end

    def entries_from_state(discovered_entries, state)
      unless state.fetch("plan") == plan_signature
        raise Error, "repack state does not match these inputs or options"
      end

      discovered_by_input = discovered_entries.to_h { |entry| [entry.input_path, entry] }
      state_entries = state.fetch("entries")
      state_inputs = state_entries.map(&:input_path)
      extra_inputs = discovered_by_input.keys - state_inputs
      unless extra_inputs.empty?
        raise Error, "input set changed since checkpoint: #{extra_inputs.first}"
      end

      state_entries.each do |entry|
        discovered = discovered_by_input[entry.input_path]
        next unless discovered
        next if discovered.source_signature == entry.source_signature

        raise Error, "input changed since checkpoint: #{entry.input_path}"
      end
      state_entries
    end

    def process_entry(entry, index, total)
      process_entry!(entry, index, total)
    rescue
      update_entry_state(entry, "failed")
      emit_progress(:fail, entry: entry, index: index, total: total)
      raise
    end

    def process_entry!(entry, index, total)
      output_path = entry.output_path
      input_path = entry.input_path

      if @resume && matching_output?(entry)
        emit_progress(:skip, entry: entry, index: index, total: total)
        update_entry_state(entry, "complete")
        delete_source_if_requested(entry, index, total)
        return Result.new(input_path, output_path, :skipped, nil, nil)
      end

      if !File.file?(input_path)
        raise Error, "source is missing and output is not resumable: #{input_path}"
      end
      if File.exist?(output_path) && !@force
        raise Error, "output already exists and does not match this repack plan: #{output_path}"
      end

      emit_progress(:start, entry: entry, index: index, total: total)
      update_entry_state(entry, "processing")
      result = Repacker.repack(
        input_path,
        output_path,
        block_bytes: @block_bytes,
        max_records: @max_records,
        restart_interval: @restart_interval,
        zstd_level: @zstd_level,
        filters: @filters,
        where: @where,
        filter_signature: @filter_signature,
        atomic: true,
        verify: true,
        force: @force,
        metadata: {"batch_plan" => plan_signature}
      )
      raise Error, "new output does not match this repack plan: #{output_path}" unless matching_output?(entry)

      update_entry_state(entry, "complete")
      emit_progress(:finish, entry: entry, index: index, total: total)
      delete_source_if_requested(entry, index, total)
      Result.new(input_path, output_path, :written, result, nil)
    end

    def delete_source_if_requested(entry, index, total)
      return unless @delete_when_processed

      output_path = entry.output_path
      input_path = entry.input_path
      unless matching_output?(entry)
        raise Error, "refusing to delete source before output verifies: #{input_path}"
      end
      if File.expand_path(output_path) == File.expand_path(input_path)
        raise Error, "refusing to delete source because output path is the same: #{input_path}"
      end

      update_entry_state(entry, "delete_pending")
      File.delete(input_path) if File.file?(input_path)
      update_entry_state(entry, "deleted")
      emit_progress(:delete, entry: entry, index: index, total: total)
    end

    def matching_output?(entry, verify: true)
      output_path = entry.output_path
      return false unless File.file?(output_path)

      header = Repacker.read_header(output_path)
      repack = header.fetch("repack")
      repack.fetch("source") == entry.source_signature &&
        repack.fetch("options") == repack_options_metadata &&
        repack.fetch("filter_signature") == @filter_signature &&
        repack.fetch("selected_fingerprint").is_a?(Hash) &&
        header.fetch("record_count") == repack.fetch("selected_fingerprint").fetch("count") &&
        (!verify || Repacker.verify_output(output_path, header.fetch("record_count")))
    rescue
      false
    end

    def dry_run(entries)
      entries.map.with_index(1) do |entry, index|
        emit_progress(:planned, entry: entry, index: index, total: entries.length)
        Result.new(entry.input_path, entry.output_path, :planned, nil, nil)
      end
    end

    def write_initial_state(entries)
      write_state(
        {
          "format" => FORMAT,
          "version" => VERSION,
          "created_at" => Time.now.to_i,
          "updated_at" => Time.now.to_i,
          "plan" => plan_signature,
          "entries" => entries
        }
      )
    end

    def update_entry_state(entry, status)
      entry.mark(status)
      state = load_state || {
        "format" => FORMAT,
        "version" => VERSION,
        "created_at" => Time.now.to_i,
        "plan" => plan_signature,
        "entries" => [entry]
      }
      state["entries"].each do |state_entry|
        next unless state_entry.input_path == entry.input_path

        state_entry.mark(status)
      end
      state["updated_at"] = Time.now.to_i
      write_state(state)
    end

    def load_state
      return unless File.file?(state_path)

      data = JSON.parse(File.read(state_path))
      raise Error, "#{state_path}: invalid repack state format" unless data.fetch("format") == FORMAT
      raise Error, "#{state_path}: unsupported repack state version #{data["version"]}" unless data.fetch("version") == VERSION

      data["entries"] = data.fetch("entries").map { |entry| Entry.from_h(entry) }
      data
    rescue JSON::ParserError => error
      raise Error, "#{state_path}: malformed repack state JSON: #{error.message}"
    end

    def write_state(state)
      state = state.merge("entries" => state.fetch("entries").map(&:to_h))
      atomic_write_json(state_path, state)
    end

    def state_path
      File.join(@output_dir, STATE_FILENAME)
    end

    def rebuild_manifest(entries)
      paths = manifest_entries(entries).map(&:output_path)
      manifest_path = File.join(@output_dir, RbcdxManifest::FILENAME)
      manifest = if paths.empty?
        {
          "format" => RbcdxManifest::FORMAT,
          "version" => RbcdxManifest::VERSION,
          "created_at" => Time.now.to_i,
          "files" => []
        }
      else
        RbcdxManifest.build(paths, root: @output_dir).to_h
      end
      atomic_write_json(manifest_path, manifest)
      RbcdxManifest.read(manifest_path, paths: paths)
    end

    def manifest_entries(entries)
      entries.select do |entry|
        %w[complete delete_pending deleted].include?(entry.status) && matching_output?(entry, verify: false)
      end
    end

    def atomic_write_json(path, data)
      FileUtils.mkdir_p(File.dirname(path))
      temp = Tempfile.new(["#{File.basename(path)}.", ".tmp"], File.dirname(path))
      temp_path = temp.path
      temp.write("#{JSON.pretty_generate(data)}\n")
      temp.close
      File.rename(temp_path, path)
      temp_path = nil
    ensure
      temp&.close
      File.unlink(temp_path) if temp_path && File.exist?(temp_path)
    end

    def source_signature(path)
      stat = File.stat(path)
      {
        "path" => File.expand_path(path),
        "basename" => File.basename(path),
        "bytes" => stat.size,
        "mtime" => stat.mtime.to_i,
        "mtime_nsec" => stat.mtime.nsec
      }
    end

    def plan_signature
      {
        "input_specs" => @input_specs.map { |input| File.expand_path(input) },
        "output_dir" => @output_dir,
        "options" => repack_options_metadata,
        "filter_signature" => @filter_signature,
        "manifest" => @manifest
      }
    end

    def repack_options_metadata
      {
        "block_bytes" => @block_bytes,
        "max_records" => @max_records,
        "restart_interval" => @restart_interval,
        "zstd_level" => @zstd_level
      }
    end

    def emit_progress(event, **payload)
      @progress&.call(event, **payload)
    end
  end
end

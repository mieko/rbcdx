require "fileutils"
require "json"
require "tempfile"

module CDX
  class BatchRepacker
    FORMAT = "rbcdx-repack-state"
    VERSION = 1
    STATE_FILENAME = "rbcdx-repack-state.json"
    SELECTION_DIRNAME = "rbcdx-collapse-selection"

    Result = Struct.new(:input_path, :output_path, :status, :result, :message)
    Entry = Struct.new(
      :input_path,
      :output_path,
      :source_signature,
      :status,
      :updated_at,
      :output_format,
      :output_signature,
      :record_count,
      :selected_fingerprint,
      :selection_path
    ) do
      def self.from_h(data)
        input_path = data.fetch("input_path")
        output_path = data.fetch("output_path")
        source_signature = data.fetch("source_signature")
        status = data.fetch("status")
        output_format = data.fetch("output_format", "rbcdx")
        unless input_path.is_a?(String) && !input_path.empty? &&
            output_path.is_a?(String) && !output_path.empty? &&
            source_signature.is_a?(Hash) &&
            status.is_a?(String) &&
            output_format.is_a?(String)
          raise TypeError, "invalid entry field type"
        end

        new(
          input_path: input_path,
          output_path: output_path,
          source_signature: source_signature,
          status: status,
          updated_at: data["updated_at"],
          output_format: output_format,
          output_signature: data["output_signature"],
          record_count: data["record_count"],
          selected_fingerprint: data["selected_fingerprint"],
          selection_path: data["selection_path"]
        )
      end

      def to_h
        {
          "input_path" => input_path,
          "output_path" => output_path,
          "source_signature" => source_signature,
          "status" => status,
          "updated_at" => updated_at,
          "output_format" => output_format,
          "output_signature" => output_signature,
          "record_count" => record_count,
          "selected_fingerprint" => selected_fingerprint,
          "selection_path" => selection_path
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

    def initialize(inputs, output_dir:, output_format: "rbcdx", block_bytes: Backends::RbCDX::Format::DEFAULT_BLOCK_BYTES,
      max_records: Backends::RbCDX::Format::DEFAULT_MAX_RECORDS, restart_interval: Backends::RbCDX::Format::DEFAULT_RESTART_INTERVAL,
      zstd_level: 6, filters: nil, where: nil, filter_signature: nil, resume: false, force: false,
      dry_run: false, delete_when_processed: false, manifest: true, collapse: nil, collapse_order: nil, progress: nil)
      @input_specs = Array(inputs).flatten.compact.map(&:to_s)
      @output_dir = File.expand_path(output_dir)
      @output_format = output_format.to_s
      raise ArgumentError, "unsupported output format: #{output_format.inspect}" unless Repacker.output_formats.include?(@output_format)

      @block_bytes = rbcdx? ? decimal_option("block_bytes", block_bytes) : block_bytes
      @max_records = rbcdx? ? decimal_option("max_records", max_records) : max_records
      @restart_interval = rbcdx? ? decimal_option("restart_interval", restart_interval) : restart_interval
      @zstd_level = rbcdx? ? decimal_option("zstd_level", zstd_level) : zstd_level
      @filters = filters
      @where = where
      @compiled_filters = RepackFilters.build(filters, where: where)
      @filter_signature = filter_signature || inferred_filter_signature(resume: resume, delete_when_processed: delete_when_processed)
      @collapse_config = CaptureCollapse.build(collapse: collapse, collapse_order: collapse_order)
      @collapse_signature = @collapse_config&.signature
      @selection_by_input = {}
      @resume = resume
      @force = force
      @dry_run = dry_run
      @delete_when_processed = delete_when_processed
      @manifest = rbcdx? && manifest
      @progress = progress
      validate_options
    end

    def run
      raise ArgumentError, "provide at least one input path" if @input_specs.empty?

      state = load_state
      @allow_missing_inputs = @resume && state
      discovered_entries = discover_entries(state: state)
      entries = entries_for_run(discovered_entries, state)
      raise ArgumentError, "no CDX/CDXJ input files were found" if entries.empty?
      prepare_collapse_selection(entries, persist: !@dry_run, state: state)

      return dry_run(entries) if @dry_run

      FileUtils.mkdir_p(@output_dir)
      if state && @resume
        emit_progress(:state_resume, path: state_path, entries: state.fetch("entries").length)
      else
        emit_progress(:state_start, path: state_path, entries: entries.length)
        write_initial_state(entries)
        emit_progress(:state_finish, path: state_path, entries: entries.length)
      end
      results = []
      entries.each_with_index do |entry, index|
        results << process_entry(entry, index + 1, entries.length)
      end
      rebuild_manifest(entries) if @manifest
      results
    end

    private

    def validate_options
      return unless rbcdx?

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

    def discover_entries(state: nil)
      paths = @input_specs.flat_map { |input| expand_input(input) }.uniq.sort
      paths = remove_resume_output_paths(paths, state) if state
      outputs = {}
      paths.map do |input_path|
        output_path = File.join(@output_dir, output_basename(input_path))
        validate_output_path!(input_path, output_path, input_paths: paths)
        if outputs.key?(output_path)
          raise ArgumentError, "multiple inputs would write #{output_path}: #{outputs.fetch(output_path)} and #{input_path}"
        end

        outputs[output_path] = input_path
        Entry.new(
          input_path: input_path,
          output_path: output_path,
          source_signature: source_signature(input_path),
          status: "pending",
          output_format: @output_format
        )
      end
    end

    def remove_resume_output_paths(paths, state)
      return paths unless @resume && cdxj?

      state_outputs = state.fetch("entries").each_with_object({}) do |entry, outputs|
        outputs[File.expand_path(entry.output_path)] = true
      end
      paths.reject { |path| state_outputs.key?(File.expand_path(path)) }
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
      Backends::CDXJ.index_file?(path)
    end

    def output_basename(input_path)
      basename = File.basename(input_path)
      return cdxj_output_basename(input_path, basename) if cdxj?

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

    def cdxj_output_basename(input_path, basename)
      return basename unless same_directory?(File.dirname(input_path), @output_dir)

      case basename
      when /\A(.+)(\.cdxj(?:\.gz)?)\z/i
        "#{$1}.filtered#{$2}"
      when /\A(cdx-\d+)\.gz\z/i
        "#{$1}.filtered.cdxj.gz"
      when /\A(.+)(\.cdx(?:\.gz)?)\z/i
        name = "#{$1}.filtered.cdxj"
        $2.end_with?(".gz") ? "#{name}.gz" : name
      else
        "#{basename}.filtered.cdxj"
      end
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
      validate_state_selection!(state_entries)
      state_entries
    end

    def validate_state_selection!(entries)
      return unless @collapse_config

      entries.each do |entry|
        unless entry.selection_path.is_a?(String) && !entry.selection_path.empty?
          raise Error, "repack state does not include collapse selection for #{entry.input_path}"
        end
      end
    end

    def prepare_collapse_selection(entries, persist:, state:)
      return unless @collapse_config

      if state && @resume
        entries.each do |entry|
          next unless entry.selection_path && File.file?(entry.selection_path)

          @selection_by_input[entry.input_path] = RepackSelection::LineSelection.read(entry.selection_path)
        end
        return
      end

      selected = select_global_line_numbers(entries)
      entries.each_with_index do |entry, index|
        line_numbers = selected.fetch(entry.input_path)
        @selection_by_input[entry.input_path] = RepackSelection::LineSelection.new(line_numbers)
        next unless persist

        entry.selection_path = selection_path_for(entry, index)
        RepackSelection::LineSelection.write(entry.selection_path, line_numbers)
      end
    end

    def select_global_line_numbers(entries)
      selected = entries.to_h { |entry| [entry.input_path, []] }
      current_urlkey = nil
      current_entry = nil
      current_entry_index = nil
      current_capture = nil

      entries.each_with_index do |entry, entry_index|
        Backends::CDXJ::RepackReader.new(entry.input_path).each_capture do |capture, _raw_line, _source_offset|
          next unless Repack.keep?(@compiled_filters, capture)

          urlkey = capture.urlkey.to_s
          if current_urlkey && urlkey < current_urlkey
            raise UnsupportedCollapse, "collapse: :urlkey requires globally urlkey-grouped input files"
          end

          if current_urlkey && urlkey != current_urlkey
            selected.fetch(current_entry.input_path) << current_capture.line_number
            current_urlkey = urlkey
            current_entry = entry
            current_entry_index = entry_index
            current_capture = capture
          else
            current_urlkey ||= urlkey
            current_entry ||= entry
            current_entry_index ||= entry_index
            if better_batch_capture?(entry_index, capture, current_entry_index, current_capture)
              current_entry = entry
              current_entry_index = entry_index
              current_capture = capture
            end
          end
        end
      end

      selected.fetch(current_entry.input_path) << current_capture.line_number if current_capture
      selected
    end

    def better_batch_capture?(entry_index, capture, best_entry_index, best_capture)
      return true unless best_capture
      return true if capture.timestamp.to_s > best_capture.timestamp.to_s
      return false if capture.timestamp.to_s < best_capture.timestamp.to_s

      return entry_index > best_entry_index unless entry_index == best_entry_index

      capture.line_number.to_i > best_capture.line_number.to_i
    end

    def selected_line_numbers_for(entry)
      return unless @collapse_config

      selection = @selection_by_input[entry.input_path]
      if selection.nil? && entry.selection_path && File.file?(entry.selection_path)
        selection = RepackSelection::LineSelection.read(entry.selection_path)
        @selection_by_input[entry.input_path] = selection
      end
      raise Error, "collapse selection is missing for #{entry.input_path}" unless selection

      selection.line_numbers
    end

    def selection_path_for(entry, index)
      basename = "#{format("%05d", index)}-#{File.basename(entry.output_path)}.lines"
      File.join(@output_dir, SELECTION_DIRNAME, basename)
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
      expected_fingerprint = expected_selected_fingerprint(entry)
      validate_selection_sidecar!(entry, expected_fingerprint)
      result = Repacker.repack(
        input_path,
        output_path,
        block_bytes: @block_bytes,
        max_records: @max_records,
        restart_interval: @restart_interval,
        zstd_level: @zstd_level,
        output_format: @output_format,
        filters: @filters,
        where: @where,
        filter_signature: @filter_signature,
        collapse: collapse_field,
        collapse_order: collapse_order,
        selected_line_numbers: selected_line_numbers_for(entry),
        atomic: true,
        verify: true,
        force: @force,
        metadata: {"batch_plan" => plan_signature},
        progress: entry_progress(entry, index, total)
      )
      unless result.source_signature == entry.source_signature
        raise Error, "source changed before output was written: #{input_path}"
      end
      unless result.selected_fingerprint == expected_fingerprint
        raise Error, "new output selected records do not match this repack plan: #{output_path}"
      end
      record_result(entry, result)
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
      return matching_cdxj_output?(entry) if cdxj?

      header = Repacker.read_header(output_path)
      repack = header.fetch("repack")
      selected_fingerprint = repack.fetch("selected_fingerprint")
      expected_fingerprint = expected_selected_fingerprint(entry)
      matches = repack.fetch("source") == entry.source_signature &&
        repack.fetch("options") == repack_options_metadata &&
        repack.fetch("filter_signature") == @filter_signature &&
        repack.fetch("collapse_signature", nil) == @collapse_signature &&
        selected_fingerprint.is_a?(Hash) &&
        selected_fingerprint == expected_fingerprint &&
        header.fetch("record_count") == selected_fingerprint.fetch("count") &&
        (!verify || Repacker.verify_output(output_path, header.fetch("record_count")))
      recover_entry_from_rbcdx_output(entry, header, selected_fingerprint) if matches
      matches
    rescue
      false
    end

    def validate_selection_sidecar!(entry, expected_fingerprint)
      return unless @collapse_config
      return unless expected_fingerprint.is_a?(Hash)
      return unless entry.selected_fingerprint.is_a?(Hash)

      selection = RepackSelection::LineSelection.new(selected_line_numbers_for(entry))
      actual_fingerprint = fingerprint_selected_input(entry.input_path, selection)
      return if actual_fingerprint == expected_fingerprint

      raise Error, "collapse selection sidecar does not match this repack plan: #{entry.input_path}"
    end

    def expected_selected_fingerprint(entry)
      return entry.selected_fingerprint if entry.selected_fingerprint.is_a?(Hash)
      return unless File.file?(entry.input_path)

      selection = RepackSelection::LineSelection.new(selected_line_numbers_for(entry)) if @collapse_config
      fingerprint_selected_input(entry.input_path, selection)
    end

    def fingerprint_selected_input(input_path, selection)
      fingerprint = Repack.new_selected_fingerprint
      Backends::CDXJ::RepackReader.new(input_path).each_capture do |capture, raw_line, _source_offset|
        next unless Repack.keep?(@compiled_filters, capture) && Repack.selected?(selection, capture)

        Repack.fingerprint_selected_record(fingerprint, capture, raw_line)
      end
      Repack.finish_selected_fingerprint(fingerprint)
    end

    def recover_entry_from_rbcdx_output(entry, header, selected_fingerprint)
      entry.output_signature ||= Repack.file_signature(entry.output_path)
      entry.record_count ||= header.fetch("record_count")
      entry.selected_fingerprint ||= selected_fingerprint
    end

    def matching_cdxj_output?(entry)
      return false unless entry.output_format.to_s == "cdxj"
      return false unless entry.output_signature

      Repack.file_signature(entry.output_path) == entry.output_signature &&
        entry.record_count.to_i == entry.selected_fingerprint.fetch("count")
    rescue
      false
    end

    def dry_run(entries)
      entries.map.with_index(1) do |entry, index|
        if @resume && matching_output?(entry)
          emit_progress(:skip, entry: entry, index: index, total: entries.length)
          emit_progress(:delete_planned, entry: entry, index: index, total: entries.length) if @delete_when_processed && File.file?(entry.input_path)
          next Result.new(entry.input_path, entry.output_path, :skipped, nil, nil)
        end
        if File.exist?(entry.output_path) && !@force
          raise Error, "output already exists and does not match this repack plan: #{entry.output_path}"
        end

        emit_progress(:planned, entry: entry, index: index, total: entries.length)
        preview = Repacker.preview(
          entry.input_path,
          entry.output_path,
          block_bytes: @block_bytes,
          max_records: @max_records,
          restart_interval: @restart_interval,
          zstd_level: @zstd_level,
          output_format: @output_format,
          filters: @filters,
          where: @where,
          filter_signature: @filter_signature,
          collapse: collapse_field,
          collapse_order: collapse_order,
          selected_line_numbers: selected_line_numbers_for(entry),
          force: @force,
          metadata: {"batch_plan" => plan_signature}
        )
        emit_progress(:preview, entry: entry, index: index, total: entries.length, preview: preview)
        emit_progress(:delete_planned, entry: entry, index: index, total: entries.length) if @delete_when_processed
        Result.new(entry.input_path, entry.output_path, :planned, preview, nil)
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

        state_entry.output_format = entry.output_format
        state_entry.output_signature = entry.output_signature
        state_entry.record_count = entry.record_count
        state_entry.selected_fingerprint = entry.selected_fingerprint
        state_entry.mark(status)
      end
      state["updated_at"] = Time.now.to_i
      write_state(state)
    end

    def record_result(entry, result)
      entry.output_format = result.output_format
      entry.output_signature = result.output_signature
      entry.record_count = result.record_count
      entry.selected_fingerprint = result.selected_fingerprint
    end

    def load_state
      return unless File.file?(state_path)

      data = JSON.parse(File.read(state_path))
      raise Error, "#{state_path}: invalid repack state format" unless data.is_a?(Hash) && data["format"] == FORMAT
      raise Error, "#{state_path}: unsupported repack state version #{data["version"]}" unless data["version"] == VERSION

      entries = data["entries"]
      unless entries.is_a?(Array) && entries.all? { |entry| entry.is_a?(Hash) }
        raise Error, "#{state_path}: invalid repack state entries"
      end
      data["entries"] = entries.map { |entry| Entry.from_h(entry) }
      data
    rescue JSON::ParserError => error
      raise Error, "#{state_path}: malformed repack state JSON: #{error.message}"
    rescue KeyError => error
      raise Error, "#{state_path}: invalid repack state entry: #{error.message}"
    rescue TypeError => error
      raise Error, "#{state_path}: invalid repack state entry: #{error.message}"
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
      manifest_path = File.join(@output_dir, Backends::RbCDX::Manifest::FILENAME)
      manifest = if paths.empty?
        {
          "format" => Backends::RbCDX::Manifest::FORMAT,
          "version" => Backends::RbCDX::Manifest::VERSION,
          "created_at" => Time.now.to_i,
          "files" => []
        }
      else
        Backends::RbCDX::Manifest.build(paths, root: @output_dir).to_h
      end
      atomic_write_json(manifest_path, manifest)
      Backends::RbCDX::Manifest.read(manifest_path, paths: paths)
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
      signature = {
        "input_specs" => @input_specs.map { |input| File.expand_path(input) },
        "output_dir" => @output_dir,
        "output_format" => @output_format,
        "options" => repack_options_metadata,
        "filter_signature" => @filter_signature,
        "manifest" => @manifest
      }
      signature["collapse_signature"] = @collapse_signature if @collapse_signature
      signature
    end

    def repack_options_metadata
      return {} if cdxj?

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

    def entry_progress(entry, index, total)
      lambda do |event, **payload|
        emit_progress(event, entry: entry, index: index, total: total, **payload)
      end
    end

    def collapse_field
      @collapse_config&.field&.to_sym
    end

    def collapse_order
      @collapse_config&.order&.to_sym
    end

    def rbcdx?
      @output_format == "rbcdx"
    end

    def cdxj?
      @output_format == "cdxj"
    end

    def validate_output_path!(input_path, output_path, input_paths:)
      if same_path?(input_path, output_path)
        raise ArgumentError, "input and output paths must be different: #{input_path}"
      end
      input_paths.each do |candidate|
        next if candidate == input_path

        if same_path?(candidate, output_path)
          raise ArgumentError, "planned output collides with input path: #{output_path}"
        end
      end
      reserved_paths.each do |reserved_path|
        if same_path?(output_path, reserved_path)
          raise ArgumentError, "planned output collides with repack metadata: #{output_path}"
        end
      end
    end

    def reserved_paths
      paths = [state_path]
      paths << File.join(@output_dir, Backends::RbCDX::Manifest::FILENAME) if @manifest
      paths
    end

    def same_path?(left, right)
      left = File.expand_path(left)
      right = File.expand_path(right)
      return true if left == right

      return false unless File.exist?(left) && File.exist?(right)

      left_stat = File.stat(left)
      right_stat = File.stat(right)
      left_stat.dev == right_stat.dev && left_stat.ino == right_stat.ino
    rescue SystemCallError
      false
    end

    def same_directory?(left, right)
      canonical_directory(left) == canonical_directory(right)
    end

    def canonical_directory(path)
      File.realpath(path)
    rescue SystemCallError
      File.expand_path(path)
    end
  end
end

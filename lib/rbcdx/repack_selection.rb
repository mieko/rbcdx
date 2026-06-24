require "fileutils"
require "tempfile"

module CDX
  module RepackSelection
    class LineSelection
      attr_reader :line_numbers

      def self.read(path)
        new(File.readlines(path, chomp: true).reject(&:empty?).map do |line|
          Integer(line, 10)
        end)
      rescue ArgumentError
        raise Error, "#{path}: invalid collapse selection sidecar"
      end

      def self.write(path, line_numbers)
        FileUtils.mkdir_p(File.dirname(path))
        temp = Tempfile.new(["#{File.basename(path)}.", ".tmp"], File.dirname(path))
        temp_path = temp.path
        line_numbers.each { |line_number| temp.puts line_number }
        temp.close
        File.rename(temp_path, path)
        temp_path = nil
      ensure
        temp&.close
        File.unlink(temp_path) if temp_path && File.exist?(temp_path)
      end

      def initialize(line_numbers)
        @line_numbers = Array(line_numbers).map(&:to_i).sort.freeze
      end

      def include?(line_number)
        target = line_number.to_i
        low = 0
        high = line_numbers.length
        while low < high
          mid = (low + high) / 2
          if line_numbers[mid] < target
            low = mid + 1
          else
            high = mid
          end
        end
        low < line_numbers.length && line_numbers[low] == target
      end
    end

    module_function

    def select_line_numbers(reader, filters, collapse_config, progress: nil)
      raise ArgumentError, "collapse selection requires collapse" unless collapse_config

      total_records = 0
      selected_records = 0
      current_urlkey = nil
      current_capture = nil
      selected = []

      progress&.call(processed_bytes: 0, total_records: total_records, selected_records: selected_records)
      reader.each_capture do |capture, _raw_line, source_offset|
        total_records += 1
        if Repack.keep?(filters, capture)
          urlkey = capture.urlkey.to_s
          if current_urlkey && urlkey != current_urlkey
            selected << current_capture.line_number
            selected_records += 1
            current_capture = capture
            current_urlkey = urlkey
          else
            current_urlkey ||= urlkey
            current_capture = capture if CaptureCollapse.better?(capture, current_capture, collapse_config)
          end
        end
        progress&.call(processed_bytes: source_offset, total_records: total_records, selected_records: selected_records)
      end

      if current_capture
        selected << current_capture.line_number
        selected_records += 1
      end
      progress&.call(processed_bytes: reader.bytesize, total_records: total_records, selected_records: selected_records, final: true)
      selected
    end
  end
end

require "zlib"

module CDX
  module Backends
    class CDXJ
      class Writer < CDX::Repack::Writer
        def initialize(output_path, **options)
          super
          @gzip = output_path.to_s.end_with?(".gz")
          @tempfile = nil
          @temp_path = nil
          @io = nil
        end

        def start(_prepared)
          if @atomic
            @tempfile = temp_in_output_dir
            @temp_path = @tempfile.path
            @io = output_io(@tempfile)
          else
            raise Error, "output already exists; use force: true to overwrite: #{output_path}" if File.exist?(output_path) && !@force

            FileUtils.mkdir_p(File.dirname(output_path))
            file = File.open(output_path, "wb")
            @io = output_io(file)
          end
        end

        def write(capture, raw_line: nil)
          @io.write(raw_line || Repack.canonical_cdxj(capture))
        end

        def finish(summary:, source_signature:, **_options)
          close_io
          if @atomic
            publish_temp(@temp_path)
          else
            @output_signature = Repack.file_signature(output_path)
          end
          Repacker::Result.new(
            output_path,
            summary.record_count,
            nil,
            summary.raw_bytes,
            nil,
            nil,
            nil,
            nil,
            summary.selected_fingerprint,
            source_signature,
            output_signature,
            "cdxj"
          )
        ensure
          @temp_path = nil if output_signature
        end

        def cleanup
          close_io
          @tempfile&.close
          File.unlink(@temp_path) if @temp_path && File.exist?(@temp_path)
        end

        private

        def output_io(file)
          @gzip ? Zlib::GzipWriter.new(file) : file
        end

        def close_io
          return unless @io

          @io.close unless @io.closed?
          @io = nil
        rescue IOError
          @io = nil
        end
      end
    end
  end
end

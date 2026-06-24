module CDX
  module Backends
    class RbCDX
      class Capture < CDX::Capture
        FIELD_NAMES = %w[
          urlkey
          timestamp
          url
          mime
          mime-detected
          status
          digest
          length
          offset
          filename
          charset
          languages
          redirect
          truncated
        ].freeze

        attr_reader :block, :index

        def initialize(block, index, source_path:)
          @block = block
          @index = index
          super({}, source_path: source_path, line_number: nil, fields: FIELD_NAMES)
        end

        def to_h
          FIELD_NAMES.each_with_object({}) do |field, result|
            value = self.field(field)
            result[field] = value unless value.nil?
          end
        end

        def with_fields(*fields)
          data = self.class.normalize_field_names(fields).each_with_object({}) do |field, result|
            value = self.field(field)
            result[field] = value unless value.nil?
          end
          CDX::Capture.new(data, source_path: source_path, line_number: line_number, fields: data.keys)
        end

        def urlkey
          block.urlkeys[index]
        end

        def timestamp
          Time.at(block.timestamp_epochs[index]).utc.strftime("%Y%m%d%H%M%S")
        end

        def url
          "#{scheme}://#{block.url_suffixes[index]}"
        end

        def scheme
          https? ? "https" : "http"
        end

        def https?
          (block.status_flags[index] & Format::STATUS_FLAG_HTTPS) != 0
        end

        def status
          block.reader.table_value("status", block.status_ids[index])
        end

        def mime
          block.reader.table_value("mime", block.mime_ids[index])
        end

        def mime_detected
          block.reader.table_value("mime-detected", block.mime_detected_ids[index])
        end

        def digest
          bytes = block.digest_bytes(index)
          return nil if bytes.nil? || bytes == ("\0" * 20).b

          Format.base32_encode(bytes)
        end

        def length
          block.lengths[index].to_s
        end

        def offset
          block.offsets[index].to_s
        end

        def filename
          block.reader.reconstruct_filename(
            block.filename_kinds[index],
            block.segment_ids[index],
            block.warc_time_pair_ids[index],
            block.shard_ids[index],
            block.fallback_filename_ids[index]
          )
        end

        def charset
          block.reader.table_value("charset", block.charset_ids[index])
        end

        def languages
          ids = block.language_ids[index]
          return nil if ids.nil? || ids.empty?

          ids.map { |id| block.reader.table_value("language", id) }.join(",")
        end

        def redirect
          block.redirects[index]
        end

        def truncated
          block.reader.table_value("truncated", block.truncated_ids[index])
        end
      end
    end
  end
end

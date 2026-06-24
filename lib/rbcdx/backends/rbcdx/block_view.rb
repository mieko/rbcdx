module CDX
  module Backends
    class RbCDX
      class BlockView
        attr_reader :reader, :entry, :count, :base_timestamp, :hot_columns

        def initialize(reader, entry, count, base_timestamp, hot_columns)
          @reader = reader
          @entry = entry
          @count = count
          @base_timestamp = base_timestamp
          @hot_columns = hot_columns
        end

        def cold_columns
          @cold_columns ||= reader.read_cold_columns(entry)
        end

        def urlkeys
          @urlkeys ||= Format.decode_front_coded_strings(hot_columns.fetch("urlkey_front_codes"), count)
        end

        def url_suffixes
          @url_suffixes ||= Format.decode_front_coded_strings(hot_columns.fetch("url_without_scheme_front_codes"), count)
        end

        def timestamp_epochs
          @timestamp_epochs ||= Format.unpack_unsigned(hot_columns.fetch("timestamp_deltas"), count).map { |delta| base_timestamp + delta }
        end

        def lengths
          @lengths ||= Format.unpack_unsigned(hot_columns.fetch("lengths"), count)
        end

        def offsets
          @offsets ||= Format.unpack_unsigned(hot_columns.fetch("offsets"), count)
        end

        def status_flags
          @status_flags ||= hot_columns.fetch("status_and_hot_flags").bytes
        end

        def mime_flags
          @mime_flags ||= hot_columns.fetch("mime_and_flags").bytes
        end

        def mime_detected_flags
          @mime_detected_flags ||= hot_columns.fetch("mime_detected_and_flags").bytes
        end

        def status_ids
          @status_ids ||= decode_extended_ids(status_flags, 0x3f, 63, hot_columns.fetch("status_extended_ids"))
        end

        def mime_ids
          @mime_ids ||= decode_extended_ids(mime_flags, 0x7f, 127, hot_columns.fetch("mime_extended_ids"))
        end

        def mime_detected_ids
          @mime_detected_ids ||= decode_extended_ids(mime_detected_flags, 0x3f, 63, hot_columns.fetch("mime_detected_extended_ids"))
        end

        def filename_kinds
          @filename_kinds ||= hot_columns.fetch("filename_kind").bytes
        end

        def segment_ids
          @segment_ids ||= Format.unpack_unsigned(hot_columns.fetch("segment_ids"), count)
        end

        def warc_time_pair_ids
          @warc_time_pair_ids ||= Format.unpack_unsigned(hot_columns.fetch("warc_time_pair_ids"), count)
        end

        def shard_ids
          @shard_ids ||= Format.unpack_unsigned(hot_columns.fetch("shard_ids"), count)
        end

        def fallback_filename_ids
          @fallback_filename_ids ||= Format.unpack_unsigned(hot_columns.fetch("fallback_filename_ids"), count)
        end

        def digest_bytes(index)
          cold_columns.fetch("digest").byteslice(index * 20, 20)
        end

        def charset_ids
          @charset_ids ||= decode_sparse_varints(mime_flags, Format::MIME_FLAG_HAS_CHARSET, cold_columns.fetch("charset_ids"))
        end

        def language_ids
          @language_ids ||= decode_sparse_varint_lists(mime_detected_flags, Format::MIME_DETECTED_FLAG_HAS_LANGUAGES, cold_columns.fetch("languages"))
        end

        def truncated_ids
          @truncated_ids ||= decode_sparse_varints(mime_detected_flags, Format::MIME_DETECTED_FLAG_HAS_TRUNCATED, cold_columns.fetch("truncated_ids"))
        end

        def redirects
          @redirects ||= decode_sparse_strings(status_flags, Format::STATUS_FLAG_HAS_REDIRECT, cold_columns.fetch("redirects"))
        end

        private

        def decode_extended_ids(flags, mask, sentinel, data)
          ids = []
          pos = 0
          flags.each do |flag|
            id = flag & mask
            if id == sentinel
              id, pos = Format.read_varint(data, pos)
            end
            ids << id
          end
          assert_consumed!(data, pos, "extended id stream")
          ids
        end

        def decode_sparse_varints(flags, bit, data)
          values = Array.new(count)
          pos = 0
          flags.each_with_index do |flag, index|
            next unless (flag & bit) != 0

            values[index], pos = Format.read_varint(data, pos)
          end
          assert_consumed!(data, pos, "sparse varint stream")
          values
        end

        def decode_sparse_varint_lists(flags, bit, data)
          values = Array.new(count)
          pos = 0
          flags.each_with_index do |flag, index|
            next unless (flag & bit) != 0

            item_count, pos = Format.read_varint(data, pos)
            values[index] = Array.new(item_count) do
              value, next_pos = Format.read_varint(data, pos)
              pos = next_pos
              value
            end
          end
          assert_consumed!(data, pos, "sparse varint-list stream")
          values
        end

        def decode_sparse_strings(flags, bit, data)
          values = Array.new(count)
          pos = 0
          flags.each_with_index do |flag, index|
            next unless (flag & bit) != 0

            length, pos = Format.read_varint(data, pos)
            raise Error, "sparse string exceeds available data" if pos + length > data.bytesize

            values[index] = data.byteslice(pos, length).force_encoding(Encoding::UTF_8)
            pos += length
          end
          assert_consumed!(data, pos, "sparse string stream")
          values
        end

        def assert_consumed!(data, pos, label)
          raise Error, "#{label} has trailing bytes" unless pos == data.bytesize
        end
      end
    end
  end
end

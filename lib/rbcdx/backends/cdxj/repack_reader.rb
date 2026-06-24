module CDX
  module Backends
    class CDXJ
      class RepackReader
        attr_reader :path

        def initialize(path)
          @path = File.expand_path(path)
        end

        def bytesize
          File.size(path)
        end

        def each_capture
          return enum_for(:each_capture) unless block_given?

          parser = Parser.new
          previous_urlkey = nil
          each_line do |line, line_number, source_offset|
            data = parse_line(parser, line, line_number)
            next unless data

            capture = CDX::Capture.new(data, source_path: path, line_number: line_number)
            validate_sorted!(capture, previous_urlkey)
            previous_urlkey = capture.urlkey
            yield capture, raw_cdxj_line(line), source_offset
          end
        end

        private

        def parse_line(parser, line, line_number)
          parser.parse(line)
        rescue CDX::ParseError => error
          raise Backends::RbCDX::Format::EncodeError.new(
            source_path: path,
            line_number: line_number,
            urlkey: nil,
            field: "line",
            value: line.to_s.chomp,
            reason: error.message
          ), cause: error
        end

        def validate_sorted!(capture, previous_urlkey)
          urlkey = capture.urlkey
          if urlkey.nil? || urlkey.to_s.empty?
            raise Backends::RbCDX::Format::EncodeError.new(
              source_path: path,
              line_number: capture.line_number,
              urlkey: nil,
              field: "urlkey",
              value: urlkey,
              reason: "missing required field"
            )
          end
          return unless previous_urlkey && urlkey < previous_urlkey

          raise Backends::RbCDX::Format::EncodeError.new(
            source_path: path,
            line_number: capture.line_number,
            urlkey: urlkey,
            field: "urlkey",
            value: urlkey,
            reason: "input is not sorted by urlkey"
          )
        end

        def raw_cdxj_line(line)
          stripped = line.to_s.lstrip
          return line if stripped.start_with?("{")

          _urlkey, _timestamp, payload = line.to_s.strip.split(/\s+/, 3)
          payload&.start_with?("{") ? line : nil
        end

        def each_line
          line_number = 0
          Reader.open_path(path) do |io, position|
            io.each_line do |line|
              line_number += 1
              yield line, line_number, position&.call
            end
          end
        end
      end
    end
  end
end

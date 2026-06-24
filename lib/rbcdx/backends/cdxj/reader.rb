require "stringio"
require "zlib"

module CDX
  module Backends
    class CDXJ
      class Reader
        attr_reader :path

        def self.open_path(path)
          if path.end_with?(".gz")
            open_gzip_path(path) { |gzip, position| yield gzip, position }
          else
            File.open(path, "r:utf-8") { |file| yield file, -> { file.pos } }
          end
        end

        def initialize(path, parser_factory:)
          @path = File.expand_path(path)
          @parser_factory = parser_factory
        end

        def each_capture
          return enum_for(:each_capture) unless block_given?

          parser = @parser_factory.call
          line_number = 0
          self.class.open_path(path) do |io|
            io.each_line do |line|
              line_number += 1
              data = parser.parse(line)
              next unless data

              yield CDX::Capture.new(data, source_path: path, line_number: line_number)
            end
          end
        end

        def self.open_gzip_path(path)
          File.open(path, "rb") do |file|
            unused = nil
            until file.eof? && unused.to_s.empty?
              gzip = Zlib::GzipReader.new(PrependedIO.new(unused, file))
              yield gzip, -> { file.pos }
              unused = gzip.unused
              gzip.finish
            end
          end
        end
        private_class_method :open_gzip_path

        class PrependedIO
          def initialize(prefix, io)
            @prefix = StringIO.new(prefix.to_s)
            @io = io
          end

          def read(length = nil, outbuf = nil)
            data = length ? read_length(length) : @prefix.read.to_s + @io.read.to_s
            outbuf.replace(data) if outbuf && data
            data
          end

          def readpartial(length, outbuf = nil)
            data = read(length)
            raise EOFError unless data

            outbuf&.replace(data)
            data
          end

          def eof?
            @prefix.eof? && @io.eof?
          end

          private

          def read_length(length)
            data = +""
            while data.bytesize < length
              source = @prefix.eof? ? @io : @prefix
              chunk = source.read(length - data.bytesize)
              break unless chunk

              data << chunk
            end
            data.empty? ? nil : data
          end
        end
        private_constant :PrependedIO
      end
    end
  end
end

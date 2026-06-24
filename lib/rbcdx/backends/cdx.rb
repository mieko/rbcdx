require "stringio"
require "zlib"

module CDX
  module Backends
    class Cdx
      INDEX_FILE_PATTERN = /(?:\.(?:cdx|cdxj)(?:\.gz)?|\Acdx-\d+\.gz)\z/i

      attr_reader :paths

      def self.index_file?(path)
        File.basename(path).match?(INDEX_FILE_PATTERN)
      end

      def initialize(paths, parser_factory:)
        @paths = paths
        @parser_factory = parser_factory
        @zipnum_indexes = ZipNumIndex.find_all(@paths)
      end

      def each_capture(matcher: nil)
        return enum_for(:each_capture, matcher: matcher) unless block_given?

        if matcher && @zipnum_indexes.any?
          each_capture_with_zipnum(matcher) { |capture| yield capture }
        else
          each_capture_from_paths(paths) { |capture| yield capture }
        end
      end

      private

      def each_capture_with_zipnum(matcher)
        zipnum_by_path = @zipnum_indexes.each_with_object({}) do |index, indexes|
          index.paths.each { |path| indexes[path] = index }
        end
        paths.each do |path|
          if (index = zipnum_by_path[path])
            index.captures_for(matcher, parser_factory: @parser_factory, path: path) { |capture| yield capture }
          else
            each_capture_from_paths([path]) { |capture| yield capture }
          end
        end
      end

      def each_capture_from_paths(paths)
        paths.each do |path|
          parser = @parser_factory.call
          line_number = 0
          open_path(path) do |io|
            io.each_line do |line|
              line_number += 1
              data = parser.parse(line)
              next unless data

              yield Capture.new(data, source_path: path, line_number: line_number)
            end
          end
        end
      end

      def open_path(path)
        if path.end_with?(".gz")
          open_gzip_path(path) { |gzip| yield gzip }
        else
          File.open(path, "r:utf-8") { |file| yield file }
        end
      end

      def open_gzip_path(path)
        File.open(path, "rb") do |file|
          unused = nil
          until file.eof? && unused.to_s.empty?
            gzip = Zlib::GzipReader.new(PrependedIO.new(unused, file))
            yield gzip
            unused = gzip.unused
            gzip.finish
          end
        end
      end

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
    end
  end
end

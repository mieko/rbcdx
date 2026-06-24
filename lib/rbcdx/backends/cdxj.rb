module CDX
  module Backends
    class CDXJ
      INDEX_FILE_PATTERN = /(?:\.(?:cdx|cdxj)(?:\.gz)?|\Acdx-\d+\.gz)\z/i

      attr_reader :paths

      def self.index_file?(path)
        File.basename(path).match?(INDEX_FILE_PATTERN)
      end

      def initialize(paths, parser_factory:)
        @paths = paths
        @parser_factory = parser_factory
        @zipnum_indexes = ZipNumIndex.find_all(@paths)
        @reader_by_path = {}
      end

      def each_capture(matcher: nil)
        return enum_for(:each_capture, matcher: matcher) unless block_given?

        if matcher && @zipnum_indexes.any?
          each_capture_with_zipnum(matcher) { |capture| yield capture }
          return
        end

        paths.each do |path|
          reader_for(path).each_capture { |capture| yield capture }
        end
      end

      def capture_pages_supported?
        false
      end

      def capture_page_backend
        "cdxj"
      end

      def capture_page_cursor_version
        nil
      end

      private

      def reader_for(path)
        @reader_by_path[path] ||= Reader.new(path, parser_factory: @parser_factory)
      end

      def each_capture_with_zipnum(matcher)
        zipnum_by_path = zipnum_indexes_by_path
        paths.each do |path|
          if (index = zipnum_by_path[path])
            index.captures_for(matcher, parser_factory: @parser_factory, path: path) { |capture| yield capture }
          else
            reader_for(path).each_capture { |capture| yield capture }
          end
        end
      end

      def zipnum_indexes_by_path
        @zipnum_indexes.each_with_object({}) do |index, indexes|
          index.paths.each { |path| indexes[path] = index }
        end
      end
    end
  end
end

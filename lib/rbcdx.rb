require_relative "rbcdx/version"

module CDX
  Error = Class.new(StandardError)
  ParseError = Class.new(Error)
  InvalidCursor = Class.new(ArgumentError)
  UnsupportedCollapse = Class.new(ArgumentError)
  UnsupportedPageQuery = Class.new(ArgumentError)
end

require_relative "rbcdx/capture"
require_relative "rbcdx/capture_collapse"
require_relative "rbcdx/capture_cursor"
require_relative "rbcdx/capture_page"
require_relative "rbcdx/capture_filters"
require_relative "rbcdx/common_crawl_data"
require_relative "rbcdx/filter"
require_relative "rbcdx/repack_filters"
require_relative "rbcdx/repack_selection"
require_relative "rbcdx/surt"
require_relative "rbcdx/timestamp"
require_relative "rbcdx/url_matcher"
require_relative "rbcdx/backends/cdxj/parser"
require_relative "rbcdx/backends/cdxj/zip_num_index"
require_relative "rbcdx/backends/cdxj/reader"
require_relative "rbcdx/backends/cdxj"
require_relative "rbcdx/backends/rbcdx/format"
require_relative "rbcdx/backends/rbcdx/manifest"
require_relative "rbcdx/backends/rbcdx/block_view"
require_relative "rbcdx/backends/rbcdx/capture"
require_relative "rbcdx/backends/rbcdx/reader"
require_relative "rbcdx/backends/rbcdx"
require_relative "rbcdx/repacker"
require_relative "rbcdx/backends/cdxj/repack_reader"
require_relative "rbcdx/backends/cdxj/writer"
require_relative "rbcdx/backends/rbcdx/writer"
require_relative "rbcdx/batch_repacker"
require_relative "rbcdx/index"
require_relative "rbcdx/http"
require_relative "rbcdx/cli"

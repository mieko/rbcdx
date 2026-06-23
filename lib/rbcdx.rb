require_relative "rbcdx/version"

module CDX
  Error = Class.new(StandardError)
  ParseError = Class.new(Error)
end

require_relative "rbcdx/capture"
require_relative "rbcdx/filter"
require_relative "rbcdx/parser"
require_relative "rbcdx/surt"
require_relative "rbcdx/timestamp"
require_relative "rbcdx/url_matcher"
require_relative "rbcdx/index"
require_relative "rbcdx/http"
require_relative "rbcdx/cli"

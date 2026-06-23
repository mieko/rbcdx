$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "minitest/autorun"
require "fileutils"
require "stringio"
require "tmpdir"
require "zlib"
require "rbcdx"

module FixturePaths
  def fixture_path(name)
    File.expand_path("fixtures/#{name}", __dir__)
  end
end

class Minitest::Test
  include FixturePaths
end

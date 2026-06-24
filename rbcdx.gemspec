require_relative "lib/rbcdx/version"

Gem::Specification.new do |spec|
  spec.name = "rbcdx"
  spec.version = CDX::VERSION
  spec.authors = ["rbcdx contributors"]
  spec.email = []

  spec.summary = "Local CDX/CDXJ index querying for Ruby"
  spec.description = "Read local CDX/CDXJ index files from Ruby and build HTTP range request parts for archived WARC records."
  spec.homepage = "https://github.com/mieko/rbcdx"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 4.0"

  spec.metadata = {
    "source_code_uri" => spec.homepage
  }

  spec.files = Dir[
    "LICENSE",
    "README.md",
    "Rakefile",
    "Gemfile",
    "rbcdx.gemspec",
    "exe/*",
    "doc/**/*.md",
    "lib/**/*.rb"
  ]
  spec.bindir = "exe"
  spec.executables = ["rbcdx"]
  spec.require_paths = ["lib"]

  spec.add_dependency "csv", "~> 3.0"
  spec.add_dependency "base64", "~> 0.3"
  spec.add_dependency "zstd-ruby", "~> 1.5"
end

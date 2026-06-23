# rbcdx

`rbcdx` reads local CDX and CDXJ index files from Ruby.

Use it to find captures, inspect capture metadata, and build HTTP `Range`
request parts for fetching WARC records from a remote archive such as Common
Crawl.

```ruby
require "rbcdx"

index = CDX::Index.open("/data/cc-index/CC-MAIN-2025-43/indexes/cdx-*.gz")
capture = index.captures("reddit.com/", closest: "202510").first

puts capture.url
puts capture.timestamp
puts capture.filename
puts capture.byte_range
```

## Add To Your Gemfile

```ruby
gem "rbcdx", git: "https://github.com/mieko/rbcdx.git"
```

You can pin the dependency to a tag or commit:

```ruby
gem "rbcdx", git: "https://github.com/mieko/rbcdx.git", tag: "v0.1.0"
gem "rbcdx", git: "https://github.com/mieko/rbcdx.git", ref: "COMMIT_SHA"
```

## Input Files

`rbcdx` operates on CDX/CDXJ index files:

| Input | Example |
| --- | --- |
| Common Crawl CDXJ shard | `cdx-00000.gz` |
| CDX/CDXJ text file | `captures.cdxj` |
| gzip-compressed CDX/CDXJ file | `captures.cdxj.gz` |
| Glob or directory | `indexes/*.gz`, `indexes/CC-MAIN-2025-43` |

It does not read WARC/WAT/WET content files, Common Crawl path-list files,
Parquet/ORC URL indexes, or ZipNum metadata. Index records need `filename`,
`offset`, and `length` fields if you want to fetch WARC records with HTTP range
requests.

## Getting Common Crawl CDXJ Shards

Pick a crawl id from `https://index.commoncrawl.org/collinfo.json` or
`https://data.commoncrawl.org/cc-index/collections/index.html`. Each crawl has
a path list at:

```text
https://data.commoncrawl.org/crawl-data/CC-MAIN-YYYY-WW/cc-index.paths.gz
```

Download the shards you want by prefixing each listed path with
`https://data.commoncrawl.org/`:

```sh
mkdir -p indexes/CC-MAIN-YYYY-WW

curl -fsSL https://data.commoncrawl.org/crawl-data/CC-MAIN-YYYY-WW/cc-index.paths.gz |
  gzip -dc |
  head -10 |
  while read -r path; do
    curl -fL "https://data.commoncrawl.org/$path" \
      -o "indexes/CC-MAIN-YYYY-WW/$(basename "$path")"
  done
```

## Query Captures

```ruby
index = CDX::Index.open("indexes/CC-MAIN-YYYY-WW")

index.captures("commoncrawl.org/*", limit: 10, filters: "=status:200") do |capture|
  puts [capture.status, capture.timestamp, capture.url].join(" ")
end
```

`captures` returns an Enumerator when called without a block:

```ruby
urls = index.captures("*.commoncrawl.org", match: :domain).map(&:url)
count = index.captures("example.com/*").count
```

Supported URL patterns:

- `example.com/page` matches one canonical page on `http` or `https`
- `example.com/*` matches that host and path prefix
- `*.example.com` matches the host and subdomains

Useful query options:

```ruby
index.captures(
  "*.commoncrawl.org",
  from: "202510",
  to: "202511",
  closest: "20251015000000",
  sort: :reverse_timestamp,
  filters: {"mime" => /html/}
)
```

Filters can be strings (`=status:200`, `!=status:404`, `~mime:text/.+`),
hashes, or procs. `sort:` accepts `:timestamp` or `:reverse_timestamp`.

## Capture Objects

`CDX::Capture` exposes common fields as methods:

```ruby
capture.url
capture.timestamp
capture.status
capture.filename
capture.warc_offset
capture.warc_length
capture.byte_range
```

Captures are also hash-like for raw CDX fields:

```ruby
capture["mime-detected"]
capture.to_h
capture.slice("url", "status")
capture.with_fields("url", "status")
```

Use `fields:` when you only want selected fields:

```ruby
index.captures("commoncrawl.org/*", fields: %w[url status]).map(&:to_h)
```

## Build HTTP Range Requests

`CDX::HTTP::RemoteArchive` converts captures into request objects for fetching
WARC records with your HTTP client:

```ruby
archive = CDX::HTTP::RemoteArchive.new(index)
request = archive.requests("reddit.com/", closest: "202510").first

request.url                # full remote WARC object URL
request.request_uri        # path plus query for Net::HTTP
request.range_header_value # "bytes=start-end"
request.headers            # { "Range" => "bytes=start-end" }
```

When the index path or capture filename looks like Common Crawl `CC-MAIN`
data, `RemoteArchive` uses `https://data.commoncrawl.org`. Pass `base_url:` for
mirrors or other archives:

```ruby
archive = CDX::HTTP::RemoteArchive.new(index, base_url: "https://archive.example/mirror")
```

Net::HTTP example:

```ruby
Net::HTTP.start(request.host, request.port, use_ssl: request.https?) do |http|
  response = http.get(request.request_uri, request.headers)
end
```

Other clients can usually use `request.url` and `request.headers` directly:

```ruby
Faraday.get(request.url, nil, request.headers)
HTTParty.get(request.url, headers: request.headers)
Excon.get(request.url, headers: request.headers)
::HTTP.headers(request.headers).get(request.url)
```

## CLI

```sh
rbcdx captures --index './indexes' --limit 10 'commoncrawl.org/*'
rbcdx count --index './indexes' 'commoncrawl.org/*'
```

Use `--format jsonl|text|csv` for capture output.

## Notes

- `rbcdx` streams local index files. It does not use ZipNum block lookup files.
- It builds WARC object URLs and range headers; it does not parse WARC records.
- Inspired by Common Crawl's [`cdx_toolkit`](https://github.com/commoncrawl/cdx_toolkit).

## License

MIT. See `LICENSE`.

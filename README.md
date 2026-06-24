# rbcdx

`rbcdx` reads local Common Crawl-style CDX/CDXJ indexes from Ruby.

A CDX/CDXJ index tells you which archived URLs exist and where their WARC bytes
live. rbcdx queries those local index files, returns capture metadata, and can
build HTTP `Range` request parts for fetching WARC records from a remote archive
such as Common Crawl. It does not parse WARC content.

Use rbcdx when you want to find captures, inspect capture metadata, count
matches, or build byte-range requests from local index files. It does not search
Common Crawl's hosted CDX API or read WARC/WAT/WET content directly.

## Requirements And Install

- Ruby 4.0+
- Local CDX/CDXJ index files, or packed `.rbcdx` files generated from them

Add rbcdx to your Gemfile from GitHub:

```ruby
gem "rbcdx", git: "https://github.com/mieko/rbcdx.git"
```

You can pin the dependency to a tag or commit:

```ruby
gem "rbcdx", git: "https://github.com/mieko/rbcdx.git", tag: "v0.1.0"
gem "rbcdx", git: "https://github.com/mieko/rbcdx.git", ref: "COMMIT_SHA"
```

Then install:

```sh
bundle install
```

## Quick Start

List Common Crawl crawls and download the index files you want. The download
command below fetches a full crawl by default. Full Common Crawl CDXJ indexes
are large; CC-MAIN-2026-25 is about 165 GiB across 300 `cdx-*.gz` shards.

```sh
rbcdx data list
rbcdx data download --output ./indexes
```

`download` uses the latest crawl by default and writes files to
`./indexes/<CRAWL_ID>/`. Use `--limit N` when you only want a small trial
download.

Open the downloaded directory and query it:

```ruby
require "rbcdx"

crawl = "CC-MAIN-2026-25" # replace with the crawl directory you downloaded
index = CDX::Index.open("./indexes/#{crawl}")
capture = index.captures("reddit.com/", closest: "202606").first

puts capture.url
puts capture.timestamp
puts capture.filename
puts capture.byte_range
```

The CLI can query the same directory; replace `CC-MAIN-2026-25` with the crawl
directory you downloaded:

```sh
CRAWL=CC-MAIN-2026-25
rbcdx captures --index "./indexes/$CRAWL" --limit 10 'commoncrawl.org/*'
rbcdx count --index "./indexes/$CRAWL" 'commoncrawl.org/*'
```

Use `--format jsonl|text|csv` for capture output.

## Querying Local Indexes

The normal path is to point `CDX::Index` at a directory:

```ruby
crawl_dir = "./indexes/CC-MAIN-2026-25" # replace with your downloaded crawl
index = CDX::Index.open(crawl_dir)

index.captures("commoncrawl.org/*", limit: 10, filters: "=status:200") do |capture|
  puts [capture.status, capture.timestamp, capture.url].join(" ")
end
```

`captures` returns an Enumerator when called without a block:

```ruby
urls = index.captures("*.commoncrawl.org", match: :domain).map(&:url)
count = index.captures("example.com/*").count
```

Directories are preferred because rbcdx can discover supported index files and
lookup metadata beside them. Files and globs are still supported when you want
tighter control:

| Input | Example |
| --- | --- |
| Directory | `indexes/CC-MAIN-2026-25` |
| Glob | `indexes/CC-MAIN-2026-25/cdx-*.gz` |
| Common Crawl CDXJ shard | `cdx-00000.gz` |
| CDX/CDXJ text file | `captures.cdxj` |
| gzip-compressed CDX/CDXJ file | `captures.cdxj.gz` |
| Packed rbcdx index, after repacking | `cdx-00000.rbcdx` |

Supported URL patterns:

- `example.com/page` matches one canonical page on `http` or `https`
- `example.com/*` matches that host and path prefix
- `*.example.com` matches the host and subdomains

Useful query options:

```ruby
index.captures(
  "*.commoncrawl.org",
  from: "202606",
  to: "202607",
  closest: "20260615000000",
  sort: :reverse_timestamp,
  filters: [:status_200, :html]
)
```

Filters can be CDX field-filter strings (`=status:200`, `!=status:404`,
`~mime:text/.+`), hashes, procs, or named-filter symbols such as
`:status_200`, `:html`, or `:extractable_text`. Ruby strings are always field
filters; use symbols for named filters in code.

Built-in named filters are `status_200`, `html`, `text_like`, `asset_like`,
`site_metadata`, `warc`, and `extractable_text`. The `extractable_text` preset
keeps normal WARC-backed `200` captures whose MIME type looks text-extractable,
while dropping obvious assets and site metadata. `sort:` accepts `:timestamp` or
`:reverse_timestamp`.

When a Common Crawl `cluster.idx` file is in the directory with `cdx-*.gz`
shards, rbcdx uses it automatically to avoid scanning unrelated CDXJ blocks for
URL-pattern queries.

## Cursor Pages

For durable, bounded work queues over packed `.rbcdx` indexes, pass
`page_size:` to `captures`. Page mode returns a materialized `CDX::CapturePage`:
the captures, `next_cursor`, and `exhausted?` state are known before the method
returns.

```ruby
cursor = saved_cursor

loop do
  page = index.captures(
    "example.com/news/*",
    filters: :extractable_text,
    page_size: 500,
    cursor: cursor
  )

  page.each { |capture| process(capture) }

  break if page.exhausted?
  cursor = page.next_cursor
  save_cursor(cursor.to_s)
end
```

`CDX::CapturePage` includes `Enumerable`, so captures are still consumed with
`each`, `map`, and other normal collection helpers. `page.next_cursor` is a
`CDX::CaptureCursor`; store `page.next_cursor.to_s` when you need a
JSON/database-friendly value, and pass either the cursor object or serialized
string back as `cursor:`.

Only persist `page.next_cursor` after successfully processing the whole page. If
you stop early and save the cursor, the next run may skip captures that were
returned in the page but not processed.

Cursor pages are returned in native index order. They currently support packed
`.rbcdx` indexes only; CDX/CDXJ, gzip, `sort:`, and `closest:` are not resumable
yet. Procs or other unstable filters require `filter_signature:` so rbcdx can
tell whether a saved cursor belongs to the same logical query. Named filters
participate automatically in cursor query signatures with their canonical
underscore names; for example `filters: [:status_200, :warc]` is signed as
`["status_200", "warc"]`. For more query filter details, see
[Querying](doc/query.md).

## Capture Objects

`CDX::Capture` exposes common fields as methods:

```ruby
capture.url
capture.timestamp
capture.status
capture.mime_detected
capture.digest
capture.filename
capture.length
capture.warc_offset
capture.warc_length
capture.byte_range
```

Use `to_h` when you want a materialized hash:

```ruby
capture.to_h
```

Use `fields:` when you only want selected fields:

```ruby
index.captures("commoncrawl.org/*", fields: %w[url status]).map(&:to_h)
```

## HTTP Range Requests

`CDX::HTTP::RemoteArchive` converts captures into request objects for fetching
WARC records with your HTTP client:

```ruby
crawl_dir = "./indexes/CC-MAIN-2026-25" # replace with your downloaded crawl
index = CDX::Index.open(crawl_dir)
archive = CDX::HTTP::RemoteArchive.new(index)
request = archive.requests("reddit.com/", closest: "202606").first

request.url                # full remote WARC object URL
request.request_uri        # path plus query for Net::HTTP
request.range_header_value # "bytes=start-end"
request.headers            # { "Range" => "bytes=start-end" }
```

When the index path or capture filename looks like Common Crawl `CC-MAIN` data,
`RemoteArchive` uses `https://data.commoncrawl.org`. Pass `base_url:` for
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

## Common Crawl Data Commands

Use `rbcdx data` to list available Common Crawl crawls and download local index
files:

```sh
rbcdx data list
rbcdx data download --output ./indexes
rbcdx data download --crawl CC-MAIN-2026-25 --output ./indexes
```

`download` writes files to `./indexes/<CRAWL_ID>/`. It downloads the `cdx-*.gz`
shards and `cluster.idx` lookup file, skipping existing files unless you pass
`--force`.

Useful options:

- `--crawl CC-MAIN-YYYY-WW` chooses a crawl instead of the latest
- `--limit N` downloads only the first N index files for a smaller trial run
- `--no-zipnum` skips `cluster.idx`
- `--dry-run` prints planned downloads without writing files

Downloaded paths are written to stdout; progress is written to stderr.

## Packed Files

`.rbcdx` files are compact binary indexes built from sorted CDXJ input. rbcdx
can query them directly, without keeping the original `cdx-*.gz` shard next to
the packed file.

Packed files are more efficient indexes for repeated local lookups and direct
access to each capture's WARC range-request metadata. Keep the original Common
Crawl `cdx-*.gz` shards when you need portable source data or plan to repack
with different filters later.

| | Common Crawl `cdx-*.gz` | `.rbcdx` |
| --- | --- | --- |
| Format | Compressed CDXJ text | rbcdx binary index |
| Portability | Standard Common Crawl shard; easy to inspect and reuse | Optimized for rbcdx queries |
| Storage | Larger; CC-MAIN-2026-25 is about 165 GiB across 300 shards | Smaller; a four-shard sample packed to about 72%, which would put that crawl around 119 GiB |
| Lookup | Decompresses and parses matching CDXJ records; `cluster.idx` can skip unrelated ranges when available | Seeks directly to matching records in the packed index |
| Best For | Interchange, archiving, and rebuilding derived indexes | Repeated querying and WARC range lookups |
| Setup | Ready to use from Common Crawl | Requires a one-time repack step |

Packing time depends on hardware and filters. As a rough reference, an
unfiltered CC-MAIN-2026-25 sample took about 15 minutes per shard with default
settings on an M1 Max.

## Repacking

Use `rbcdx repack` to convert sorted CDXJ files into `.rbcdx` files.

To replace a directory of `cdx-*.gz` shards with packed files in place:

```sh
cd ./indexes/CC-MAIN-2026-25
rbcdx repack --delete-when-processed
```

`--delete-when-processed` deletes each source shard only after its output has
been written, atomically published, and recorded. Once all source shards have
been deleted, the directory can be opened normally as packed rbcdx indexes.

If you want to keep the original `cdx-*.gz` files, write packed files to a
separate directory:

```sh
rbcdx repack --output-dir ./rbcdx-indexes ./indexes/CC-MAIN-2026-25
```

Non-dry-run repacks write progress and resume instructions to stderr. Successful
output paths are written to stdout, one per line, so scripts can consume them.

`CDX::Index` treats a local index directory as one backend format at a time, so
a directory containing both `cdx-*.gz` and `.rbcdx` files should be treated as a
migration workspace, not as a queryable index.

For query filtering and cursor signatures, see [Querying](doc/query.md). For
dry-run, resume, repack filtering, same-format output, and single-file repack
details, see [Repacking](doc/repack.md).

## What rbcdx Does Not Do

`rbcdx` does not parse WARC/WAT/WET files, crawl the web, or use Common Crawl's
hosted CDX API for capture searches. Capture queries run against local index
files. If you want WARC bytes, your index records need usable `filename`,
`offset`, and `length` fields so an HTTP client can request the right byte
range.

It also does not read Common Crawl path-list files, WARC content files, or
Parquet/ORC URL indexes as capture indexes.

## Notes

- rbcdx streams CDX/CDXJ files and seeks within packed `.rbcdx` indexes.
- `cluster.idx`, when present, is used automatically for CDX/CDXJ queries.
- rbcdx builds WARC object URLs and range headers; it does not parse WARC records.
- Query filters and cursor signatures are documented in [`doc/query.md`](doc/query.md).
- The `.rbcdx` on-disk format is documented in [`doc/rbcdx-format.md`](doc/rbcdx-format.md).
- Inspired by Common Crawl's [`cdx_toolkit`](https://github.com/commoncrawl/cdx_toolkit).

## License

MIT. See `LICENSE`.

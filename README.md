# rbcdx

`rbcdx` reads Common Crawl-style CDX/CDXJ indexes from Ruby.

Use it when you already have local index files and want to find captures,
inspect capture metadata, count matches, or build HTTP `Range` request parts
for fetching WARC records from a remote archive such as Common Crawl.

```ruby
require "rbcdx"

index = CDX::Index.open("./indexes/CC-MAIN-2026-25")
capture = index.captures("reddit.com/", closest: "202606").first

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

## CDX/CDXJ Indexes

The normal path is to point `CDX::Index` at a directory of local index files:

```ruby
index = CDX::Index.open("./indexes/CC-MAIN-2026-25")

index.captures("commoncrawl.org/*", limit: 10, filters: "=status:200") do |capture|
  puts [capture.status, capture.timestamp, capture.url].join(" ")
end
```

`captures` returns an Enumerator when called without a block:

```ruby
urls = index.captures("*.commoncrawl.org", match: :domain).map(&:url)
count = index.captures("example.com/*").count
```

Directories are preferred because `rbcdx` can discover the supported index
files and any lookup metadata beside them. Files and globs are still supported
when you want tighter control:

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
  filters: {"mime" => /html/}
)
```

Filters can be strings (`=status:200`, `!=status:404`, `~mime:text/.+`),
hashes, or procs. `sort:` accepts `:timestamp` or `:reverse_timestamp`.

When a Common Crawl `cluster.idx` file is in the directory with `cdx-*.gz`
shards, `rbcdx` uses it automatically to avoid scanning unrelated CDX blocks
for URL-pattern queries.

## What rbcdx Does Not Do

`rbcdx` does not parse WARC/WAT/WET files, crawl the web, or use Common
Crawl's hosted CDX API for capture searches. Capture queries run against local
index files. The `rbcdx data` helper can fetch crawl metadata and download
public CDX shards for local use.

It also does not read Common Crawl path-list files, WARC content files, or
Parquet/ORC URL indexes as capture indexes. If you want WARC bytes, your index
records need usable `filename`, `offset`, and `length` fields so an HTTP client
can request the right byte range.

## Common Crawl Index Files

Use `rbcdx data` to list available Common Crawl crawls and download local index
files:

```sh
rbcdx data list
rbcdx data download --output ./indexes
rbcdx data download --crawl CC-MAIN-2026-25 --output ./indexes
```

`download` uses the latest crawl by default and writes files to
`./indexes/<CRAWL_ID>/`. It downloads the `cdx-*.gz` shards and `cluster.idx`
lookup file, skipping existing files unless you pass `--force`.

Use `--limit N` when you only want a small sample, `--no-zipnum` to skip
`cluster.idx`, and `--dry-run` to print planned downloads without writing
files. Downloaded paths are written to stdout; progress is written to stderr.

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
archive = CDX::HTTP::RemoteArchive.new(index)
request = archive.requests("reddit.com/", closest: "202606").first

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

## Packed Files

For repeated local queries, `.rbcdx` files are a compact binary alternative to
the original Common Crawl `cdx-*.gz` shards. A `.rbcdx` file is a
self-contained packed index that rbcdx can open directly, so you can query it
without keeping the source gzip shard alongside it.

Use packed files when you want smaller local index files, faster repeated
lookups, and direct access to each capture's WARC range-request metadata. Keep
the original `cdx-*.gz` shards when you need the portable Common Crawl source
data, or when you may want to rebuild packed indexes with different filters
later.

You can create `.rbcdx` files with `rbcdx repack` from sorted CDXJ input.

| | Common Crawl `cdx-*.gz` | `.rbcdx` |
| --- | --- | --- |
| Source | Official compressed CDXJ shards | Packed local index, often generated from CDXJ shards |
| Compatibility | Text CDXJ inside gzip; broadly inspectable | Ruby-specific binary packed index |
| Storage | Large compressed text | Usually smaller for Common Crawl-style records |
| Lookup | Streams and parses compressed text; faster with `cluster.idx` when present | Seeks into the packed local index |
| Best For | Interchange, archiving, rebuilding derived indexes | Repeated local querying and range-request lookup |
| Tradeoff | More disk and more scanning | Format-specific files; repack step when starting from CDXJ |

Exact size and speed gains depend on the crawl and filters you choose.

## Repacking

Use `rbcdx repack` to convert sorted CDXJ files into `.rbcdx` files:

```sh
cd ./indexes/CC-MAIN-2026-25
rbcdx repack
```

By default, batch repack uses the current directory as both input and output.
You can also name the input and output directories explicitly:

```sh
rbcdx repack --output-dir ./rbcdx-indexes ./indexes/CC-MAIN-2026-25
```

Non-dry-run repacks write progress and resume instructions to stderr. Successful
output paths are written to stdout, one per line, so scripts can consume them.

Use `--dry-run` to preview a repack without writing files:

```sh
rbcdx repack --filter extractable-text --dry-run
```

Dry runs print the output file each input would create. With
`--delete-when-processed`, they also print the source file that would be deleted
after the output is written. They stream each input once to report filter
selectivity, for example `2 of 3 records passed filters`, but they do not sort,
compress, write packed files, update state, or delete sources.

`CDX::Index` treats a local index directory as one backend format at a time, so
a directory containing both `cdx-*.gz` and `.rbcdx` files should be treated as a
migration workspace, not as a queryable index.

Batch repack writes a resume log in the directory where you ran the command, so
interrupted work can continue without repeating the original arguments:

```sh
rbcdx repack --resume
```

The log records the original input paths, output directory, filters, and format.
It is removed after a successful batch.

If disk space is tight, `--delete-when-processed` deletes each source shard only
after its output has been written, atomically published, and recorded:

```sh
rbcdx repack --delete-when-processed
```

Once all source shards have been deleted, the directory can be opened normally
as packed rbcdx indexes.

`rbcdx` is the default output format. You can also keep CDXJ output and use
repack as a streaming filter:

```sh
rbcdx repack --output-format cdxj --filter extractable-text --output-dir ./filtered ./indexes/CC-MAIN-2026-25
```

In CDXJ mode, `--output-format` controls the record format. For single-file
outputs, `.gz` controls only CDXJ compression. Batch output preserves input
basenames when writing to a different directory; when writing beside the source
file, rbcdx inserts `.filtered` so it does not overwrite the input.

Repacking can also filter records. Named repack filters are useful presets:

```sh
rbcdx repack --filter extractable-text
```

`extractable-text` keeps normal WARC-backed `200` captures whose MIME type
looks text-extractable, while dropping obvious assets and site metadata such as
images, scripts, stylesheets, fonts, PDFs, `robots.txt`, sitemaps, and web
manifests.

Built-in named filters are:

| Filter | Keeps records that... |
| --- | --- |
| `status-200` | have CDX status `200` |
| `warc` | point at a normal `/warc/` object |
| `html` | have `text/html` in `mime` or `mime-detected` |
| `text-like` | are plain text, Markdown, HTML, XHTML, RSS/Atom/RDF, or generic XML documents |
| `asset-like` | look like static assets by MIME type or URL extension |
| `site-metadata` | look like `robots.txt`, sitemaps, manifests, or `.well-known` metadata |
| `extractable-text` | combine `status-200`, `warc`, `text-like`, `-asset-like`, and `-site-metadata` |

`text-like` accepts `text/plain`, Markdown MIME types, `text/html`, `text/xml`,
`application/xml`, `application/xhtml+xml`, and RSS/Atom/RDF XML MIME types.
It intentionally does not treat every `+xml` MIME type as text content, because
Common Crawl includes XML-backed playlists, map files, and media descriptors.
`asset-like` rejects images, audio, video, fonts, CSS, JavaScript, PDFs, and
common static-file extensions such as `.jpg`, `.png`, `.gif`, `.svg`, `.css`,
`.js`, `.woff2`, `.mp4`, and `.zip`.
`site-metadata` treats sitemap-looking XML files as metadata, including names
that contain `sitemap` and either end in `.xml`/`.xml.gz` or have an XML-ish
reported or detected MIME type.

Use `+name` to require a named filter and `-name` to exclude records matching a
named filter. For example, this is equivalent to the preset above:

```sh
rbcdx repack --filter +status-200,+warc,+text-like,-asset-like,-site-metadata
```

Use `--where` for normal CDX field filters:

```sh
rbcdx repack --output-dir ./rbcdx-200 --where '=status:200' ./indexes/CC-MAIN-2026-25
```

Single-file output is available when you want exact control:

```sh
rbcdx repack --output ./rbcdx-indexes/cdx-00000.rbcdx ./indexes/CC-MAIN-2026-25/cdx-00000.gz
rbcdx repack --output-format cdxj --output ./filtered/cdx-00000.gz ./indexes/CC-MAIN-2026-25/cdx-00000.gz
```

`--force` is required to overwrite an existing output.

## CLI

```sh
rbcdx data list
rbcdx data download --output './indexes'
rbcdx captures --index './indexes/CC-MAIN-2026-25' --limit 10 'commoncrawl.org/*'
rbcdx count --index './indexes/CC-MAIN-2026-25' 'commoncrawl.org/*'
rbcdx repack --output-dir './rbcdx-indexes' './indexes/CC-MAIN-2026-25'
```

Use `--format jsonl|text|csv` for capture output.

## Notes

- `rbcdx` streams CDX/CDXJ files and seeks within packed `.rbcdx` indexes.
- `cluster.idx`, when present, is used automatically for CDX/CDXJ queries.
- `rbcdx` builds WARC object URLs and range headers; it does not parse WARC records.
- The `.rbcdx` on-disk format is documented in [`doc/rbcdx-format.md`](doc/rbcdx-format.md).
- Inspired by Common Crawl's [`cdx_toolkit`](https://github.com/commoncrawl/cdx_toolkit).

## License

MIT. See `LICENSE`.

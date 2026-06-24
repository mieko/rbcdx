# Querying

`CDX::Index#captures` queries local CDX/CDXJ or packed `.rbcdx` index files and
returns `CDX::Capture` records. Query filters can be CDX field filters or shared
named capture filters.

## Thread Safety

Open one `CDX::Index` per worker thread or process by default. rbcdx reads index
files without modifying them, but the `CDX::Index` object keeps lazy reader and
lookup caches, and callers can provide custom parser or filter objects.
Per-worker indexes keep that state local while still letting each query open its
own file handles.

Do not share one index across workers unless you serialize all access to it with
a mutex. If you do serialize a shared index, use it only for read-only queries
against stable index files and thread-safe caller-provided parser/filter state.
Never have multiple workers consume the same Enumerator returned by `captures`;
start a separate query in each worker, or distribute materialized `.rbcdx`
cursor pages. Reopen the index when files are added, replaced, or removed.

## Ruby Filters

Use CDX field-filter strings when matching index fields directly:

```ruby
index.captures("example.com/news/*", filters: "=status:200")
index.captures("example.com/news/*", filters: ["=status:200", "~mime:text/.+"])
```

Use symbols for shared named filters:

```ruby
index.captures(
  "example.com/news/*",
  match: :prefix,
  filters: :extractable_text
)

index.captures(
  "example.com/news/*",
  match: :prefix,
  filters: [:status_200, :warc, :html]
)
```

Ruby strings are always parsed as CDX field filters, not named filters. Use
`filters: :extractable_text`, not `filters: "extractable_text"`. Hyphenated
names such as `:"extractable-text"` are not accepted.

Named filters can be mixed with field filters:

```ruby
index.captures(
  "example.com/news/*",
  match: :prefix,
  filters: ["~url:/news/", :extractable_text]
)
```

Ruby symbol named filters are positive terms. For custom negative query logic,
pass a callable filter and provide `filter_signature:` when using cursor pages.

## Built-In Named Filters

The built-in named filters are shared with repack filtering:

| Filter | Meaning |
| --- | --- |
| `status_200` | CDX status is `200` |
| `warc` | Record points at a normal `/warc/` object |
| `html` | `mime` or `mime-detected` contains `text/html` |
| `text_like` | Common text, HTML, XML, XHTML, RSS, Atom, and RDF MIME types |
| `asset_like` | Images, audio, video, fonts, CSS, JavaScript, PDFs, or common static-file extensions |
| `site_metadata` | `robots.txt`, manifests, `.well-known` metadata, or sitemap-looking XML files |
| `extractable_text` | Combines `status_200`, `warc`, `text_like`, `-asset_like`, and `-site_metadata` |

`extractable_text` is a capture-metadata heuristic. It is useful for discovery
passes that want likely parseable text payloads, but it does not guarantee that
the fetched WARC payload parses as article text.

## CLI Filters

`rbcdx captures --filter` accepts CDX field filters and named filter
expressions:

```sh
rbcdx captures --index ./indexes/CC-MAIN-2026-25 --filter extractable_text 'example.com/news/*'
rbcdx captures --index ./indexes/CC-MAIN-2026-25 --filter '+status_200,+warc,+text_like,-asset_like' 'example.com/news/*'
rbcdx captures --index ./indexes/CC-MAIN-2026-25 --filter '=status:200' --filter html 'example.com/news/*'
```

For query CLI filters, strings with `:` are CDX field filters and no-colon
terms are named filters. Multiple `--filter` flags may mix the two forms. A
comma-separated expression that starts with a named term can include later field
filters, for example:

```sh
rbcdx captures --filter 'html,~url:get-started' 'example.com/*'
```

`rbcdx repack --filter` always parses named filter expressions. Use
`rbcdx repack --where` for CDX field filters during repack.

## URL-Key Collapse

Packed `.rbcdx` queries can return one representative capture per CDX URL key:

```ruby
index.captures(
  "dailyadvance.com/news/local/*",
  match: :prefix,
  filters: :extractable_text,
  collapse: :urlkey
)
```

`collapse: :urlkey` groups by the URL key in the current logical index and
keeps the highest CDX timestamp in each group. `collapse_order:` defaults to
`:latest`; `:latest` is the only supported order in this version. Collapse runs
after URL matching, timestamp bounds, and filters, so if the newest raw capture
does not pass the filters, an older matching capture can win.

Native output order remains URL-key/index order, not global timestamp order.
`limit:` counts collapsed groups. Query collapse is not supported with `sort:`
or `closest:`.

Query-time collapse currently requires `.rbcdx` input. For multi-file `.rbcdx`
queries, rbcdx validates that the selected files are globally grouped by URL
key, allowing the same URL key at an adjacent file boundary. If rbcdx cannot
prove that grouping, it raises `CDX::UnsupportedCollapse` instead of collapsing
per physical file. This proof uses `.rbcdx` file URL-key ranges before scanning
captures, so a raw multi-file layout with overlapping or out-of-order ranges may
be rejected even when later filters would exclude the offending records.

The CLI exposes the same option:

```sh
rbcdx captures --index ./rbcdx-indexes --filter extractable_text --collapse urlkey 'example.com/news/*'
rbcdx count --index ./rbcdx-indexes --collapse urlkey 'example.com/news/*'
```

## Cursor Pages

Pass `page_size:` to `captures` for resumable page mode over packed `.rbcdx`
indexes:

```ruby
page = index.captures(
  "dailyadvance.com/news/local/*",
  match: :prefix,
  filters: :extractable_text,
  collapse: :urlkey,
  page_size: 500,
  cursor: saved_cursor
)
```

With `collapse: :urlkey`, `page_size:` counts URL-key groups rather than raw
captures. Page cursors resume at group boundaries, so a page will not split a
URL-key group and lose the capture that should represent it.

Cursor query signatures use canonical underscore names for named filters. For
example, `filters: [:status_200, :warc]` signs the named-filter portion as:

```json
["status_200", "warc"]
```

CLI negative terms preserve polarity, so
`+status_200,+warc,+text_like,-asset_like` signs as:

```json
["status_200", "warc", "text_like", "-asset_like"]
```

When named filters are present, the cursor query signature also includes the
named-filter vocabulary version. This deliberately invalidates affected cursors
if the built-in named-filter predicates change in the future.

Named symbols and CLI named terms do not require caller-provided
`filter_signature:`. Procs and other unstable filters still require a stable
`filter_signature:` in page mode so rbcdx can reject cursors from a different
logical query.

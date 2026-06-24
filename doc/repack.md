# Repacking

`rbcdx repack` converts sorted CDXJ input into packed `.rbcdx` files by
default. It can also filter records while keeping CDXJ output.

## Basic Batch Repack

To replace the CDXJ shards in the current directory with packed files:

```sh
cd ./indexes/CC-MAIN-2026-25
rbcdx repack --delete-when-processed
```

`--delete-when-processed` removes each source shard only after its packed output
has been written, atomically published, and recorded. Once all source shards
have been deleted, the directory can be opened normally as packed rbcdx indexes.

If you want to keep the original `cdx-*.gz` files, write packed files to a
separate output directory:

```sh
rbcdx repack --output-dir ./rbcdx-indexes ./indexes/CC-MAIN-2026-25
```

Non-dry-run repacks write progress and resume instructions to stderr. Successful
output paths are written to stdout, one per line, so scripts can consume them.

`CDX::Index` treats a local index directory as one backend format at a time, so
a directory containing both `cdx-*.gz` and `.rbcdx` files should be treated as a
migration workspace, not as a queryable index.

## Deleting Sources After Packing

If you already started an in-place repack without deletion, the directory is a
migration workspace until the source shards are removed. For tight disk budgets,
run the batch with deletion from the start:

```sh
rbcdx repack --delete-when-processed
```

If interrupted, resume the same conversion with:

```sh
rbcdx repack --resume
```

Resume also completes any delete-pending work that was recorded before the
interruption. Once all source shards have been deleted, the directory can be
opened normally as packed rbcdx indexes.

## Preview And Resume

Use `--dry-run` to preview a repack without writing files:

```sh
rbcdx repack --filter extractable_text --dry-run
```

Dry runs print the output file each input would create. With
`--delete-when-processed`, they also print the source file that would be deleted
after the output is written. Without collapse, dry runs stream each input once
to report filter selection, for example `2 of 3 records selected`, but they do
not sort, compress, write packed files, update state, or delete sources. With
batch collapse enabled, rbcdx first scans the logical input batch to select the
global URL-key winners, then previews each input against that selection; the
selected count is after filters and collapse.

Batch repack writes a resume log in the directory where you ran the command, so
interrupted work can continue without repeating the original arguments:

```sh
rbcdx repack --resume
```

The log records the original input paths, output directory, filters, output
format, and other plan-bearing options. Resume uses the saved request rather
than current command-line options; run `rbcdx repack --resume` without input
paths or `--output-dir`. The log is removed after a successful batch.

## Filtering

Named repack filters are useful presets. These names are shared with query-time
filters; see [Querying](query.md) for the Ruby and `rbcdx captures` surfaces.

```sh
rbcdx repack --filter extractable_text
```

`extractable_text` keeps normal WARC-backed `200` captures whose MIME type
looks text-extractable, while dropping obvious assets and site metadata such as
images, scripts, stylesheets, fonts, PDFs, `robots.txt`, sitemaps, and web
manifests.

Built-in named filters are:

| Filter | Meaning |
| --- | --- |
| `status_200` | CDX status is `200` |
| `warc` | Record points at a normal `/warc/` object |
| `html` | `mime` or `mime-detected` contains `text/html` |
| `text_like` | `text/plain`, Markdown MIME types, `text/html`, `text/xml`, `application/xml`, `application/xhtml+xml`, and RSS/Atom/RDF XML MIME types; intentionally does not match every `+xml` MIME type, because Common Crawl includes XML-backed playlists, map files, and media descriptors |
| `asset_like` | Images, audio, video, fonts, CSS, JavaScript, PDFs, or common static-file extensions such as `.jpg`, `.png`, `.gif`, `.svg`, `.css`, `.js`, `.woff2`, `.mp4`, and `.zip` |
| `site_metadata` | `robots.txt`, manifests, `.well-known` metadata, or sitemap-looking XML files, including names that contain `sitemap` and either end in `.xml`/`.xml.gz` or have an XML-ish reported or detected MIME type |
| `extractable_text` | Combines `status_200`, `warc`, `text_like`, `-asset_like`, and `-site_metadata` |

Use `+name` to require a named filter and `-name` to exclude records matching a
named filter. For example, this is equivalent to the preset above:

```sh
rbcdx repack --filter +status_200,+warc,+text_like,-asset_like,-site_metadata
```

Use `--where` for normal CDX field filters:

```sh
rbcdx repack --output-dir ./rbcdx-200 --where '=status:200' ./indexes/CC-MAIN-2026-25
```

Use `--only-url-file` to restrict repack output to captures whose canonical
host and path match URL or host/path prefixes from one or more files:

```sh
rbcdx repack --output-dir ./rbcdx-news --only-url-file ./targets.txt ./indexes/CC-MAIN-2026-25
rbcdx repack --output-dir ./rbcdx-news --only-url-file ./local.txt --only-url-file ./more.txt ./indexes/CC-MAIN-2026-25
```

Each allow-list file is a line list. Blank lines and lines whose first
non-space character is `#` are ignored. Entries may be full URLs such as
`https://example.com/news/`, wildcard host URLs such as
`https://*.example.com/news/`, or bare host/path prefixes such as
`example.com/news/`. The URL scheme is ignored, so an `https://` entry can match
HTTP or HTTPS captures. Host-only entries match all paths for that canonical
host. Path entries are prefix matches. Exact hosts do not include subdomains;
`*.example.com` includes both `example.com` and its subdomains.

The canonical deduped allow-list contributes to output filter signatures and
batch plan signatures. Batch resume reuses the saved expanded file paths and
rejects changed allow-list contents before continuing.

## URL-Key Collapse

Use `--collapse urlkey` when you only need the newest matching capture for each
publisher URL key:

```sh
rbcdx repack --output-dir ./rbcdx-latest --filter extractable_text --collapse urlkey ./indexes/CC-MAIN-2026-25
```

Collapse runs after repack filters. For each URL-key group, rbcdx keeps the
highest CDX timestamp; `--collapse-order latest` is the default and the only
supported order in this version. The derived output intentionally discards the
other same-URL-key captures, so they cannot be queried from that output later.

Single-file repack streams a sorted input normally. Batch repack performs one
global selection across the logical batch before writing per-shard outputs, so
duplicate URL keys at adjacent file boundaries still produce one winner. Batch
collapse requires the filtered logical input stream to be globally grouped by
URL key; rbcdx raises `CDX::UnsupportedCollapse` instead of doing per-file
collapse when it sees URL keys move backwards across inputs.

Selection sidecars are stored under the output directory and referenced from
`rbcdx-repack-state.json`; this lets `--resume` and `--delete-when-processed`
continue without rereading deleted sources.

## Other Outputs

`rbcdx` is the default output format. You can also keep CDXJ output and use
repack as a streaming filter:

```sh
rbcdx repack --output-format cdxj --filter extractable_text --output-dir ./filtered ./indexes/CC-MAIN-2026-25
```

In CDXJ mode, `--output-format` controls the record format. For single-file
outputs, `.gz` controls only CDXJ compression. Batch output preserves input
basenames when writing to a different directory; when writing beside the source
file, rbcdx inserts `.filtered` so it does not overwrite the input.

Single-file output is available when you want exact control:

```sh
rbcdx repack --output ./rbcdx-indexes/cdx-00000.rbcdx ./indexes/CC-MAIN-2026-25/cdx-00000.gz
rbcdx repack --output-format cdxj --output ./filtered/cdx-00000.gz ./indexes/CC-MAIN-2026-25/cdx-00000.gz
```

`--force` is required to overwrite an existing output.

# rbcdx File Format

This document describes the current packed rbcdx index format emitted by
`CDX::Repacker` and read by `CDX::Backends::RbCDX`.

The current on-disk variant is `v3a`. Files conventionally use the `.rbcdx`
extension, but the magic string and header identify the actual format.

This format stores CDXJ records in sorted blocks. Each block has a hot frame for
lookup and WARC range-request fields, and a cold frame for fields that are
usually only needed when materializing a full capture.

## Scope

The current writer accepts sorted CDXJ input with these fields:

```text
url
mime
mime-detected
status
digest
length
offset
filename
charset
languages
redirect
truncated
```

These fields are required:

```text
url
mime
status
length
offset
filename
```

Unknown CDXJ fields are rejected. Missing optional fields are encoded as `0`,
empty strings, all-zero digests, or absent sparse values depending on the
column.

Records must be sorted by CDX `urlkey`. A writer must reject unsorted input.

Only `http://` and `https://` URLs are representable in the current variant.
Only nonnegative `length` and `offset` values are representable.

## Byte Order And Primitive Types

All fixed-width integer fields are little-endian.

```text
uint8   1 byte
uint16  2 bytes, little-endian
uint32  4 bytes, little-endian
uint64  8 bytes, little-endian
```

### Varint

Unsigned varints use little-endian base-128 encoding:

```text
repeat:
  byte low_7_bits plus continuation bit
until continuation bit is 0
```

The low seven bits of each byte are payload. Bit `0x80` means another byte
follows. Negative values are not representable.

### Packed Unsigned Integer Column

Packed unsigned integer columns have this shape:

```text
bit_width: uint8
payload: ceil(bit_width * count / 8) bytes
```

If `bit_width` is `0`, every value is `0` and there is no payload.

Otherwise, all values use exactly `bit_width` bits. Values are packed
contiguously. Bits are stored least-significant bit first within each value and
within each byte.

The payload length is exact. Readers must reject packed columns that are too
short or that contain trailing bytes after the required payload.

### Front-Coded String Sequence

Front-coded string sequences have this shape:

```text
restart_interval: uint16
repeat count:
  prefix_length: varint
  suffix_length: varint
  suffix_bytes: byte[suffix_length]
```

Strings are UTF-8 byte strings. The first string of each restart group is
encoded relative to the empty string. Other strings are encoded relative to the
previous decoded string:

```text
decoded = previous.byteslice(0, prefix_length) + suffix_bytes
```

The `count` is not stored in the sequence itself. It is supplied by the table,
block, or column metadata that owns the sequence.

## File Layout

Top-level layout:

```text
magic
header_length
header_json
dictionaries
directory
hot_blocks
cold_blocks
```

### Magic

```text
RBCDXV3A\n
```

The magic is exactly 9 bytes.

### Header Length

Immediately after the magic:

```text
header_length: uint32
```

`header_length` is the byte length of the following JSON header.

### Header JSON

The header is UTF-8 JSON. The current Ruby writer emits compact JSON with keys
sorted lexicographically, but readers must not depend on key order.

Required fields:

```text
magic                  string, "RBCDXV3A\n"
version                integer, 3
variant                string, "v3a"
flags                  integer, currently 0
record_count           integer
block_count            integer
source_kind            integer, 1 for Common Crawl/CDXJ style input
crawl_id               string, may be empty
created_at             integer, Unix epoch seconds
restart_interval       integer
raw_bytes              integer, source bytes read during the write pass
length_sum             integer, sum of decoded length values
offset_sum             integer, sum of decoded offset values
hot_column_names       array of strings
cold_column_names      array of strings
dict_offset            integer, absolute byte offset
dict_length            integer
directory_offset       integer, absolute byte offset
directory_length       integer
hot_blocks_offset      integer, absolute byte offset
hot_blocks_length      integer
cold_blocks_offset     integer, absolute byte offset
cold_blocks_length     integer
```

Offsets are absolute byte offsets from the beginning of the file.

The current reader requires:

```text
version == 3
variant == "v3a"
```

and validates the leading magic bytes before reading the header.

## Dictionaries

The dictionary section stores sorted global string tables.

Section shape:

```text
table_count: uint32
repeat table_count:
  name_length: uint16
  name_bytes: byte[name_length]
  value_count: uint32
  table_length: uint64
  table_data: byte[table_length]
```

`name_bytes` is UTF-8.

`table_data` is a front-coded string sequence with `value_count` strings.

Dictionary values are sorted lexicographically by UTF-8 bytes. Dictionary IDs
are one-based:

```text
id 0: missing/no value
id N: decoded_values[N - 1]
```

The current writer emits these tables, in this order:

```text
status
mime
mime-detected
charset
language
truncated
segment
warc-time-pair
fallback-filename
```

Readers should use table names, not table positions.

## Directory

The directory lets a reader find candidate blocks by `urlkey`.

Section shape:

```text
block_count: uint32
restart_interval: uint16
repeat block_count:
  first_urlkey: front-coded string entry
  last_urlkey: front-coded string entry
  record_count: uint64
  hot_compressed_offset: uint64
  hot_compressed_length: uint64
  hot_uncompressed_length: uint64
  cold_compressed_offset: uint64
  cold_compressed_length: uint64
  cold_uncompressed_length: uint64
  block_base_timestamp: uint64
```

The `first_urlkey` and `last_urlkey` entries use the same entry encoding as a
front-coded string sequence, but without an extra sequence-level
`restart_interval`; the directory-level `restart_interval` applies to both
series. `first_urlkey` is front-coded against the previous block's
`first_urlkey`, and `last_urlkey` is front-coded against the previous block's
`last_urlkey`. Both previous strings reset to empty every `restart_interval`
blocks.

Block offsets are relative to their block section:

```text
hot block absolute offset  = hot_blocks_offset  + hot_compressed_offset
cold block absolute offset = cold_blocks_offset + cold_compressed_offset
```

Blocks must be sorted and non-overlapping:

```text
first_urlkey <= last_urlkey
current.first_urlkey >= previous.last_urlkey
```

Adjacent blocks may share the same boundary key. A reader must therefore scan
all blocks whose key range overlaps the query, not only the last block whose
`first_urlkey <= query`. This matters for duplicate captures of the same URL
when a writer splits blocks by byte or record limits.

## Block Frames

Hot and cold blocks are separately compressed Zstandard frames. The current
writer uses zstd level `6` by default.

After decompression, both block payloads use the same column-frame structure:

```text
block_magic: byte[4]
record_count: uint32
base_timestamp: uint64
column_count: uint16
reserved: uint16
column_offsets: uint32[column_count + 1]
column_data: byte[]
```

`column_offsets` are byte offsets into `column_data`. For column `i`:

```text
start = column_offsets[i]
end   = column_offsets[i + 1]
data  = column_data[start...end]
```

The hot block magic is:

```text
HOT3
```

The cold block magic is:

```text
CLD3
```

`base_timestamp` must match the directory entry's `block_base_timestamp` for
both hot and cold frames.

## Hot Columns

Hot columns are emitted in this exact order:

```text
record_flags
status_and_hot_flags
mime_and_flags
mime_detected_and_flags
urlkey_front_codes
url_without_scheme_front_codes
timestamp_deltas
lengths
offsets
filename_kind
segment_ids
warc_time_pair_ids
shard_ids
fallback_filename_ids
status_extended_ids
mime_extended_ids
mime_detected_extended_ids
```

The same array appears in the header as `hot_column_names`.

### `record_flags`

One byte per record.

```text
bit 0: URL has explicit non-default port
bit 1: URL has query string or fragment
bit 2: filename did not match the Common Crawl filename pattern
```

The current reader does not need these flags for normal capture materialization,
but they are part of the encoded record.

### `status_and_hot_flags`

One byte per record.

```text
bits 0..5: status dictionary id, or 63 sentinel
bit 6: URL scheme is HTTPS
bit 7: redirect is present
```

If bits `0..5` are `63`, the real status dictionary ID is read from
`status_extended_ids`.

### `mime_and_flags`

One byte per record.

```text
bits 0..6: mime dictionary id, or 127 sentinel
bit 7: charset is present
```

If bits `0..6` are `127`, the real mime dictionary ID is read from
`mime_extended_ids`.

### `mime_detected_and_flags`

One byte per record.

```text
bits 0..5: mime-detected dictionary id, or 63 sentinel
bit 6: languages are present
bit 7: truncated is present
```

If bits `0..5` are `63`, the real mime-detected dictionary ID is read from
`mime_detected_extended_ids`.

### `urlkey_front_codes`

Front-coded string sequence with `record_count` strings. Values are the CDX
`urlkey` values for records in the block.

### `url_without_scheme_front_codes`

Front-coded string sequence with `record_count` strings. Values are original
URLs with the leading `http://` or `https://` removed. The scheme is restored
from `status_and_hot_flags` bit 6.

### `timestamp_deltas`

Packed unsigned integer column with `record_count` values.

Logical timestamp:

```text
timestamp_epoch = block_base_timestamp + timestamp_delta
```

Timestamps are UTC Unix seconds. The Ruby reader renders them as 14-digit CDX
timestamps with `Time.at(...).utc.strftime("%Y%m%d%H%M%S")`.

### `lengths`

Packed unsigned integer column with `record_count` nonnegative WARC record
lengths.

### `offsets`

Packed unsigned integer column with `record_count` nonnegative WARC record
offsets.

### `filename_kind`

One byte per record.

```text
0: warc
1: robotstxt
2: crawldiagnostics
3: fallback filename
```

Kinds `0..2` reconstruct a Common Crawl WARC filename from `crawl_id`,
`segment_ids`, `warc_time_pair_ids`, `filename_kind`, and `shard_ids`.

Kind `3` uses `fallback_filename_ids`.

### `segment_ids`

Packed unsigned integer column with dictionary IDs into the `segment` table.

### `warc_time_pair_ids`

Packed unsigned integer column with dictionary IDs into the `warc-time-pair`
table.

### `shard_ids`

Packed unsigned integer column with the numeric five-digit WARC shard number.
Readers render it with zero padding to five digits.

### `fallback_filename_ids`

Packed unsigned integer column with dictionary IDs into the `fallback-filename`
table. Values are meaningful only when `filename_kind == 3`.

### `status_extended_ids`

Varint sequence. Contains one dictionary ID for each record whose
`status_and_hot_flags` low six bits equal `63`, in record order.

### `mime_extended_ids`

Varint sequence. Contains one dictionary ID for each record whose
`mime_and_flags` low seven bits equal `127`, in record order.

### `mime_detected_extended_ids`

Varint sequence. Contains one dictionary ID for each record whose
`mime_detected_and_flags` low six bits equal `63`, in record order.

## Cold Columns

Cold columns are emitted in this exact order:

```text
digest
redirects
charset_ids
languages
truncated_ids
extras
```

The same array appears in the header as `cold_column_names`.

### `digest`

Exactly `record_count * 20` bytes. Each value is a decoded SHA-1 digest. A
20-byte all-zero digest means no digest was present in the source record.

The writer accepts only canonical uppercase, unpadded Base32 SHA-1 strings.
The Ruby reader renders nonzero digests the same way, using this alphabet:

```text
ABCDEFGHIJKLMNOPQRSTUVWXYZ234567
```

### `redirects`

Sparse string sequence for records whose `status_and_hot_flags` bit 7 is set.
For each such record, in record order:

```text
length: varint
bytes: byte[length]
```

### `charset_ids`

Sparse varint sequence for records whose `mime_and_flags` bit 7 is set. Each
value is a dictionary ID into the `charset` table.

### `languages`

Sparse varint-list sequence for records whose `mime_detected_and_flags` bit 6
is set. For each such record, in record order:

```text
language_count: varint
language_id: varint repeated language_count times
```

Each `language_id` is a dictionary ID into the `language` table. The Ruby reader
renders languages as comma-joined table values.

### `truncated_ids`

Sparse varint sequence for records whose `mime_detected_and_flags` bit 7 is
set. Each value is a dictionary ID into the `truncated` table.

### `extras`

Currently empty. The current writer rejects unknown CDXJ fields instead of
encoding extras.

## Filename Reconstruction

For `filename_kind` values `0`, `1`, or `2`, readers reconstruct:

```text
crawl-data/<crawl_id>/segments/<segment>/<kind>/<warc_time_pair>-<shard>.warc.gz
```

where:

```text
crawl_id       = header["crawl_id"]
segment        = segment table value
kind           = warc, robotstxt, or crawldiagnostics
warc_time_pair = warc-time-pair table value
shard          = shard_ids value formatted as five decimal digits
```

For `filename_kind == 3`, readers use the `fallback-filename` table value.

## Writer Constraints

The current writer:

```text
- reads the input twice sequentially
- accepts plain text CDXJ and gzip-compressed CDXJ
- handles concatenated gzip members
- uses block_bytes default 512 KiB
- uses max_records default 16,384
- uses restart_interval default 32
- uses zstd_level default 6
```

The first pass collects dictionaries and validates sort order. The second pass
encodes records into blocks.

The writer rejects:

```text
- unsorted urlkeys
- missing required fields
- unknown CDXJ fields
- non-http/non-https URLs
- invalid 14-digit CDX timestamps
- negative length or offset values
- non-Base32 or non-20-byte digests
- mixed crawl IDs when filenames match the Common Crawl filename pattern
```

## Reader Behavior

Readers should use the directory to find candidate blocks by `urlkey`, then
scan matching records inside those blocks. Directory lookup is only a candidate
generator; query semantics must still be checked against materialized captures.

The Ruby backend does this so packed `.rbcdx` queries remain compatible with
plain CDX/CDXJ queries for exact, prefix, host, domain, filters, sorting, and
closest-capture selection.

## Known Pressure Points

These are intentional notes for future format work.

### Writer Memory

The current Ruby writer is shard-oriented. It collects global dictionaries in
memory and accumulates the compressed `hot_blocks` and `cold_blocks` sections
before writing the final file. That is acceptable for the Common Crawl shard
sizes tested so far, but memory scales with:

```text
dictionary size + compressed hot section + compressed cold section
```

Merged crawls, unusually large fallback filename dictionaries, or much larger
future shards may require a streaming writer variant. A streaming writer would
need either reserved header space, a footer, a temporary section file, or a
two-phase rewrite of offsets.

### Future CDXJ Fields

Unknown CDXJ fields are currently rejected, and the `extras` column is empty.
This keeps the format simple and lossless for fields rbcdx understands, but it
is the most likely cause of a future format variant. If Common Crawl adds a new
field that users need, a compatible reader cannot recover it from existing
files, and a compatible writer cannot store it without assigning semantics to
`extras` or adding a new column.

### Clever Encodings

The most delicate parts of the format are:

```text
front-coded strings
packed integer columns
sparse cold-column streams
extended id streams
column offset tables
```

Readers should treat these as untrusted binary structures. They should validate
bounds, monotonic offsets, and exact stream consumption before returning values.
Writer-generated happy paths are not enough protection for corrupted or
mismatched files.

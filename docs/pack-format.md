# Pack format

[Documentation index](README.md) · [User guide](../README.md)

Pack format version 1 is an immutable binary container. A writer appends object
records to a file under `staging/`, writes a checksummed footer index, flushes to
disk, then reopens and verifies every payload before atomically moving the file
into `packs/`. Failure or cancellation removes temporary output without exposing
a committed filename.

Index entries accumulate in a delete-on-close staging sidecar and stream into the
finished pack. Sealing and payload validation traverse the index with bounded
memory. Restore and compressed reads use authoritative repository offsets and one
handle per active pack, without loading the whole object map.

## Layout

| Region | Contents |
|---|---|
| Fixed header | Magic, format version, pack UUID, creating `run_index` |
| Object header | Opaque object UUID, algorithm IDs, flags, original/stored lengths, checksum up to 32 bytes |
| Object payload | Original or compressed bytes |
| Footer index | Object UUID-to-record-offset mapping with its own SHA-256 checksum |
| Fixed trailer | Index location relative to the end of the file |

Version 1 supports integrity algorithms `none`, `xxhash64`, and `sha256`,
and compression algorithms `none` and `brotli`. `auto` is resolved before
opening the writer and is never stored as an algorithm. Each object records its
actual algorithms, allowing packs made with different defaults to coexist.

## Reuse and validation

An object UUID is a locator, not a content hash. With deduplication enabled, full
SHA-256 and original length locate candidates. Their decoded bytes must match the
stable private source copy before the worker reuses an object UUID. Verified
duplicates written earlier in the same run can also be reused.

Readers validate ranges, magic, versions, algorithm IDs, checksum lengths,
index-to-object identity, decoded lengths, decompression, and the selected object
checksum. With `none`, structural damage and length changes remain detectable,
but same-length payload modification is not guaranteed to be detected.

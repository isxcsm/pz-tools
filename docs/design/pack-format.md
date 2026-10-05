# Pack format

[Documentation index](../README.md) · [User guide](../../README.md) · [Glossary](glossary.md)

A [pack](glossary.md#pack) is a file in the backup repository's `packs/` folder that
holds the stored contents of many files, each one an [object](glossary.md#object),
usually compressed. This page describes the file layout and how packs are written, read
and checked. It is for people reading or changing the storage code. What else the
repository holds is on [repository format](repository-format.md).

## In short

- The pack format version is 1. A pack is never changed after it is written.
- A pack is written under `staging/`, checked, and only then moved into `packs/`. An
  interrupted write leaves no pack behind.
- Each object records its own checksum and compression algorithm, so packs written with
  different defaults can sit side by side.
- Packs that are mostly unused are rewritten later by
  [housekeeping](repository-housekeeping.md#pack-space-reclamation).

## Layout

| Region | Contents |
|---|---|
| Fixed header | Magic, format version, pack UUID, the `run_index` that created it |
| Object header | Opaque object UUID, algorithm IDs, flags, original and stored lengths, checksum of up to 32 bytes |
| Object payload | The original or the compressed bytes |
| Footer index | Maps each object UUID to its record offset; has its own SHA-256 checksum |
| Fixed trailer | The last 16 bytes of the file: magic and the offset where the footer index starts |

The object header and payload repeat once per object.

### Algorithms

| Kind | Supported in version 1 |
| --- | --- |
| Integrity checksum | `none`, `xxhash64`, `sha256` |
| Compression | `none`, `brotli` |

`auto` is resolved before the writer opens and is never stored as an algorithm. Each
object records the algorithms actually used.

## Limits

- With checksum `none`, structural damage and length changes are still detected, but a
  change to a payload that keeps its length is not guaranteed to be detected.
- An object UUID is a locator, not a content hash. It says where an object is, not what
  it contains.

## How it works inside

### Writing

1. The writer appends object records to a file under `staging/`.
2. Index entries collect in a staging sidecar file that is deleted when it is closed, and
   stream into the finished pack.
3. The writer adds the checksummed footer index and trailer, and flushes to disk.
4. It reopens the file and verifies every payload.
5. It moves the file into `packs/` in one atomic step.

If writing fails or is cancelled, the temporary output is removed and no committed file
name is ever exposed. Sealing the pack and validating payloads walk the index with
bounded memory.

### Reuse of stored objects

With deduplication on, full SHA-256 and the original length find candidate objects. The
candidate's decoded bytes must match the stable private copy of the source file before
the worker reuses its object UUID. Verified duplicates written earlier in the same run
can also be reused.

### Reading and validation

Restore and compressed reads use the offsets recorded in the repository, which are
authoritative, and one handle per active pack, without loading the whole object map.

Readers check:

- ranges, magic values and versions
- algorithm IDs and checksum lengths
- that each index entry matches the object it points to
- decoded lengths and decompression
- the object's checksum, for the algorithm it recorded

# Compact storage representation

[Documentation index](../README.md) · [User guide](../../README.md) · [Glossary](glossary.md)

`repository.db`, the database in the backup [repository](glossary.md#repository), stores
some fields in a compact binary form instead of as text: file identities, times, IDs and
fingerprints. This page explains those representations, what they do and do not change,
and the experiment that measured the saving. It is for people reading or changing the
storage code. The current format and schema numbers and compatibility are on
[repository format](repository-format.md); path dictionaries are on
[path handling](path-normalization.md).

## Compact representations

The compact representations were introduced with repository format 2.

| Data | Format 1 (older) | Format 2 (compact) |
| --- | --- | --- |
| Change-detection fingerprint | 32-byte SHA-256 plus the algorithm as text | First 16 bytes; algorithm implicit |
| File and parent identity | 49 UTF-8 bytes | 24 bytes: volume 64 bits and reference 128 bits, big-endian |
| Object, pack and repository GUID | 36-character text | 16 bytes in `Guid.ToByteArray()` layout |
| Entry modified and changed time | 33-character timestamp | Signed 64-bit UTC .NET ticks, 100 ns |
| Stored checksum and compression algorithm | Repeated names | Validated integer codes |

These are sizes of the field payloads, not of rows or of the database.

Notes on each change:

- **Not everything is compact.** Timestamps of workflows and revisions, which are few,
  and source checkpoint strings keep their earlier form.
- **Times.** Conversion keeps the instant and the precision. The display time-zone offset
  is not stored.
- **File identity** keeps the volume bits.
- **Fingerprint.** `content_hash_algorithm` is removed rather than repeated. Stored
  fingerprints must be exactly 16 bytes. When the optional fingerprint was not recorded,
  the first 16 bytes of a full SHA-256 integrity checksum can be used for change
  comparison instead. That is reuse of a checksum within one format, not support for an
  older fingerprint.

## Limits

- **Only the change-detection fingerprint is shortened**, and it is used only for the
  non-adversarial full-scan comparison. Checks that the source and the copy are stable
  still use full SHA-256.
- **Pack checksum widths are unchanged:** SHA-256 is 32 bytes and the default xxHash64 is
  8 bytes.
- **Deduplication** still confirms the full digest and the actual bytes.
- **No speed-up or authentication.** Shortening the fingerprint does not make SHA-256
  faster and does not authenticate data.

## Database layout

- `stored_objects` uses `WITHOUT ROWID`, so there is no separate GUID primary-key index.
  Its secondary indexes include its 16-byte primary key.
- `entry_versions` keeps its rowid, which bounded reclamation uses.
- A partial `(original_length, checksum)` index supports SHA-256 deduplication. Objects
  with the default xxHash64 checksum do not appear in it.
- File-reference lookup compares BLOB slices with a matching expression index, rather
  than casting identities to text and lowercasing hex.
- The unused index on the current parent reference is removed; the parent identity
  column stays.
- Full-scan `INSERT` commands are prepared once per session and rebound across
  transaction batches.
- The performance follow-up also reuses the object, pack and entry commit commands, and
  adds atomic file-count and byte-count summaries.
- Schema 3 replaced the repeated path strings in versions with integer references into
  immutable dictionaries of canonical keys and exact spellings; see
  [path handling](path-normalization.md).

## Measurements

The size experiment and the verification runs from when this representation was introduced
are kept in [compact storage measurements](../history/compact-repository-measurements.md).

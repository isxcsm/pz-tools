# Fingerprint branch reconciliation

[Documentation index / 문서 목차](README.md) · [User guide / 사용 안내](../README.md)

> Historical branch-reconciliation record. The recorded schema and test counts apply to the named commits; see the current repository format before opening data.

The original fingerprint-only follow-up `9894bddbab50d5be6d75f5f37482f85e5a10bd7d`
starts from dev merge `6ab613238081946b9d9fccd67d01c0719b11340f`.
The former `optimize/content-fingerprint128` head was
`668df5c966d183db5c387ef698f58ae329ae1be8` (closed PR #2). Its two unique commits
implemented an older design, not an additional product feature missing from dev.

## Disposition of PR #2

- The capture truncation, full-scan comparison and checksum fallback are already
  implemented by the merged format 2 code. Do not reapply the alternative helper
  namespace or duplicate product changes.
- Schema-12 migration SQL, dual-length readers and their migration fixtures are
  deliberately excluded. There is no legacy compatibility path.
- The old migration-specific Python check and Windows workflow changes are not
  applicable. The existing storage regression workflow also selects the
  current-format fingerprint tests.
- Useful regression intent is adapted in `ContentFingerprintTests.cs`: known
  vectors including empty input, independent output bytes, exact prefix semantics,
  strict digest/fingerprint lengths, schema CHECK rejection without mutating the
  saved fingerprint/checksum, and unchanged-to-changed full scans followed by
  restoration of both revisions. The latter exercises optional fingerprint and
  full-checksum fallback without any legacy data.

## Scope of the fingerprint-only commit

No production source, storage schema, retention policy or runtime configuration was
changed by `9894bdd`. It did not restore the retired content_hash_algorithm column.
PR #2 remains closed as superseded. The old commit ID above preserves an audit/recovery
reference for the rewrite. The 22 fingerprint cases passed in its 88-case targeted
Windows validation; the original PR records that evidence.

Run on Windows with the repository's pinned SDK:

```text
dotnet test tests/PzTools.Backup.Tests -c Release -warnaserror --filter FullyQualifiedName~ContentFingerprintTests
```

## Subsequent path work

The same branch now also implements [normalized immutable path dictionaries](path-normalization.md)
in format 2 / schema 3. That subsequent change does alter product code and the schema;
it must not be described as a tests-only PR. The 22 fingerprint cases are retained
and their internal SQL reads now use the normalized catalog. Schema 2 databases are
not migrated and need an explicit new empty backup repository. Consult the path
follow-up and current PR for newer test and compatibility evidence.

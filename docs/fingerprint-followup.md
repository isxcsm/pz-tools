# Fingerprint branch reconciliation

This follow-up starts from dev merge `6ab613238081946b9d9fccd67d01c0719b11340f`.
The former `optimize/content-fingerprint128` head was
`668df5c966d183db5c387ef698f58ae329ae1be8` (closed PR #2). Its two unique commits
implemented an older design, not an additional product feature missing from dev.

## Disposition of PR #2

- The capture truncation, full-scan comparison and checksum fallback are already
  implemented by the merged format 2 code. Do not reapply the alternative helper
  namespace or duplicate product changes.
- Schema-12 migration SQL, dual-length readers and their migration fixtures are
  deliberately excluded. Format 2 / schema 3 has no legacy compatibility path.
- The old migration-specific Python check and Windows workflow changes are not
  applicable. The existing storage regression workflow now also selects the
  current-format fingerprint tests.
- Useful regression intent is adapted in `ContentFingerprintTests.cs`: known
  vectors including empty input, independent output bytes, exact prefix semantics,
  strict digest/fingerprint lengths, schema CHECK rejection without mutating the
  saved fingerprint/checksum, and unchanged-to-changed full scans followed by
  restoration of both revisions. The latter exercises optional fingerprint and
  full-checksum fallback without any legacy data.

No production source, storage schema, retention policy or runtime configuration is
changed by this follow-up. It does not restore the retired content_hash_algorithm
column. PR #2 remains closed as superseded; the rebuilt branch is a new review.
The old commit ID above preserves an audit/recovery reference for the rewrite.

Run on Windows with the repository's pinned SDK:

```text
dotnet test tests/PzTools.Backup.Tests -c Release -warnaserror --filter FullyQualifiedName~ContentFingerprintTests
```

The new class contains 22 cases. Exact execution results and the reviewed commit
belong in the PR/CI evidence, not a pre-emptive assertion of test success here.

Current path storage uses [normalized immutable path dictionaries](path-normalization.md).
Earlier measurements and CI counts above describe their explicitly named commits.

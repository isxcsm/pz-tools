# Fingerprint branch reconciliation

[Documentation index](README.md) · [User guide](../README.md)

Historical branch-reconciliation record. Schemas and test counts below apply to the
named commits. See [repository format](repository-format.md) for the current contract.

The original fingerprint-only follow-up `9894bddbab50d5be6d75f5f37482f85e5a10bd7d`
starts from dev merge `6ab613238081946b9d9fccd67d01c0719b11340f`.
The superseded `optimize/content-fingerprint128` head was
`668df5c966d183db5c387ef698f58ae329ae1be8` (closed PR #2).

## Disposition of PR #2

- Merged format 2 code already provided capture truncation, full-scan comparison
  and checksum fallback, so the alternative product changes were not reapplied.
- Schema-12 migration SQL, dual-length readers and their migration-specific tests
  and workflow changes were excluded.
- `ContentFingerprintTests.cs` retained the useful regression coverage: known vectors,
  output independence, exact prefix/length rules, nonmutating schema rejection, and
  full scans followed by restoration using fingerprint and full-checksum fallback.

## Scope of the fingerprint-only commit

`9894bdd` changed tests only: production source, schema, retention and runtime settings
were unchanged, and the retired content_hash_algorithm column stayed removed. Its
22 fingerprint cases passed within an 88-case targeted Windows validation.

Run on Windows with the repository's pinned SDK:

```text
dotnet test tests/PzTools.Backup.Tests -c Release -warnaserror --filter FullyQualifiedName~ContentFingerprintTests
```

## Subsequent path work

The branch later added [normalized immutable path dictionaries](path-normalization.md)
in format 2 / schema 3, changing product code and schema. It retained the 22 fingerprint
cases with SQL reads adapted to the normalized catalog. The earlier tests-only result
does not describe that later change's validation scope.

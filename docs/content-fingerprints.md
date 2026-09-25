# 128-bit change-detection fingerprints

## Scope

New captures persist `content_hash_algorithm = 'Sha256_128'` and the first 16
bytes of the SHA-256 digest in `stored_objects.content_hash`. This is a storage
optimization for change detection, not a new hash algorithm and not an
integrity/authentication guarantee. The full digest is still calculated.

Pack checksums, SHA-256 deduplication candidates, byte-for-byte deduplication
confirmation, and before/copy/after stable-capture verification are unchanged.
`recordContentHash = false` still stores no optional fingerprint. Existing
32-byte `Sha256` fingerprints are compared using all 32 bytes; recognized
SHA-256 pack checksums can still supply a missing comparison baseline.
Unknown or incorrectly sized fingerprints are not accepted as a matching baseline.

A 128-bit comparison has a higher collision probability than a 256-bit comparison.
It is intended to detect non-adversarial save-file changes. This change does not
reduce the bytes read or the cost of calculating SHA-256. No throughput improvement
is claimed from truncation alone.

## Upgrade

Repository schema 12 converts existing 32-byte optional fingerprints to 16 bytes
inside the migration runner's transaction. It uses the saved digest, without
reading live saves or recompressing packs. Stored object IDs, checksums, pack
locations and entry references are preserved. Missing fingerprints remain missing.
The two leaf columns are replaced to update their CHECK constraints; the referenced
`stored_objects` table itself is not replaced. The migration's indexed temporary
table avoids a full temporary-table scan for every object.

This extends the original, schema-preserving housekeeping change described in
`repository-housekeeping.md`: the fingerprint follow-up DOES change the schema.
Use matching new app and workers. Stop the app and workers and preserve a consistent
copy of the repository before first rollout; do not downgrade an upgraded repository
to an old executable. There is no downgrade migration. A failed SQL transaction
rolls back, but the tests below do not establish behavior for every power-loss or
hardware-error scenario. A new binary's legacy-hash support is not a promise that
an old binary understands schema 12.

The hash BLOB payload shrinks by 16 bytes per populated row. The marker grows from
six ASCII bytes (`Sha256`) to ten (`Sha256_128`), so the net stored-value reduction
is 12 bytes per migrated row before record/index/page overhead. For the previously
reported 7,751 hashes, that is 124,016 bytes of hash payload or 93,012 bytes net
stored values. Those counts were supplied from another session, not measured here.
Actual file-size reduction depends on SQLite page utilization and space recovery.
It is not a 50% reduction of the entire repository database.

## Verification

The Linux editing environment has no .NET SDK or Windows runtime. It ran:

```text
python scripts/check-fingerprint-sql.py
7 tests passed (SQLite 3.46.1)
9 migration-statement interruption/rollback boundaries checked
```

These tests execute the production migration SQL against simplified isolated
SQLite fixtures, plus a matching comparison-expression fixture. They do not
replace the real production schema tests or a Windows application run.

`ContentFingerprintTests.cs` adds 17 C# test cases covering known vectors, exact
algorithm/length rules, legacy full-digest comparison, real v11-to-v12 migration,
rollback, foreign keys, and initial backup -> unchanged full scan -> same-length
changed capture -> verified restore. Existing stable-capture and incremental
regression assertions now expect 16-byte optional fingerprints while preserving
32-byte checksum assertions. The old-schema fixture resets the new migration
marker as well.

Windows CI runs the focused fingerprint/housekeeping/migration/capture/deduplication
regressions separately before the unchanged full-suite gate. A focused pass does
not authorize deployment while the full suite or published distribution checks fail.

The preceding housekeeping head `6f2023c` had a successful Windows build and
synthetic JVM job, but its full suite recorded 671 passed, 5 failed and 36 skipped
(run `36086130516`). Three failures were disk I/O errors reopening killed-process
fixtures, one was a projection-loop assertion and one a locked scheduler database
on cleanup. Their root causes are not established by this hash change; do not call
them fixed or dismiss them as environment-only failures. Check the new head's CI
results before merging or publishing. No user save or live repository was accessed.

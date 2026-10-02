# Active-only automatic backups and optimization follow-up (schema 5)

[Documentation index](../README.md) · [User guide](../../README.md)

> **Historical record.** This page describes the code and measurements at the time it was written. It is kept for reference and is not updated; for current behaviour start at the [documentation index](../README.md).

Historical record of the schema-5 follow-up to the schema-4 hotpath branch, including
documentation changes from dev `2c1133d`. Format remained 2. For current behavior,
see [configuration](../configuration.md), [repository format](../repository-format.md) and
[cleanup policy](../repository-housekeeping.md).

## Automatic backup policy and execution boundaries

The change removed final-on-exit backups: gameplay ending cleared the target and
pending reservations. Death-triggered backups required a fresh Active observation.
Retired FinalizeTarget commands cleared only their matching target, and old Final
queue entries were not dispatched. A delayed stop for world A could not clear B.

Settings changes consumed pending state commands before updating the interval or
enabled flag. They could not promote Paused/Ambiguous/Limited state using a remembered
path. Continuous tracked the active world independently of backup eligibility;
reenabling started a full interval. The countdown required a fresh, single active
SaveList world matching the target.

Activity checks guarded run allocation, launch and the worker's save/countdown wait.
Automatic calls carried `--require-active-game`, including with game saving disabled.
The probe combined a live PZ process with Windows players.db sharing; missing or unknown
activity produced Skipped without a revision. Manual calls could still capture offline
saves, and game exit did not abort capture already in progress. Finite observation
intervals left a race with game exit.

## Storage and read work

- Full-scan Added detection switched to indexed NOT EXISTS. Modified/Deleted
  comparisons, hashing and integrity checks were unchanged.
- Root lookup separated exact keys from the binary range [root+'/', root+'0'),
  preserving uppercase keys, segment boundaries, literal '%'/'_' and overlapping roots
  without another permanent path index.
- Thumbnail reads shared PNG bytes by (RepositoryId,ObjectId) in a bounded cache after
  resolving the active revision. Cold reads serialized; deleted revisions stayed hidden.
- Restore completed path preflight before copying in pack/offset order, with at most
  one open pack reader. Payload checks, durable writes, cancellation cleanup and final
  directory metadata were retained.
- Entry-version GC budgeted inspected rows, including ineligible rows, using resumable
  `entry_gc_cursors` per global/source scope. This avoided a wide source/rowid index at
  the cost of more passes in multi-source repositories. Retained revisions and the
  hidden latest baseline protected entries; eligibility, deletion and cursor updates
  shared one immediate transaction. Wrapping revisited freed or reused rowids.
  This row budget did not bound object GC, VACUUM or total maintenance time.

## Validation scope

`AutomaticBackupRegressionTests` covered state transitions and execution-time guards;
the published-runner fixture checked offline automatic skipping with saving disabled.
`OptimizationFollowupTests` covered scan plans, thumbnail visibility, bounded restore
readers and version-GC cursor recovery, budgets and source isolation.

Local production SQL checks passed. Windows and published-worker results were tracked
in PR #6; this document records no final counts or real-game validation.

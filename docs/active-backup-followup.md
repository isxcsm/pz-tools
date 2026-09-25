# Active-only automatic backups and optimization follow-up (schema 5)

[Documentation index / 문서 목차](README.md) · [User guide / 사용 안내](../README.md)

This follows the schema-4 hotpath branch and incorporates the documentation-only
changes from dev `2c1133d`. Repository format remains 2; schema is now 5. No migration,
dual-format reader or automatic reset is provided. Use a new empty backup repository
and matching app/workers; never reset the game's `Zomboid/Saves` directory.

## Automatic backup policy and execution boundaries

Gameplay ending clears the target and pending reservations; it no longer schedules
a final backup. Death-triggered backups require a successful current Active activity
observation, not merely a late character result after the world closes. Retired
FinalizeTarget commands are treated as clearing only their matching target, and old
Final queue entries are not dispatched. A delayed stop for world A cannot clear B.

Changing interval/enabled settings first consumes pending state commands. It does
not turn Paused/Ambiguous/Limited state into Continuous based on a remembered path.
Continuous records an active world even while automatic backups are disabled; the
separate enabled flag controls eligibility. Enabling again starts a full interval.
The app's countdown also requires a fresh, single active SaveList world matching
the target. Changing settings alone is not evidence that a game is running.

The scheduler checks active gameplay before allocating a run, then rechecks both
activity and reservation identity immediately before launch. Automatic runner calls
carry `--require-active-game`; the worker checks before game-save preparation and
after any save/countdown wait, including when in-game saving is disabled. The probe
requires a live Project Zomboid process and the existing Windows players.db sharing
signal. Missing/Unknown activity fails closed for automatic runs. The worker reports
an obsolete automatic request as Skipped without committing a backup revision.
Manual/direct calls without that flag can still back up offline saves. An already
capturing backup is not aborted solely because the game then exits. Process probing
and the state pipeline have finite observation intervals; this is not a claim of
atomic synchronization with the game's lifetime.

## Storage and read work

* Full-scan Added detection uses indexed NOT EXISTS rather than repeatedly joining
  a derived current catalog. Modified/Deleted comparisons retain their semantics.
  Tests exercise actual scans, Unicode/case changes and query plans before/after
  ANALYZE. No integrity check or hashing is disabled to obtain this improvement.
* Root lookup separates exact keys from the binary range [root+'/', root+'0'). The
  canonical .NET uppercase keys, segment boundaries, literal '%'/'_' and overlapping
  root multiplicity remain unchanged. No new permanent path index is required.
* Revision thumbnail requests still resolve the requested active revision, then share
  PNG bytes by (RepositoryId,ObjectId) in the existing bounded cache. Cold revision
  reads serialize to avoid duplicate reads; no long-lived UI pack handle or unbounded
  alias map is added. Deleted revisions are not served from cached content.
* Restore performs the complete path preflight first, creates directories, and copies
  files in pack/offset order. It releases one reader before opening the next, bounding
  concurrent readers at one rather than at the number of referenced packs. Payload
  checks, durable per-file writes, cancellation cleanup and final directory metadata
  are retained. Progress order is now pack order, not path order.
* Entry-version collection now limits inspected physical version rows, not only
  successful deletions. Each global/source scope keeps a resumable rowid cursor in
  entry_gc_cursors. Open versions and versions of other sources consume inspection
  budget without becoming eligible. This avoids an extra wide source/rowid index but
  can need more passes in a multi-source repository. Eligibility is checked against
  every retained revision and the hidden latest baseline, inside the same immediate
  transaction as deletion and cursor update. Cursor wrap revisits older newly-freed
  entries and rowids renumbered/reused by SQLite; IDs are not treated as proof of
  liveness. Whole maintenance work, object GC and VACUUM are not time-bounded by this
  row budget.

## Validation scope

New AutomaticBackupRegressionTests exercise actual reactor/outbox/scheduler transitions,
settings while stop commands wait, inactive/death/ambiguous states, delayed commands,
fresh-view countdown gating and two execution-time guards. A published-runner fixture
checks offline automatic skipping with game saving disabled; the existing scheduled
manual-offline backup/restore fixture remains required.

OptimizationFollowupTests exercise actual scan/query results and plans, historical
thumbnail sharing plus deleted revisions, real multi-pack restoration with a reader
count guard, cancellation, version cursor reopening/wrapping/budgets, source isolation,
rollback and schema-4 rejection. Existing tests are updated for intentional removal
of final-on-exit backups and inspection (rather than deletion) batch semantics.

The production SQL housekeeping/path checks pass locally. Record the actual final
Windows build, targeted/full tests and published-worker results in PR #6; source
review and Python checks are not Windows, UI or real-game execution evidence. No user
repository, game save or installed application is accessed by these fixtures.

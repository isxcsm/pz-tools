# Advanced runtime configuration

[Documentation index](README.md) · [User guide](../README.md)

Operational tuning is read at the owning process boundary and passed to the
implementation. Libraries do not repeatedly read TOML during a scan or copy.
Code defaults remain as fallbacks for omitted keys and direct library callers;
they do not override an explicitly configured value. App-owned preferences and
explicit CLI flags keep their existing precedence over TOML defaults.

| Editable file | Operational settings |
| --- | --- |
| `app/default.toml` | Projection frequency, telemetry catch-up/read grace/stale threshold, card lifetime, thumbnail budget/parallelism, explicit refresh retries/timeouts, scheduler restart/backoff, shutdown grace, settings/filter debounce, active-operation progress frequency (legacy key: `export_progress_interval_ms`) |
| `backup-worker/default.toml` | Unstable-file attempts/backoff, copy/hash buffer, bounded small-file staging pool, capture reader/queue limits, full-scan hash batch/reader limits, progress frequency, scan/USN batches, backup heartbeat, JVM connection/queue/completion timeouts |
| `backup-scheduler/default.toml` | Due-work polling frequency (not the user's backup interval) |
| `state-scheduler/default.toml` | State collection, wake polling, independent confirmation delay, interrupted/orphan cleanup interval |
| `maintenance-worker/default.toml` | Deleted-revision reclamation batch and writer-contention retry delay (not retention policy) |
| `archive-worker/default.toml` | Existing archive safeguards, character/thumbnail preview budgets, progress/heartbeat frequency |
| `restore-worker/default.toml`, `character-recovery/default.toml` | Diagnostic retention, progress/heartbeat frequency |

The templates document units, accepted ranges and consequences in English.
Invalid operational ranges fail configuration validation; they do not disable
consistency checks or turn bounded waits into infinite waits. The app keeps the
settings-repair UI available when its runtime file is invalid, but does not start
workers with rejected configuration. Editing a file never changes an operation
already in progress. Use **Apply settings and restart** for a consistent reload.

Save queue timeout is distinct from completion timeout: only a still-queued call
can be cancelled safely. An already-running game save is not interrupted and an
unknown completion does not permit capture or automatic retry. The extended bridge
protocol transports configured deadlines to the JVM. Compatible payload updates
reload at an idle boundary; an incompatible resident bootstrap requires a game
restart. See [component reload](module-reload.md) for that distinction.

## Intentionally not editable

- Binary formats, schema versions, field sizes/offsets, OS/API constants and
  enum/status codes describe data contracts, not preferences.
- Authentication sizes, allowed commands, parser/manifest hard limits, path
  validation, lock ordering, database integrity pragmas and atomic-write ordering
  are safety boundaries, not switches to bypass validation.
- Low-level OS/SQLite transport buffers, socket handshake guards, private bounded
  diagnostic buffers and internal synchronization checks remain implementation
  details. The supported workload/copy budgets and user-facing timeouts above are
  the tuning interface, not every allocation or lock-wait primitive.
- Animation geometry/durations, responsive breakpoints and layout dimensions
  remain part of the UI design; data refresh and I/O concurrency are configurable.
- Game-format recovery targets and two-independent-observation confirmation are
  correctness rules. Recovery does not erase negative traits.
- Benchmark data sizes, seeds and synthetic test timeouts are test inputs.

No startup migration rewrites existing editable files. New installations and the
explicit reset action use the checked-in templates. Existing installations use
fallbacks for omitted settings until those keys are explicitly added.

## Shared validation and derived display data

Worker option readers in `ComponentOptions` are shared by preflight validation and
worker startup. Apply-and-restart checks every installed component's section names,
key names, value types and ranges before stopping the current host. Telemetry limits
of zero keep their documented unlimited meaning. App and backup options retain
their dedicated schemas; no runtime code rewrites existing TOML files.

`app/runtime.character_metadata_batch_size` bounds background attempts to fill
missing backup character summaries, including failed reads. The retry interval is
`character_metadata_retry_seconds`. New backups collect the summary from their
captured `players.db`; the current schema stores survival duration and an explicit completion
flag, so an unavailable duration is not confused with pending work. The collector
also handles interrupted metadata collection. It reads packs outside the writer
lease, retains completed reads across writer contention, and advances past failures.
It also stores the last character-summary read error. A failed read
is displayed as unavailable with a retry notice, not as an indefinitely running
progress indicator. Successful retries clear the error. Display projectors never
modify the repository or extract revision files.

Live character snapshots are cached by file version in the background state
projector, not read from UI callbacks. Revision thumbnails follow realized list rows;
recycled rows and save switches cancel their pending reads. Bitmap creation remains
on the UI thread, while pack and database reads run in the background.

## Process contracts and disposable operation telemetry

All process boundaries use `ProcessResultValidator`: required envelope fields,
component identity, run index, and exit status must agree. Missing output is never
treated as success. App-side protocol failures retain stderr in the durable log
inbox, separately from the machine-readable error code. Managed child processes
share one Job Object implementation and one teardown path.

Archive, restore, and character-recovery telemetry is disposable after the worker
has stopped and every available event has been imported into `logs.db`. A session
activity lock prevents premature retirement, including during historical replay.
Cleanup removes only known telemetry files and empty directories under the owned
operations root; unknown files and reparse points are preserved. The central log
retention settings continue to control the imported diagnostics. This is ongoing
lifecycle management, not a one-off migration or a TOML rewrite.

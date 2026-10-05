# Telemetry

[Documentation index](../README.md)

[Telemetry](glossary.md#telemetry) is what each PZ Tools process records about its own work: when a run started and
ended, its progress, and why it failed. The app reads it to draw progress cards and to fill the Logs page. It is
kept apart from backup data. A telemetry failure never changes a revision, a repository transaction or a worker's
exit code, and nothing that decides whether a backup exists reads it. Run indexes come from `control.db`
([process architecture](process-architecture.md#databases)); telemetry never allocates an identifier that other data
depends on.

## Stores

There are two kinds of telemetry database, and every producer owns its own file.

| Store | Code | Schema | Event identity |
| --- | --- | --- | --- |
| Backup engine: `telemetry.db` in the backup folder | [`TelemetryStore`](../../src/PzTools.Backup.Storage/Telemetry/TelemetryStore.cs) | Format 1, schema 2 | `(run_index, sequence)`; runs in `telemetry_runs`, events in `telemetry_events` |
| Process telemetry: one per component | [`ProcessTelemetryStore`](../../src/PzTools.Process.Telemetry/ProcessTelemetryStore.cs) | Schema 3 (1 and 2 are migrated) | `(scope_id, run_index, component, event_sequence)` |

Both refuse a newer schema. An event has a name, a UTC time, elapsed ticks, a payload version and an optional
JSON payload. Elapsed ticks mean different things in the two stores: time since the backup session started in
the engine store, a Stopwatch delta since the store object was created in process telemetry. Neither is a clock to
compare across processes.

A process telemetry database lives beside the identity it belongs to
([`ComponentRuntimePaths.GetComponentDirectory`](../../src/PzTools.Process.Contracts/ComponentConfiguration.cs)):

| Identity | Database |
| --- | --- |
| A folder | `<folder>\.pztools\<component>\telemetry.db` |
| A file, or any path ending in `.db` | `<parent>\.pztools\<file name>\<component>\telemetry.db` |

An operation worker (restore, archive, character recovery, profiler) holds a `telemetry.active` file open next to
its database while it runs; the app uses it to tell a running operation from a dead one. Schedulers, runners,
state checks and maintenance lanes have none.

| Producers | Identity |
| --- | --- |
| `backup-scheduler`, `state-scheduler` | `scheduler.db` |
| `state-runner`, `state-collector`, `state-reactor` | `state.db` |
| `backup-runner`, `maintenance-runner`, `maintenance-worker`, `maintenance-lane-<lane>`, `backup-worker` | The backup folder |
| `restore-worker`, `archive-worker`, `character-recovery`, `profiler` | `%LOCALAPPDATA%\PzTools\operations\<component>\<operation key>`, passed as `--telemetry-identity` |

The backup worker's process database holds only its `backup.completed` event, written whenever `enabled` is
true, also in `off` mode. The app never registers it as a source, so nothing reads it. The `backup-runner` and
`maintenance-runner` events go to the log only; they never make a card. `state-runner` events can. An operation's database is deleted once its events
are in `logs.db` and its card has gone. Any left over at start-up are imported into `logs.db` and then deleted
([`AppHost.RegisterHistoricalOperationTelemetrySourcesAsync`](../../src/PzTools.App.Core/AppHost.cs)).

## What the backup engine records

The `[telemetry]` section of the `backup-worker` component chooses how much
([`BackupConfiguration`](../../src/PzTools.Backup.Core/Configuration/BackupConfiguration.cs)):

| `mode` | Recorded scopes |
| --- | --- |
| `off` | Nothing in the engine store; it is not opened |
| `run` | `Run` events |
| `phase` | `Run` and `Phase` events |
| `raw` | Everything |

| Key | Default | Range |
| --- | --- | --- |
| `enabled` | `true` | |
| `mode` | `phase` | `off`, `run`, `phase`, `raw` |
| `batch_size` | 256 | 1–4096 |
| `flush_interval_ms` | 250 | 10–10000 |
| `retain_runs` | 100 | 0 or more; 0 means no limit |
| `max_database_mib` | 64 | 0 or more; 0 means no limit |

The template ([`config/defaults/backup-worker/default.toml`](../../config/defaults/backup-worker/default.toml)) is
what the app writes; a key left out of the file takes the same value as the template. Process telemetry reads
`enabled` (true), `retain_runs` (100), `max_database_mib` (64), `progress_flush_interval_ms` (100) and
`heartbeat_interval_ms` (5000) from each component's own `[telemetry]` section
([`TelemetryRuntimeOptions`](../../src/PzTools.Process.Contracts/ComponentOptions.cs)). The keys are listed in
[advanced settings](../reference/advanced-settings.md).

### Trimming

A limit of 0 turns that limit off. The size limit is the logical size, `page_size × (page_count − freelist_count)`,
not the file size; the file does not shrink.

- Backup engine: after each backup, finished runs beyond `retain_runs` are deleted, then the oldest finished runs
  until the logical size fits. A running run is never deleted.
- Process telemetry: per component, by run count, then by size, always keeping at least one run. A best-effort write
  trims at most once a minute per database; a session trims when it ends.

## Writing

**Backup engine** ([`TelemetryRunSession`](../../src/PzTools.Backup.Storage/Telemetry/TelemetryRunSession.cs)).
Events go through a bounded channel of `max(2 × batch_size, 16)`; a full channel makes the emitter wait. A batch is
written in one transaction when it is full or when its flush deadline passes. The deadline starts at the batch's
first event and does not move as more arrive. Batching groups events into transactions; it does not sample or
aggregate them.

If a write fails with a SQLite, I/O or access error, telemetry stops for the rest of that backup and the result
carries the warning `telemetry_unavailable`. A failed trim gives `telemetry_trim_failed`. A crash loses the batch not
yet committed.

After taking the [writer lock](glossary.md#writer-lock), every backup reconciles the engine's runs with the
repository's `worker_runs` and then marks any run still `Running` as `Abandoned` with `process-interrupted`
([`RepositoryRecoveryService`](../../src/PzTools.Backup.Engine/RepositoryRecoveryService.cs)). Nothing that only
reads telemetry does this.

**Process telemetry** ([`ProcessTelemetrySession`](../../src/PzTools.Process.Telemetry/ProcessTelemetrySession.cs)).
Events are queued and written by a timer every `progress_flush_interval_ms` (100 ms), one transaction per tick. A
failed write is retried on the next tick. Once stopping, the session gives up when three writes in a row have
failed, counting failures from before the stop. Producers that record single events (schedulers, runners,
state checks, maintenance dispatch and lanes) use
[`BestEffortProcessTelemetry.TryRecordAsync`](../../src/PzTools.Process.Telemetry/ProcessTelemetryStore.cs), which
writes one event and swallows any failure. Process databases use `synchronous=NORMAL`, so a power loss can lose the
last events.

## Progress and liveness

| Signal | Emitted by | Interval |
| --- | --- | --- |
| `operation.heartbeat` (scope `Run`) | Backup worker | `heartbeat_interval_ms` in `[runtime]`, 2000 ms |
| `operation.heartbeat` | Restore, archive, character recovery, profiler | `heartbeat_interval_ms` in `[telemetry]`, 5000 ms |
| `operation.heartbeat` | Maintenance lanes: `ArtifactCleanup` from its start, the others once they know they have work | 3 s |
| `progress.snapshot` | Process workers | At most every `progress_flush_interval_ms` (100 ms), only after new progress |
| Scan, hash and capture progress (scope `Phase`) | Backup worker | `progress_interval_ms` in `[runtime]`, 250 ms |

A heartbeat is emitted only while work runs. A card turns stale when no event has arrived for
`telemetry_stale_seconds` (10 s) and only while its workflow is `Running`; an idle or finished producer is never
stale. Backup progress is not recorded in `run` mode, and nothing is in `off` mode.

A process worker keeps only the latest progress sample between ticks. When the phase changes, the old phase's
last sample is queued first. A terminal event (`run.committed`, `run.failed`, `run.busy`, `run.cancelled`,
`run.unavailable`) queues the latest sample before itself, so the order holds. Retries merge adjacent samples of
the same phase. Readers compute percentages from the cumulative completed and total counts; a total written as
JSON `null` means unknown, and scan progress has none.

Deleting a save runs inside the app and has no telemetry database. It reports into a latest-value slot
([`LatestProgress`](../../src/PzTools.App.Core/LatestProgress.cs)) that a UI timer reads every
`export_progress_interval_ms` (350 ms); the result comes from the awaited task. `SaveDeletionService` throttles
its own reports with the built-in 350 ms, not the configured value. While files are listed it shows a
count; a percentage appears once the total is known.

### Matching events to cards

[`OperationCoordinator`](../../src/PzTools.App.Core/OperationCoordinator.cs) gives every operation started from the
UI an `OperationId` (`manual-backup:<guid>`, `restore:<guid>` and so on) before it takes its in-app gates, and
registers the telemetry source with that workflow and its run index. Events carry no operation id; the projection
binds them to the source's current workflow by run index
([`TelemetryProjection`](../../src/PzTools.Projections/TelemetryProjection.cs)). A card of the current workflow
shows the workflow's own status, and a finished card keeps the result the app saw: a late running event cannot
reopen it ([`OperationCardStack`](../../src/PzTools.App.Core/OperationCardStack.cs)).

## Reading

The app's projection loop reads every source each `projection_interval_ms` (1000 ms), at most
`telemetry_pages_per_refresh` (8) × 512 events per source per pass. It keeps one read-only connection per source
and skips a source whose `PRAGMA data_version` has not changed.

- `telemetry_read_timeout_seconds` (1, range 1–5) sets the SQLite provider's `DefaultTimeout`. The provider retries
  `BUSY` by itself for 30 seconds by default, and one locked database would otherwise stall every card.
- Before a source's first successful read, missing metadata and SQLite errors 1, 5 and 6 are treated as a database
  still being created, for `telemetry_read_grace_ms` (2000 ms). The source shows as waiting. A missing file
  waits until `telemetry_stale_seconds` have passed since its workflow started, then shows as stale.
- A schema other than 2 (engine) or 3 (process) marks the source `UnsupportedSchema` at once, grace or not.
  After the grace, SQLite, I/O, access or bad-data errors (including invalid JSON) mark it `Unreadable`. Only that source is affected. The change is logged as
  `telemetry.source.unreadable`, `.unsupportedschema`, `.stale` or `.recovered`.
- A changed instance id, or event ids outside the cursor's range, reset that source's cursor.

## The Logs page's data

The projection copies events into `logs.db` in the data folder
([`LogInboxStore`](../../src/PzTools.Projections/LogInboxStore.cs)). Each entry has one of five levels: Trace,
Information, Warning, Error, Critical. Rules, in order
([`TelemetryProjection.ClassifyLogLevel`](../../src/PzTools.Projections/TelemetryProjection.cs)):

| Event | Level |
| --- | --- |
| `operation.heartbeat`, `progress.snapshot`, `workload.discovered`, `file.*.completed` | Not logged |
| `maintenance.*.started` | Information when `planned`, else Trace |
| `maintenance.*.cancelled`, `maintenance.recovery.completed` | Information |
| `run.cancelled` with `failureCode` `source-deferred` or `source-skipped` | Information: an automatic backup put off during preparation, retried by itself |
| `source.prepare.completed` with outcome `save-unavailable` | Warning: the backup ran without the game's own save |
| Name contains `critical` | Critical |
| Name ends `.failed` or contains `error` | Error |
| Name ends `.busy` or `.unavailable` | Information: the work did not start |
| Name contains `warning`, or ends `.degraded` or `.cancelled` | Warning |
| Other `*.started` except `run.started` | Trace |
| Outcome completions (`tick`, `collector`, `reactor`, `state-runner`, `runner`, `backup`, `maintenance.*`) | `Failed`, `Abandoned` → Error; `Busy`, `Degraded`, `Cancelled`, unknown → Warning; a state-scheduler `tick.completed` that was `Busy` and not started → Trace; maintenance with work done (`planned`, or `affectedItems` above 0) → Information; no readable outcome → Information for `tick.completed`, Trace for the rest; else Trace |
| Anything else | Information |

What these rules give in practice:

| Events | Level |
| --- | --- |
| Routine successful checks: `tick.completed`, `collector.completed`, `reactor.completed`, `state-runner.completed`, `runner.completed` | Trace |
| Background cleanup that found nothing to do | Trace |
| Background cleanup with work: an announced start (`planned`), its completion, a completion that affected items, a postponement (`.cancelled`) | Information |
| Backup and operation results: `run.started`, `run.committed` | Information |
| Work that did not start: `run.busy`, `run.unavailable` (only the profiler sends it, when there is no single game or the game needs a restart) | Information |
| An automatic backup put off during preparation: `run.cancelled` with `source-deferred` or `source-skipped` | Information |
| Busy, degraded, cancelled and unknown outcomes | Warning |
| Failures (`*.failed`, `Failed` or `Abandoned` outcomes) | Error |

With the default `record_minimum_level` (Information), Trace entries are not stored.

A numeric `outcome` is read in `ProcessOutcome` order. A record without `outcome` but with a numeric `status`
(written by old versions) is read as `RunStatus`. Entries already stored are not reclassified when these rules
change.

Every entry at Warning or above belongs to an incident (`run:<run index>`, or `source:<source>:<event>` without one)
that the player acknowledges on the Logs page.

`[logs]` in the app's `default.toml` sets storage: `record_minimum_level` (Information) and `max_entries` (100000,
range 10000–500000). The level is applied both when projecting and when appending, and the oldest entries go first.
These settings do not change how long raw telemetry is kept. The Logs page's own filters live in the page and are
not saved.

The app writes three kinds of entries itself, with no worker telemetry behind them:

- `run.failed` from source `app-dispatch` when a worker could not be started (`phase` `process-launch`, with the
  executable path and `nativeErrorCode`) or returned an invalid result envelope (`phase` `process-result`).
- `app.action.failed` for an action that ran no worker, such as a rename or a refused setting
  ([`AppHost.RecordActionIssue`](../../src/PzTools.App.Core/AppHost.cs)). It keeps the title and message the card
  showed. An issue that was not a failure is written under the same name at Warning with outcome `Degraded`.
- `component.launch.blocked` from source `app-dispatch` and component `app`, written by the periodic launch
  check ([process architecture](process-architecture.md#the-processes)) when the set of blocked components
  changes.

Maintenance lanes that fail to delete files record `failureCode` `file-delete-failed`, the count and up to eight
file names.

## Failure payloads

[`FailureTelemetry.FromException`](../../src/PzTools.Process.Contracts/FailureTelemetry.cs) builds the payload of
failure events that come from an exception. A few are written inline instead: the app's `process-launch`
entries, `runner.completed` and the lanes' `file-delete-failed` completions.

- Always: `failureCode`, `exceptionType`, `message`, `hResult` (`0x` + 8 hex digits).
- `nativeErrorCode` for a `Win32Exception`. Its `hResult` is always `0x80004005`; the native number (5 for access
  denied) is what says why.
- When given: `status`, `phase`, `path`, `reason`, `operation`, `saveId`, and one level of inner exception.
- `diagnostics`, up to 6144 characters, when the exception implements
  [`IFailureDiagnostics`](../../src/PzTools.Process.Contracts/IFailureDiagnostics.cs) (game-save and backup
  preparation failures).

Every other text field except the code and type is flattened to one line and cut to its first 512 characters
plus `…`. A caller may pass a path prefix to replace with `<save>`; only the backup worker does, with the save's root.
Other producers, and the app's `process-launch` entries, keep full paths.

For a failed game save or a deferred preparation, the backup worker's own event has the detail. Schedulers and
runners above it record only the child's code, linked by the same run index.

### How the Logs page explains a failure

The failure details are explained in the app's language
([`UserFacingErrorCatalog.FromDiagnostics`](../../src/PzTools.App.Core/UserFacingErrorCatalog.cs)). The first
match wins:

1. A profiler failure code.
2. A known failure code.
3. A known code at the start of `message`, a message logged by 0.1.0, or the English phrases "access is denied",
   "unauthorized", or "not found"/"does not exist" with a file word.
4. The exception type.
5. `nativeErrorCode`, or the Windows error inside an `hResult` of the form `0x8007xxxx`.

A known worker `reason` is shown translated. A reason or message that nothing explains is shown word for word as
**Original message** in the technical details, because Windows writes some messages in its own language.

An `app.action.failed` entry shows the title and message the card showed. If that text is a whole string of any of
the app's languages, the page shows it in the current language. The lookup table (every string of every
language, about a second to build) is built in the background at launch
([`Localizer.Warm`](../../src/PzTools.App/Localizer.cs)). The app does not set
`ApplicationLanguages.PrimaryLanguageOverride`: with it set, every resource lookup answers in that one language
whatever language it asks for, and the table could not be built.

## Crash reports

A crash of the app itself goes to a plain text file, not to telemetry or `logs.db`, because the log database may be
what failed.

| Hook ([`App.xaml.cs`](../../src/PzTools.App/App.xaml.cs)) | `Origin` in the report |
| --- | --- |
| `Application.UnhandledException` | `ui-thread` |
| `AppDomain.CurrentDomain.UnhandledException` | `background-thread` |

`ReportFatal` runs once per process. It calls
[`CrashReport.TryWrite`](../../src/PzTools.App.Core/CrashReport.cs), which writes
`crash-<yyyyMMdd-HHmmss-fff>.txt` (UTC) to `%LOCALAPPDATA%\PzTools\crash`, or `%TEMP%\PzTools\crash` if the data
folder cannot be found. The file holds the app version, time, origin, Windows version and the full exception. The
newest 20 reports are kept. `TryWrite` never throws. The app then shows a native message box, which works before
the window exists and while XAML is failing, with `FatalErrorMessageFormat` and the report path. The handler does
not mark the exception handled, so the process ends.

WinUI does not raise `Application.UnhandledException` for an exception thrown in a `DispatcherQueue` callback or a
`DispatcherQueueTimer` tick; the process ends with no report. [`UiQueue`](../../src/PzTools.App/UiQueue.cs) wraps
both and rethrows a failure through the UI thread's `SynchronizationContext`, where the handler sees it. The app
queues UI work only through `UiQueue.Enqueue` and `UiQueue.Timer`; a test keeps direct `TryEnqueue` and
`CreateTimer` calls out of the app.

Crashes of workers and schedulers need no report file: the parent reads their exit code and error output, and the
app supervises the schedulers ([process architecture](process-architecture.md#starting-supervising-and-stopping)).

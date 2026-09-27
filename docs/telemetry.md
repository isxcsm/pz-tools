# Telemetry

[Documentation index](README.md) · [User guide](../README.md)

Telemetry records diagnostic events independently of backup data. Producers emit
events; readers derive progress, logs, and metrics. Telemetry failure must not
change a successful revision, repository transaction, or operation exit code.

## Stores and identities

| Store | Format/schema | Event identity |
|---|---|---|
| Repository-root `telemetry.db` | Format 1, schema 2 | `(run_index, sequence)` |
| Per-producer process `telemetry.db` | Schema 3 | `(scope_id, run_index, component, event_sequence)` |

The installation's `control.db` allocates run indices; telemetry never allocates
authoritative identifiers. Events include a version, name, UTC timestamp,
monotonic elapsed ticks, and optional JSON payload.

Each process writes its own database. Directory identities use
`<identity>/.pztools/<component>/telemetry.db`; database-file identities use
`<parent>/.pztools/<database-name>/<component>/telemetry.db`. Producers do not
share schema ownership or trimming responsibilities.

## Recording and retention

Backup-engine modes select recorded event scopes:

| Mode | Recorded scopes |
|---|---|
| `off` | No detailed engine runs or events |
| `run` | Run events |
| `phase` | Run and phase events |
| `raw` | All emitted events |

The generated backup-worker template uses `phase`, batches of 256, a 250 ms
flush interval, 100 retained runs, and a 64 MiB logical-size threshold.
Process telemetry normally uses `enabled = true`, 100 runs, and 64 MiB.
A zero retention/size limit disables that limit. These settings are independent
of revision retention and do not cap the physical SQLite file size.

The backup event writer uses a bounded channel with backpressure. Batch size and
flush interval control transactions, not sampling or aggregation. The deadline
starts at the first event in a batch and does not slide as more events arrive.
A crash can lose the last uncommitted batch.

SQLite errors disable the affected backup telemetry session and become result
warnings. Recording and trimming process telemetry are also best-effort.
After acquiring the repository writer lease, a one-shot backup may mark previous
running telemetry rows abandoned; read-only consumers do not perform recovery.

## Progress and liveness

Long-running backup, restore, and archive operations emit `operation.heartbeat`
only while working. Heartbeat timeout marks a workflow stale only while it is
`Running`; idle producers and completed operations are not failures.

Restore and archive progress callbacks replace the latest cumulative sample.
A background writer normally records `progress.snapshot` about every 100 ms.
A phase boundary queues the previous phase's final sample first. Start, completion,
failure, cancellation, and busy events preserve order and are flushed before exit.
Retries coalesce adjacent progress samples within a phase without losing these
boundaries. Readers calculate percentages from cumulative completed/total values.

Backup scan, hash, and capture phases also report progress, sampled before
serialization. Scan remains indeterminate until the total is known; hash progress
counts completed files and bytes. Events use the existing bounded queue and batches.

App-local save deletion uses a latest-value slot instead of a worker telemetry
database. The UI timer consumes the newest sample; completion/failure comes from
the operation task. Enumeration reports discovered counts, and percentages appear
only after the total is established.

UI-started operations carry `operation_id` from admission onward. Projection
matches that identifier instead of guessing from operation kind and run number,
and a terminal state takes precedence over a late running update.

## App logs and failure details

The app projects producer events into `logs.db` at Trace, Information, Warning,
Error, or Critical level. File-completion, progress, heartbeat, and workload-discovery
events inform progress/metrics but are omitted from the ordinary log list.

Storage policy comes from `config/app/default.toml` under `[logs]`; display
filters come from `settings.toml`. Neither changes raw telemetry retention.

Failure payloads include `failureCode`, `exceptionType`, `message`, and
`hResult`, plus known phase, relative path, save ID, reason, and inner exception
details. Short diagnostic strings are flattened and capped at 512 characters;
absolute source paths are masked. `IFailureDiagnostics` may add a
`diagnostics` field up to 6,144 characters with truncation marked, using the same
path masking and newline normalization.

For game-save failures or deferred preparation, inspect the original
`backup-worker` event: it retains detailed diagnostics, including
`run.cancelled` with `code=source-deferred`. Parent runners/schedulers carry
the child error code, while the source producer owns detailed file information.
Events and envelopes correlate through the same run index.

Cancellation is a warning and failure is an error. A `.completed` event with
`Failed` or `Degraded` outcome is still shown as error or warning; busy,
cancelled, degraded, and failed outcomes are never displayed as success.
A duplicate state-scheduler check (`Busy`, `Started=false`) is Trace, without
hiding rejected user backups or real failures. Numeric `outcome` uses
`ProcessOutcome`; legacy numeric backup `status` uses `RunStatus`.
Existing stored logs are not rewritten.

The app also reads independent maintenance-lane telemetry. Partial file-cleanup
failures include a count and up to eight filenames.

## Read failures

`telemetry_read_timeout_seconds` defaults to one second and bounds both SQLite
busy waiting and provider retries. Setting only `PRAGMA busy_timeout` would not
bound the provider's default retry window.

An initial database without tables or metadata receives the initialization grace
period. Missing metadata after a successful read, or failure beyond that grace,
is an error. Invalid JSON, dates, and instance IDs are isolated to their source so
other producers continue updating. Read errors retain the database path, stage,
exception message, and inner exception for diagnosis.

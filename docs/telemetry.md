# Telemetry

[Documentation index](README.md) · [User guide](../README.md) · [Glossary](glossary.md)

[Telemetry](glossary.md#telemetry) is the diagnostic record each PZ Tools process keeps
while it works: when a job started and finished, how far it has got, and what went
wrong. The app reads it to draw progress cards, fill the Logs screen and show timings.
This page is for people reading the code or digging into a failure. It explains where
the records are stored, what is recorded, how the app turns them into progress and
logs, and what to look at when something failed.

Telemetry is kept apart from backup data. Processes that do work (producers) write
events; readers derive progress, logs and metrics from them. A telemetry failure never
changes a successful revision, a repository transaction or an operation's exit code.

## Where it is stored

| Store | Format/schema | Event identity |
| --- | --- | --- |
| Repository-root `telemetry.db` | Format 1, schema 2 | `(run_index, sequence)` |
| Per-producer process `telemetry.db` | Schema 3 | `(scope_id, run_index, component, event_sequence)` |

Each process writes its own database, and producers do not share schema ownership or
trimming. The database's location depends on what the producer's identity is:

| Identity | Database path |
| --- | --- |
| A directory | `<identity>/.pztools/<component>/telemetry.db` |
| A database file | `<parent>/.pztools/<database-name>/<component>/telemetry.db` |

Every event has a version, a name, a UTC timestamp, monotonic elapsed ticks and an
optional JSON payload. The installation's `control.db` hands out the
[run index](glossary.md#run-index); telemetry never allocates identifiers that other
data depends on.

## What is recorded

The backup engine's `mode` setting chooses how much it records:

| Mode | Recorded scopes |
| --- | --- |
| `off` | No detailed engine runs or events |
| `run` | Run events |
| `phase` | Run and phase events |
| `raw` | All emitted events |

Retention settings and their usual values:

| Setting | Generated backup-worker template | Process telemetry, normally |
| --- | --- | --- |
| Enabled | yes | `enabled = true` |
| Mode | `phase` | — |
| Batch size | 256 events | — |
| Flush interval | 250 ms | — |
| Retained runs | 100 | 100 |
| Logical-size threshold | 64 MiB | 64 MiB |

A limit of zero turns that limit off. These settings are separate from how many
backups are kept, and they do not cap the physical size of the SQLite file. The
settings keys are in [configuration](configuration.md).

## Progress and liveness

**Heartbeats.** Long-running backup, restore and archive operations emit
`operation.heartbeat`, but only while they are working. A missed heartbeat marks a
workflow stale only while it is `Running`. An idle producer or a finished operation is
not a failure.

**Restore and archive progress.** Each progress callback replaces the latest
cumulative sample. A background writer normally records `progress.snapshot` about every
100 ms.

- At a phase boundary, the previous phase's final sample is queued first.
- Start, completion, failure, cancellation and busy events keep their order and are
  flushed before the process exits.
- Retries merge adjacent progress samples within a phase without losing these
  boundaries.
- Readers calculate percentages from the cumulative completed and total values.

**Backup progress.** The scan, hash and capture phases also report progress, sampled
before it is serialised. Scan progress stays indeterminate until the total is known.
Hash progress counts completed files and bytes. These events go through the same
bounded queue and batches as other backup events.

**Deleting a save from the app.** This runs inside the app and uses a latest-value
slot instead of a worker telemetry database. The UI timer takes the newest sample;
completion or failure comes from the operation's task. While files are being listed,
it reports how many were found; percentages appear only once the total is known.

**Matching events to cards.** Operations started from the UI carry an `operation_id`
from [admission](glossary.md#admission) onward. The projection matches on that
identifier rather than guessing from the operation kind and run number. A final state
wins over a running update that arrives late.

## App logs

The app projects producer events into `logs.db` at one of five levels: Trace,
Information, Warning, Error or Critical. File-completion, progress, heartbeat and
workload-discovery events feed progress and metrics but are left out of the ordinary
log list.

How levels are chosen:

- Cancellation is a warning and failure is an error.
- A `.completed` event with a `Failed` or `Degraded` outcome is still shown as an
  error or a warning. Busy, cancelled, degraded and failed outcomes are never shown as
  success.
- Work that did not start is Information, not a problem to acknowledge: `run.busy` (other
  work was running) and `run.unavailable` (what it needs is absent, such as a recording
  with no game or with more than one). Its card shows the neutral icon and says why.
- A duplicate state-scheduler check (`Busy`, `Started=false`) is logged at Trace. This
  does not hide rejected user backups or real failures.
- A numeric `outcome` is read as `ProcessOutcome`. The numeric backup `status` written
  by older versions is read as `RunStatus`.

Storage policy comes from the `[logs]` section of `config/app/default.toml`; the Logs
screen's display filters are saved in `settings.toml`. Neither changes how long raw
telemetry is kept.

The app also reads the telemetry of the separate maintenance lanes. When file cleanup
partly fails, the event includes a count and up to eight file names.

## Failure details

A failure payload includes `failureCode`, `exceptionType`, `message` and `hResult`,
plus, when known, the phase, relative path, save ID, reason and inner exception details.
A `Win32Exception` also carries `nativeErrorCode`: its `hResult` is only the generic
`0x80004005`, and the number (5 for access denied) is what says why. When a worker
cannot be started it records nothing itself, so the app logs that worker's `run.failed`
entry (`phase` `process-launch`) with the same number.

- Short diagnostic strings are flattened onto one line and capped at 512 characters.
- Absolute source paths are masked.
- A failure that implements `IFailureDiagnostics` may add a `diagnostics` field of up
  to 6,144 characters. Truncation is marked, and the same path masking and newline
  normalisation apply.

**How the Logs page shows it.** The failure card speaks the app's language only. Its
explanation comes from the failure code, the exception type and the Windows error number
(`nativeErrorCode`, or the one inside an `hResult` of the form `0x8007xxxx`), never from the
wording of `message`: Windows writes some messages in its own
language, whatever language the app uses. A known worker `reason` is shown translated.
Anything that cannot be explained this way (an unknown reason, the message itself) is
shown word for word as *Original message* under the technical details. A notice the app
logged itself (`app.action.failed`) keeps the title and message it showed; if that text
is a whole string of any of the app's languages, the page shows it in today's language.
The table for that lookup (every string of every language, about a second to read) is
built in the background at launch. The app does not set
`ApplicationLanguages.PrimaryLanguageOverride`: with it set, every resource lookup answers
in that one language whatever language it asks for, and the table could not be built.

**Where to look.** For a failed game save or a deferred preparation, read the original
`backup-worker` event. It keeps the detailed diagnostics, including `run.cancelled` with
`code=source-deferred`. Parent runners and schedulers carry only the child's error code;
the producer that did the work owns the detailed file information. Events and result
envelopes are linked by the same run index.

## Limits

- **The last batch can be lost.** A crash can lose the last batch that was not yet
  committed.
- **Best effort.** A SQLite error turns off telemetry for that backup session and is
  reported as a warning in the result. Recording and trimming process telemetry are
  also best effort.
- **Batching is not sampling.** Batch size and flush interval decide how events are
  grouped into transactions. They do not sample or aggregate events.
- **Retention is not a file-size cap.** The size threshold does not limit the physical
  SQLite file.
- **Old logs stay as they are.** Logs already stored are not rewritten when the level
  rules change.

## How it works inside

### Writing backup events

The backup event writer uses a bounded channel with backpressure. A batch is written
when it is full or when its flush deadline passes. The deadline starts at the first
event in the batch and does not move as more events arrive.

After taking the repository [writer lease](glossary.md#writer-lock), a one-shot backup
may mark running telemetry rows left by earlier runs as abandoned. Read-only consumers
never do this recovery.

### Reading

`telemetry_read_timeout_seconds` defaults to one second. It bounds both SQLite's busy
waiting and the provider's retries; setting only `PRAGMA busy_timeout` would leave the
provider's default retry window unbounded.

- A new database without tables or metadata is given the initialisation grace period.
- Missing metadata after a successful read, or a failure after the grace period, is an
  error.
- Invalid JSON, dates or instance IDs affect only the source they came from, so other
  producers keep updating.
- A read error keeps the database path, the stage, the exception message and the inner
  exception, for diagnosis.

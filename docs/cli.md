# Command-line contract

[Documentation index](README.md) · [User guide](../README.md)

Workers and runners execute one operation. Schedulers own recurring state.
Direct calls allocate a global `run_index`; a supplied `--run-index` is
reused throughout the pipeline. Backup `--revision` is a CLI-only override
that must exceed the current revision.

## Backup diagnostics

```text
backup --repository <path> --source-id <id> [--source <id>=<path>]
    [--run-index <n>] [--control-db <path>] [--revision <n>]
    [--always-include <relative-path>]...
    [--full-scan-hash-comparison <true|false>]
    [--save-game] [--save-game-before-backup <true|false>]
    [--require-active-game] [--scheduled-utc <ISO 8601>]
restore --repository <path> --source-id <id> --revision <n> --target <save-path>
verify --repository <path>
maintenance prune --repository <path> --source-id <id> --keep <n>
maintenance gc --repository <path>
config validate [configuration options]
config show [configuration options]
scan <source> <catalog.json>
diff <source> <catalog.json>
```

`--save-game` requests a save from the matching running single-player world.
`--require-active-game` skips automatic work when that world stops before
capture. `--scheduled-utc` allows advance preparation but prevents saving
and capture before the scheduled time.

`restore`, `verify`, and all `maintenance` commands require an existing
repository, so a mistyped path does not create one.

## Runners, schedulers, and archives

```text
PzTools.Backup.Runner --repository <path> --source-id <key> [--run-index <n>]
    [--config <runner.toml>] [--worker-config <backup-worker.toml>]
PzTools.Maintenance.Runner --repository <path> --source-id <numeric-id> [--run-index <n>]
    [--config <runner.toml>] [--worker-config <maintenance-worker.toml>]
PzTools.State.Runner --state-db <path> --saves-root <path> [--run-index <n>]
    [--config <state-runner.toml>]
PzTools.State.Collector.Cli --state-db <path> --saves-root <path> [--run-index <n>]
    [--control-db <path>] [--config <state-collector.toml>]
PzTools.State.Reactor.Cli --state-db <path> [--run-index <n>]
    [--control-db <path>] [--config <state-reactor.toml>]

PzTools.Backup.Scheduler configure --scheduler-db <path> --repository <path>
    [--interval-minutes <0..60>] [--config <backup-scheduler.toml>]
PzTools.Backup.Scheduler run --scheduler-db <path>
    [--control-db <path>] [--worker-directory <path>] [--once]
PzTools.State.Scheduler --scheduler-db <path> --state-db <path>
    --saves-root <path> [--repository <path>]
    [--control-db <path>] [--interval-seconds <n>]
    [--worker-directory <path>] [--once]

PzTools.Zomboid.Archive.Cli inspect --archive <file>
PzTools.Zomboid.Archive.Cli export --repository <path> --source-id <numeric-id>
    --revision <n> --output <file> [--run-index <n>] [--control-db <path>]
PzTools.Zomboid.Archive.Cli import --archive <file> --saves-root <path>
    [--run-index <n>] [--control-db <path>]
```

The scheduler configure command accepts zero to disable automatic backups.
App settings store the enabled toggle separately from the 1–60 minute interval.

Publish development executables together with `scripts/publish-tools.ps1`.
Runners launch fixed worker names from that directory. Each `--config`
selects only its own process's settings; BackupRunner and MaintenanceRunner use
`--worker-config` to override a child's configuration. See
[configuration](configuration.md) for defaults, precedence, and worker overrides.

## Restore safety

Restore builds staging beside the target, moves the existing save to a rollback
name, and installs staging through an atomic directory rename. It accepts an
existing target but rejects a running save if `players.db` cannot be opened
exclusively.

Interrupted operations are reconciled at app startup. Version 2 journals record
directory identities so recovery can prove the installed target came from staging
before removing rollback. A conflicting folder, unverifiable version 1 journal,
or access error preserves the original, staging, and journal for resolution.
An `installed` phase label alone is insufficient. Recovery also uses the
original directory identity when resuming an interrupted rollback.

## Results and exit codes

| Code | Meaning |
|---:|---|
| 0 | Completed successfully |
| 1 | Backup, restore, repository, or I/O failure |
| 2 | Cancelled at a safe boundary |
| 3 | Verification found missing or damaged data |
| 4 | Maintenance committed, but some physical files could not be removed |
| 64 | Invalid command, configuration, or arguments |
| 75 | Runner mutex or repository writer lease is busy |

A runner that cannot acquire its mutex records a `Busy` workflow without
starting a worker. Its allocated run index is retained. The scheduler retries
without accumulating missed ticks or consuming an unstarted pending attempt.

Runners and one-shot workers write a common JSON envelope to stdout with version,
component, `runIndex`, outcome, timestamps, and result/error. Parents validate
the supplied run index, component, and exit code; mismatches become
`invalid-runner-result` or `runner-contract-mismatch`.
Diagnostic errors may instead use stderr JSON with `success`, `code`,
and `message`.

Telemetry failure does not change a successful backup's exit code. The result's
`warnings` can report telemetry errors, quarantined staging files, and orphan
packs. See [telemetry](telemetry.md) for diagnostic details.

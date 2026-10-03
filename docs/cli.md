# Command line

[Documentation index](README.md) · [User guide](../README.md) · [Glossary](glossary.md)

Every background program in PZ Tools is also a command-line program. This page lists
their commands and options, the exit codes they return, and how a restore protects the
save it replaces. It is for scripting, testing and troubleshooting without the app;
everyday backups and restores go through the app.

Programs come in two roles
([scheduler, runner, worker](glossary.md#scheduler-runner-worker)):

- **Workers and runners** carry out one operation and exit.
- **Schedulers** keep the state of recurring work.

Each operation gets a [run index](glossary.md#run-index). A direct call allocates a new
global `run_index`; a `--run-index` you supply is reused throughout the pipeline.

Settings, defaults and which setting wins are on the [configuration](configuration.md)
page.

## Backup diagnostics

```text
backup --repository <path> --source-id <id> [--source <id>=<path>]
    [--run-index <n>] [--control-db <path>] [--revision <n>]
    [--always-include <relative-path>]...
    [--full-scan-hash-comparison <true|false>]
    [--save-game] [--save-game-before-backup <true|false>]
    [--require-active-game] [--scheduled-utc <ISO 8601>]
    [--game-version <text>]
restore --repository <path> --source-id <id> --revision <n> --target <save-path>
verify --repository <path>
maintenance prune --repository <path> --source-id <id> --keep <n>
maintenance gc --repository <path>
config validate [configuration options]
config show [configuration options]
scan <source> <catalog.json>
diff <source> <catalog.json>
```

| Option of `backup` | Effect |
| --- | --- |
| `--save-game` | Asks the matching running single-player world to save first ([game bridge](game-bridge.md)) |
| `--require-active-game` | Skips automatic work if that world stops before files are captured |
| `--scheduled-utc` | Allows preparation in advance, but no saving or capture before the scheduled time |
| `--game-version` | Records the running game's version with the new backup. The app and the scheduler pass it while the game has that save loaded. |
| `--revision` | Command-line-only override of the revision number; it must be higher than the current revision |

`restore`, `verify` and all `maintenance` commands need an existing repository, so a
mistyped path does not create a new one.

The configuration options and overrides accepted by `backup` and `config` are listed
under [configuration](configuration.md#checking-and-overriding-from-the-command-line).

## Runners, schedulers, and archives

```text
PzTools.Backup.Runner --repository <path> --source-id <key> [--run-index <n>]
    [--config <runner.toml>] [--worker-config <backup-worker.toml>]
    [--control-db <path>] [--worker-directory <path>]
PzTools.Maintenance.Runner --repository <path> --source-id <numeric-id> [--run-index <n>]
    [--config <runner.toml>] [--worker-config <maintenance-worker.toml>]
    [--control-db <path>] [--worker-directory <path>]
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
PzTools.Zomboid.Archive.Cli export-live --source <save-path> --save-id <mode/name>
    --output <file> [--run-index <n>] [--control-db <path>]
PzTools.Zomboid.Archive.Cli import --archive <file> --saves-root <path>
    [--run-index <n>] [--control-db <path>]

PzTools.Zomboid.Recovery.Cli --repository <path> --saves-root <path> --save-id <mode/name>
    --run-index <n> --telemetry-identity <path>
PzTools.Profiler.Cli record --output <file.pzprof> --stop-file <file> --mode general|detailed
    --run-index <n> --telemetry-identity <path>
    [--max-seconds <5..>] [--process-id <pid>] [--bridge <game-bridge-dir>] [--owner <app-run>]
PzTools.Profiler.Cli roll-start --mode general|detailed --seconds <n> [--max-megabytes <n>] [--owner <app-run>]
PzTools.Profiler.Cli roll-save --output <file.pzprof> --seconds <n>
PzTools.Profiler.Cli roll-stop
    (each: --run-index <n> --telemetry-identity <path> [--process-id <pid>] [--bridge <game-bridge-dir>])
```

- `PzTools.Zomboid.Recovery.Cli` performs [character recovery](character-recovery.md)
  on a save that is not being played.
- `PzTools.Profiler.Cli` makes one [performance recording](profiler.md): it records until
  the stop file appears or `--max-seconds` (default 600) runs out, then converts the
  result. Without `--process-id` it looks for the single running game. With `--owner`, an
  app run's identifier, the game ends the recording once that run's lease lapses (see
  [leases](game-bridge.md#leases)). `roll-start`, `roll-save` and `roll-stop` start, save
  and stop [the last minutes](profiler.md#the-last-minutes); they are internal, started by
  the app.
- `PzTools.Maintenance.Cli` is the maintenance worker. It is internal: MaintenanceRunner
  and StateScheduler start it with the options they need (`--lane`,
  `--dispatch-lanes`, `--saves-root` and others).

- `PzTools.Backup.Scheduler configure` accepts an interval of zero to turn automatic
  backups off. The app's settings store the on/off switch separately from the 1–60
  minute interval.
- Publish development executables together with `scripts/publish-tools.ps1`. Runners
  start workers with fixed names from that same directory.
- Each `--config` selects the settings of its own process only. BackupRunner and
  MaintenanceRunner use `--worker-config` to override their child worker's settings.
  See [configuration](configuration.md#which-setting-wins) for defaults and precedence.

## Results and exit codes

| Code | Meaning |
|---:|---|
| 0 | Completed successfully |
| 1 | Backup, restore, repository, or I/O failure |
| 2 | Cancelled at a safe boundary |
| 3 | Verification found missing or damaged data (`verify`), or a runner or maintenance run finished degraded |
| 4 | Maintenance committed, but some physical files could not be removed |
| 64 | Invalid command, configuration, or arguments |
| 75 | Runner mutex or repository writer lease is busy |

**Busy (75).** A runner that cannot take its mutex records a `Busy`
[workflow](glossary.md#workflow) and does not start a worker. The run index it was given
stays used. The scheduler tries again later; missed ticks do not pile up, and a pending
attempt that never started is not used up.

**Result output.** Runners and one-shot workers write a common JSON envelope to stdout
with the version, component, `runIndex`, outcome, timestamps, and result or error. The
parent process checks the run index it supplied, the component and the exit code. A
mismatch becomes `invalid-runner-result` or `runner-contract-mismatch`. Diagnostic
errors may instead be written to stderr as JSON with `success`, `code` and `message`.

**Warnings.** A telemetry failure does not change the exit code of a successful backup.
The result's `warnings` can report telemetry errors, quarantined staging files and
orphan packs. See [telemetry](telemetry.md) for details.

## Restore safety

A restore replaces a save folder with the contents of a backup. It works in three
steps:

1. Build the restored save in a staging folder beside the target. Each stored object is
   verified as it is read, files are written under their final names, and every file is
   flushed to disk (by a few background workers, while later files are written) before
   the next step.
2. Move the existing save aside to a rollback name.
3. Put the staging folder in place with an atomic directory rename.

An existing target is accepted. A save that is running is refused: if `players.db`
cannot be opened exclusively, the restore does not start.

The save is not touched until the rename step. A restore that fails before then
discards its own staging folder and [journal](glossary.md#restore-journal), even if
the save has been opened in the meantime, and reports the original error. After the
new save is installed, a rollback folder that cannot be removed yet stays in the
journal for later cleanup; the restore still counts as successful.

### After an interruption

Interrupted operations, restores included, are sorted out when the app starts. This
recovery never writes
into an existing save, so it does not wait for that save to be closed.

- Version 2 journals record directory identities. Recovery uses them to prove that the
  installed target came from staging before it removes the rollback folder, and uses
  the original directory's identity when it resumes an interrupted rollback.
- A phase label of `installed` alone is not enough proof.
- If there is a conflicting folder, a version 1 journal that cannot be verified, or an
  access error, the original save, the staging folder and the journal are all kept so
  the situation can be resolved.

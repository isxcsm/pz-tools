# Configuration

[Documentation index](README.md) · [User guide](../README.md)

## App settings

The app saves UI choices in `%LOCALAPPDATA%/PzTools/settings.toml`.
Advanced component settings live separately under `%LOCALAPPDATA%/PzTools/config`.
Use **Open folder** in Settings to find them, then **Apply settings and restart**
after editing. **Restore defaults** archives the current `config` directory
under `config-backups` and recreates the templates while preserving UI choices.

The app creates 13 component TOML files with English keys and comments. Changing
the UI language does not rewrite them, update comments, or insert missing keys.
Workflows, schedules, and recorded logs are stored in databases, not these files.

Key app settings:

| Setting | Default | Behavior |
|---|---|---|
| `[ui].system_tray` | `false` | When enabled, closing the window hides it in the tray. Restore or exit through the tray menu. Exit requires confirmation and stops the scheduler. |
| `[backup].automatic_enabled` | `true` | Enables automatic backups independently of interval, death-backup, and pre-backup-save preferences. |
| `[backup].interval_minutes` | `5` | Integer from 1 through 60. Editing it does not enable automatic backups. |
| `[backup].pause_periodic_during_game` | `true` | Preserves the remaining interval while the game is paused, the player is asleep, or runtime state is unknown. Resumes counting afterward. |

Disabling automatic backups preserves the selected interval and does not stop
manual or already-started backups. Re-enabling checks current play state and starts
a new interval. Older settings without the toggle interpret `interval_minutes = 0`
as disabled, with five minutes as the retained interval. Reading does not rewrite
the file; the next settings save writes both fields. With an explicit toggle, zero
or an invalid interval type is an error. See
[runtime pause observation](runtime-pause-backups.md) for pause behavior.

In `config/app/default.toml`, `[logs].record_minimum_level` and `max_entries`
control stored logs. The Logs screen's level and count filters affect display only.

## Backup worker

The worker reads `config/backup-worker/default.toml` unless `--config`
selects another file. Precedence is code defaults, TOML, overlapping app choices,
then explicit CLI options. Relative source paths in TOML resolve against that
file's directory.

The current generated template includes:

```toml
format_version = 1

[capture]
save_game_before_backup = true
game_save_countdown = true
always_include = ["players.db", "vehicles.db", "thumb.png"]
full_scan_hash_comparison = true

[storage]
checksum = "auto"
compression = "auto"
content_deduplication = false
verify_staged_copies = true

[telemetry]
enabled = true
mode = "phase"
batch_size = 256
flush_interval_ms = 250
retain_runs = 100
max_database_mib = 64
```

These are template values. A custom TOML that omits telemetry fields uses the
engine fallbacks: raw mode, 1,000 runs, and 256 MiB. Use `config show` to check the
effective configuration.

`always_include` recaptures the listed source-relative paths even when USN or
a full comparison reports no change. Missing previously stored files become
tombstones after absence is confirmed. Omitting the key uses the same default list;
an explicit `[]` disables extra capture. This setting cannot flush game memory.

`full_scan_hash_comparison` reads content with SHA-256 when USN is unavailable,
including files whose metadata matches. A missing comparison fingerprint causes
capture to establish a baseline. Turning it off can miss content changes that
preserve size and times; it does not affect `always_include`, existing
fingerprints, or integrity checksums. Format 2 stores nullable comparison
fingerprints as the first 16 bytes of SHA-256. Full SHA-256 integrity checksums can
also supply a comparison baseline.

`save_game_before_backup` requests a save before game-aware file capture.
Disabling it captures only data already on disk. Turning off
`game_save_countdown` skips the messages and the manual backup's five-second delay
while keeping the save request. Periodic backups keep their scheduled deadline.
Changes apply to the next backup. See
[save bridge](save-bridge.md).

`verify_staged_copies` verifies private copies with SHA-256 and retries unstable
reads. Disabling it preserves staging and metadata checks but reduces content
consistency checks; keep it enabled for live saves. Capture defaults to four
readers, eight files in flight, and a 4 MiB pool budget. With 256 KiB slots, effective
staging capacity is 2 MiB. Full-scan hashing uses batches of 16 and at most four
readers. See [stable capture](stable-capture.md) and
[runtime configuration](runtime-configuration.md) for bounds and controls.

Checksums support `auto`, `none`, `xxhash64`, and `sha256`;
compression supports `auto`, `none`, and `brotli`. Currently
`auto` resolves to XxHash64 and Brotli. Deduplication requires SHA-256.

New backup names follow the selected app language; English uses
`Manual backup N` and `Automatic backup N`. Existing names do not change
when language changes. App `[ui].language`, worker `[naming].language`,
and CLI `--name-language` accept [supported locale codes](localization.md),
including `en-US`, `ko-KR`, and `ja-JP`. Legacy `Korean`
and `English` values remain readable.

## Validation and overrides

```powershell
dotnet run --project src/PzTools.Backup.Cli -- config validate --repository C:\Backups\pz
dotnet run --project src/PzTools.Backup.Cli -- config show --repository C:\Backups\pz
```

For direct CLI use, define sources in TOML or pass repeated `--source <id>=<path>`
options. Explicit source options replace the TOML source list. Repeated
`--always-include <relative-path>` options likewise replace its entire list.

Other overrides cover `--checksum`, `--compression`,
`--content-deduplication`, `--verify-staged-copies`,
`--full-scan-hash-comparison`, `--save-game-before-backup`,
`--name-language`, and `--telemetry-{enabled,mode,batch-size,flush-ms,retain-runs,max-database-mib}`.
Boolean options take `true` or `false`; telemetry modes are
`off`, `run`, `phase`, and `raw`.
See the [CLI contract](cli.md) for commands.

Unknown keys/options are errors. Source IDs are unique without regard to case.
Source roots cannot overlap each other or the repository. Always-include paths
must be relative and cannot contain `..`.

## Process ownership and retention

Other components merge packaged `defaults/<component>/default.toml`, central
`config/<component>/default.toml`, overlapping app settings, and an explicit
`--config`, in that order. Central settings are shared by that component
across an installation. Parent settings are not implicitly passed to children:
BackupRunner and MaintenanceRunner use `--worker-config` for an explicit
child override.

The app chooses how many automatic backups to keep. Manual and unknown-origin
backups are excluded from count-based retention, but remain subject to explicit
deletion and the separate policy for confirmed missing source folders.
Automatic pack recompression is disabled. Maintenance TOML contains diagnostics
and bounded maintenance controls; see [repository housekeeping](repository-housekeeping.md).

Telemetry retention is separate from backup retention. A zero run or size limit
disables that limit; the size threshold measures used database pages, not the
physical file size. `enabled = false` disables recording. See
[telemetry](telemetry.md) for modes and failure behavior.

The app owns backup cadence. StateScheduler's `[scheduler].interval_seconds`
applies only without `--interval-seconds`. Archive resource limits are
documented in [deployment layout](deployment-layout.md).

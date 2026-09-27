# Deployment and runtime data layout

[Documentation index](README.md) · [User guide](../README.md)

PzTools keeps installed files, app control data, and user-selected backup
repositories separate.

```text
C:\Program Files\PzTools\
  PzTools.App.exe and worker executables
  defaults\<component>\default.toml    # read-only packaged defaults

%LOCALAPPDATA%\PzTools\
  control.db                          # installation-wide run_index allocator
  settings.toml                       # choices saved from the app UI
  config\<component>\default.toml     # 13 editable component configurations
  config-backups\                     # TOML copies made by Restore defaults
  state.db                            # current game/save state
  scheduler.db                        # schedule and command inbox
  logs.db                             # projected app logs
  operations\<component>\<operation>\ # temporary operation telemetry
  cache\
  temp\

<user-selected BackupRoot>\
  repository.db, packs\, staging\, telemetry.db
  .pztools\<component>\...            # component diagnostics
```

PzTools does not create its databases or `.pztools` directories beside source
save folders or imported archives. Development runs use the same app-data layout.
Existing configuration files are not automatically relocated or rewritten.

## Global run_index

`control.db` atomically allocates monotonically increasing run indices across
an installation. A scheduler or app supplies the number to its runners and workers;
direct CLI and runner calls allocate through `--control-db` or the default
control database.

Allocation precedes mutex acquisition. Gaps caused by busy or failed runs are
expected and never reused. An unavailable control database fails the run rather
than falling back to a local counter.

The initial allocation floor is UTC Unix milliseconds shifted left by 16 bits,
reducing collision risk after a lost database is recreated. Recovery tools may
also supply the largest observed value as an exclusive lower bound.

## Archive import limits

Inspection and import default to 1,000,000 entries and 64 GiB per uncompressed
file. Checks cover paths, links, duplicate entries, per-file sizes, and actual
extracted byte counts. Compression ratio alone is not a rejection criterion.

There is no arbitrary total extraction-size cap. Before import, the worker
estimates required space and requires free space afterward of at least
`max(5 GiB, 10% of uncompressed archive contents)`. The percentage is based
on archive contents, not drive capacity.

Adjust `config/archive-worker/default.toml` or an explicit process
`--config`. The packaged `defaults/archive-worker/default.toml` supplies
the initial defaults.

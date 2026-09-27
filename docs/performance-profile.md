# Performance profile

[Documentation index](README.md) · [User guide](../README.md)

The Release profiler creates a deterministic file tree, takes an initial backup,
applies overwrite/append/truncate/rename/delete/create operations, then runs a
journal-based incremental backup, restores the latest revision, and verifies every
committed pack. JSON output records elapsed time, managed allocation, repository
size, and process peak working set. Each strategy runs in a fresh child process.

## Historical results

The measurements below predate the current bounded capture pipeline. They used
seed 1729 on `LOCAL-MAIN`, with source and repository on the same `C:` volume.
They are engineering observations, not hardware-independent targets or CI failure
thresholds. See [backup tuning](backup-tuning.md) for the 2026-09-27 comparison that
selected the capture and full-scan hash defaults documented in [stable capture](stable-capture.md).

The 2026-09-22 regression profile used 500 random 4 KiB files and 10 mutations.
Across four strategies, initial backup took 0.65–0.76 s, incremental backup
0.14–0.19 s, restore 1.90–2.00 s, and peak working set 60.7–63.3 MiB. All strategies
completed restore and pack verification. The generated output was
`artifacts/profile-final/profile-results.json`.

An earlier 2,000-file random 4 KiB workload, after buffer pooling, recorded:

| Checksum / compression / telemetry | Initial | Incremental | Restore | Restore allocation | Repository size |
|---|---:|---:|---:|---:|---:|
| none / none / off | 1.74 s | 199 ms | 6.84 s | 12.6 MB | 9.69 MB |
| XxHash64 / Brotli / off | 1.51 s | 159 ms | 6.88 s | 13.5 MB | 9.73 MB |
| XxHash64 / Brotli / raw | 1.40 s | 213 ms | 6.82 s | 13.5 MB | 10.28 MB |
| SHA-256 / Brotli / off | 1.39 s | 144 ms | 6.82 s | 13.6 MB | 9.79 MB |

Pooling reduced restore allocation from roughly 800 MB to 13 MB under these
conditions. Creating and closing many small files remained the main restore cost.

Other observations from the same historical profiling:

| Workload | Observation |
|---|---|
| 12 warm Release CLI help launches | 71.49–84.93 ms per launch |
| Sixteen random 8 MiB files | Without compression: about 176.3 MB repository and 0.67 s initial backup. Brotli added CPU without useful size reduction; SHA-256/Brotli took 1.32 s. |
| Sixteen compressible 8 MiB files | Brotli reduced about 176.3 MB to 0.16 MB. XxHash64/Brotli took 0.58 s; SHA-256/Brotli took 1.05 s. Raw telemetry added about 8 KiB. |

## Current strategy

`checksum = "auto"` resolves to `xxhash64`; `compression = "auto"` resolves
to `brotli`. Use `none` compression for data that is already compressed or
incompressible when measurements justify it. Content deduplication is opt-in and
requires SHA-256 plus byte comparison.

A backup run that writes new objects seals one immutable version 1 pack.
Compression, pack writing, and catalog updates use one consumer; source reads
overlap through the bounded capture pipeline. The old sequential-I/O measurements
above must not be read as a description of current concurrency.
[Stable capture](stable-capture.md) documents the limits.

The generated worker template uses phase telemetry, batches of 256 events, and
a 250 ms flush interval. Raw mode is available for detailed diagnostics. Telemetry
errors do not invalidate a successful revision.

## Reproduction

Run on the deployment hardware:

```powershell
dotnet run --project src/PzTools.Backup.Benchmarks -c Release -- --output artifacts/profile --files 2000 --bytes 4096 --operations 20 --seed 1729 --compressible false
```

The output contains `profile-results.json` and separate source, repository, and
restore trees for each scenario. To measure cross-volume behavior, choose an
output volume appropriate to that experiment.

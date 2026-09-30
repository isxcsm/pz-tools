# Backup tuning measurements

[Documentation index](../README.md) · [User guide](../../README.md)

> **Historical record.** This page describes the code and measurements at the time it was written. It is kept for reference and is not updated; for current behaviour start at the [documentation index](../README.md).

This records 78 synthetic-workload runs on 2026-09-27, starting from the bounded
capture implementation at `6ae3519`. The selected settings became the defaults;
see [stable capture](../stable-capture.md) for current values. Results describe this
machine and workload and do not identify optimal settings for every disk.

## Conditions and measurement scope

| Item | Conditions |
|---|---|
| Hardware | Intel Core i7-8700K, 6 cores/12 threads; Samsung 960 EVO 500 GB SSD |
| Environment | Game running; no game hooks or save commands invoked |
| Cache | Repeated synthetic reads with OS caching; not cold-cache testing |
| Storage | XxHash64, Brotli, deduplication off, phase telemetry |
| Safety | Staged-copy verification, comparison fingerprints, and full-scan hashing enabled |
| Seed | 1729; mixture of repeated values, periodic patterns, and random bytes |

The generated workloads were:

| Workload | Files | Total bytes |
|---|---|---:|
| `small` | 6,000 × 9 KiB | 55,296,000 (52.73 MiB) |
| `mixed` | 6,000 × 1–128 KiB plus two 16 MiB files | 123.69 MiB |
| `large` | 12,000 × 64–112 KiB | 1,081,332,736 (1.007 GiB) |

Each initial backup used an empty repository. Each unchanged fallback run cloned
a successful seed repository, disabled USN, and set `always_include=[]`. It also
checked that there were zero changes and no new revision. Real saves and backups
were not used or modified.

[TuningProfile.cs](../../src/PzTools.Backup.Benchmarks/TuningProfile.cs) times only
`OneShotBackupService.RunAsync`. Generation, seed cloning, and result validation
are excluded. It checks stored object/fingerprint counts and source byte totals.
A separate post-measurement `verify` on the final large candidate passed with one
pack and zero issues.

Results separate total, scan/planning, capture, and seal/commit times. Fallback
planning includes metadata scanning and hash comparison. CPU time sums all threads;
allocations are cumulative managed allocation. Peak working set covers the entire
process, including preparation. Do not directly compare these values with older
benchmarks that used different data.

## Reproduction

Run from the repository root with PowerShell 7 and .NET 10 SDK. Use fresh output
directories. This minimal `capture-plan.json` intentionally retains the
**historical baseline**, not the defaults selected by this experiment:

```json
{
  "base": {
    "copy_buffer_kib": 128,
    "small_file_staging_kib": 256,
    "staging_memory_mib": 16,
    "capture_read_concurrency": 2,
    "capture_queue_capacity": 16,
    "full_scan_hash_batch_size": 16,
    "full_scan_hash_read_concurrency": 2,
    "scan_batch_size": 512
  },
  "cases": {
    "baseline": {},
    "read-four": { "capture_read_concurrency": 4 }
  }
}
```

For `hash-plan.json`, keep the same base and change the candidate key to
`full_scan_hash_read_concurrency`. Each candidate overlays its case onto the base;
installed user settings are unchanged.

```powershell
dotnet build .\src\PzTools.Backup.Benchmarks\PzTools.Backup.Benchmarks.csproj -c Release
$bench = '.\src\PzTools.Backup.Benchmarks\bin\Release\net10.0-windows\PzTools.Backup.Benchmarks.exe'
& $bench --tune-generate --workload small --output .\artifacts\tuning-repro-small
.\scripts\measure-backup-tuning.ps1 -Source .\artifacts\tuning-repro-small\source -Plan .\capture-plan.json -Output .\artifacts\tuning-repro-capture -Scenario initial -Repeats 2 -OrderSeed 1729
.\scripts\measure-backup-tuning.ps1 -Source .\artifacts\tuning-repro-small\source -Plan .\hash-plan.json -Output .\artifacts\tuning-repro-hash -Scenario fallback -SeedRepository .\artifacts\tuning-repro-capture\r01-baseline\repository -Repeats 2 -OrderSeed 1729
```

[measure-backup-tuning.ps1](../../scripts/measure-backup-tuning.ps1) starts a separate
process per run and shuffles candidate order each round. It preserves the plan,
generated TOML, execution order, raw results, median/range summary, per-run metrics,
and logs. For final comparisons, use three to five repeats. Select `mixed` or
`large` with `--workload` and a fresh output directory.

## Initial small-workload results

These are medians of **two runs per candidate**, excerpted from 11 initial-backup
and 10 fallback candidates. Reader counts refer to capture readers or hash readers,
respectively.

| Path | Change from historical baseline | Total (s) | CPU (s) | Peak working set (MiB) |
|---|---|---:|---:|---:|
| Initial | Baseline | 3.578 | 9.211 | 63.7 |
| Initial | 4 readers | 3.407 | 9.156 | 63.9 |
| Initial | 8 readers | 3.268 | 9.508 | 64.7 |
| Initial | Queue 4 | 3.653 | 9.188 | 64.0 |
| Unchanged fallback | Baseline | 1.963 | 3.398 | 61.4 |
| Unchanged fallback | 4 readers | 1.817 | 3.781 | 61.9 |
| Unchanged fallback | 8 readers | 1.907 | 3.883 | 62.7 |
| Unchanged fallback | Hash batch 64 | 1.934 | 3.398 | 61.2 |
| Unchanged fallback | 4 readers, hash batch 64 | 1.856 | 3.664 | 61.9 |

Four and eight capture readers warranted further comparison. Four hash readers
gave the shortest fallback time but used more CPU; eight brought no further gain.
Small differences in batch/buffer size were not enough to establish a preference.

For fixed buffer size S, queue Q, and budget M, effective staging capacity is
`min(Q, floor(M/S)) × S`. The historical 256 KiB slots and queue of 16 limited
the pool to 4 MiB even with a 16 MiB budget. Unchanged fallback does not use this
capture queue or staging pool.

The original plans and summaries are local build artifacts under
`artifacts/tuning-20260927/small-capture` and `small-hash`.

## Final comparison and selected defaults

Follow-up values are medians of three runs per candidate. The selected capture
settings were four readers, queue eight, and a 4 MiB budget; hashing used four
readers and batches of 16. The large workload applied both sets together.

| Workload/path | Historical baseline | Selected settings | Reduction |
|---|---:|---:|---:|
| Mixed initial | 4.212 s | 3.737 s | 11.3% |
| Mixed unchanged fallback | 2.071 s | 1.840 s | 11.2% |
| Large initial | 12.702 s | 8.799 s | 30.7% |
| Large unchanged fallback | 4.677 s | 3.963 s | 15.3% |

Large initial totals ranged from 11.270–15.713 s before and 8.759–8.823 s with the
selected settings. Capture medians fell from 6.955 to 4.755 s, but the larger
baseline variance prevents attributing the entire total-time difference to capture.
CPU medians were 28.078 versus 27.766 s; peak working set was 79.80 versus 78.65 MiB.
Large fallback traded more CPU (9.313 to 10.516 s) for lower elapsed time. Game frame
times were not measured.

```toml
[runtime]
copy_buffer_kib = 128
small_file_staging_kib = 256
staging_memory_mib = 4
capture_read_concurrency = 4
capture_queue_capacity = 8
full_scan_hash_batch_size = 16
full_scan_hash_read_concurrency = 4
scan_batch_size = 512
```

Eight capture readers were faster on small data but slower than four on mixed data.
Queue 16 was about 1.5% faster on mixed data and brought no additional large-workload
benefit, so queue eight was selected. Its effective 2 MiB staging capacity halves
the old 4 MiB capacity; it does not limit total process memory. Hash batch 64 gained
only about 0.6% on mixed data, so batch 16, copy-buffer size, and slot size were
retained. Safety checks, fingerprint recording, and compression stayed enabled.

Follow-up plans and raw results are local, untracked build artifacts under
`artifacts/tuning-20260927/{mixed-capture,mixed-hash,large-capture,large-hash}`.
To reproduce the combined comparison, keep the historical baseline and override
`staging_memory_mib`, `capture_read_concurrency`, `capture_queue_capacity`,
and `full_scan_hash_read_concurrency` together in the candidate.

## Earlier pipeline comparison

A separate 2026-09-27 Windows Release comparison measured pre-pipeline commit
`6258158` against the initial bounded pipeline, before the final tuning above.
Each side ran three times in separate processes and fresh repositories using
6,000 synthetic files of 9,216 bytes (55,296,000 total), seed 1729. XxHash64/Brotli,
staged verification, comparison fingerprints, and phase telemetry were enabled;
deduplication was off. Generation and post-run pack verification were outside the
backup timer.

| Median | Before pipeline | Initial bounded pipeline |
|---|---:|---:|
| Initial backup total | 12.431 s | 4.631 s |
| Scan | 0.586 s | 0.615 s |
| Capture | 10.848 s | 2.569 s |
| Seal, verify, commit | 0.740 s | 0.901 s |
| Managed allocation during backup | 849.8 MiB | 91.9 MiB |
| Process peak working set | 67.5 MiB | 72.1 MiB |

Every run verified 6,000 files and fingerprints, total bytes, and pack integrity.
Cumulative allocation is not simultaneous memory use; peak working set includes
generation and post-run verification and increased slightly. These historical
results do not describe the final tuned defaults or guarantee the same improvement
on real saves.

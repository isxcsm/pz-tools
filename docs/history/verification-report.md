# Historical verification reports

[Documentation index](../README.md) · [User guide](../../README.md)

> **Historical record.** This page describes the code and measurements at the time it was written. It is kept for reference and is not updated; for current behaviour start at the [documentation index](../README.md).

Results below belong to the stated dates and environments. Check CI for validation of a newer revision.

## 2026-09-25 — external review follow-up

The baseline was `dev` at `2d9108c`, plus the working-tree changes under review. Validation ran on local Windows, not a GitHub-hosted runner.

The review resulted in stricter handling of unreadable files during collection, restore journal v2 directory-identity checks, and Windows build/distribution plus synthetic JVM CI. Uncertain file absence preserves revisions and checkpoints; uncertain rollback targets preserve the original and journal. Administrator launch and the existing orphan-backup cleanup policy were retained at that time. Current retention rules are described in the [user guide](../../README.md).

| Recorded check | Result |
| --- | --- |
| Release solution build | 0 warnings, 0 errors |
| Fresh distribution | Created at `artifacts/app-review-safety` without overwriting the running app |
| Release suite with that distribution | **676 passed, 0 failed, 22 skipped; 698 total** |
| Synthetic JVM bridge suite | **22 passed, 0 failed; 1 real-game probe skipped** |
| README links/images at that time | 18 language versions and 417 local references checked |

Evidence was stored in the Git-ignored `artifacts/review-test-results/review-distribution.trx`. The README count describes the former multilingual documentation, not the current documentation policy.

Recorded reproduction commands:

```powershell
dotnet build PzTools.sln -c Release -p:Platform=x64 -warnaserror
pwsh scripts/publish-app.ps1 -Configuration Release -JdkPath C:\path\to\jdk-25 -Output artifacts/review-fresh
$env:PZTOOLS_DISTRIBUTION_DIR = (Resolve-Path artifacts/review-fresh).Path
$env:PZTOOLS_TOOLS_DIR = $env:PZTOOLS_DISTRIBUTION_DIR
dotnet test tests/PzTools.Backup.Tests -c Release --logger "trx;LogFileName=review.trx" --results-directory artifacts/review-test-results
```

The CI configuration described in this review used the SDK from `global.json`, Java 25, and Windows 2025 runners. It did not receive real user saves, a real game PID, or administrator USN opt-in. Its separate JVM job used synthetic processes. CI success therefore did not establish real-game or administrator USN validation.

## 2026-09-22 — implementation and integration checks

| Recorded check | Result |
| --- | --- |
| Release suite at this point | **179 passed out of 181; 2 administrator opt-in USN tests skipped** |
| Earlier elevated end-to-end run | **173 passed, 0 failed, 0 skipped** |
| Real USN integration | NTFS volume query and journal range read passed |
| Real save samples | Living/dead character classification passed under `%USERPROFILE%\Zomboid\Saves` |
| Published tools | State/backup/maintenance runner chain and archive backup → export → inspect → import passed |
| Lifecycle and failure recovery | Scheduler startup/shutdown/restart, restore-journal boundaries, future-schema rejection, and maintenance admission passed |
| Telemetry | Health states, instance replacement, backlog paging, and retention passed |
| Release/format checks | App and 10 tools published; `dotnet format --verify-no-changes` passed |
| App shutdown | **0 remaining PzTools processes** |

The elevated run used [verify-a15.ps1](../../scripts/verify-a15.ps1). That script publishes Release, runs explicitly opted-in real USN/save and published-process checks, opens the app for visual inspection, and checks for remaining processes after the user closes it.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify-a15.ps1
```

`-SkipPublish` reuses existing output and `-SkipApp` omits the app phase. Non-elevated volume access returned access denied; the app manifest used `requireAdministrator`.

### UI validation remained incomplete

Computer Use could capture the elevated debug app, but its accessibility tree exposed only the window/title bar and menu/exit input did not take effect. The [input diagnosis](computer-use-diagnosis.md) records that boundary.

Outstanding checks at that time included language/theme switching, wide/narrow layouts, keyboard focus and clipping, active-play status/countdown, a final backup after play ended, and backup/restore/archive flows through the real UI. Process cleanup had already passed. Final-on-exit backups were subsequently removed; they are not part of the current [scheduling behavior](../process-architecture.md#game-state-decisions).

Later Fluent layout changes on the same date built with 0 errors and 0 warnings. Their recorded regression runs were **180 passed / 7 skipped**, followed by **181 passed / 7 skipped**, both with no failures. Screenshots of an older debug session and build success did not verify the new layouts: the updated screens, themes, and click flows remained unverified.

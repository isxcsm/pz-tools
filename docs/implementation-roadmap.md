# Historical application plan

[Documentation index](README.md) · [User guide](../README.md)

This records the September 2026 plan for adding the desktop app to the headless backup engine. It is not the current backlog or operating manual.

## Architectural decisions

- `AppHost` owns schedulers, projections and child-process lifetime. Navigation does not start or stop them; app exit ends the owned process tree.
- The scheduler follows one active save instead of maintaining a permanent job per save. Save identity is a normalized path, not a list index or display name.
- Workers own data changes. The UI reads immutable revisioned views and applies only changed snapshots on the UI thread.
- Workflow state determines whether an operation is running; telemetry supplies its progress. Missing progress must not invent a failed or successful operation.
- Restore and import prepare verified staging output before replacing a save. Recovery journals make interrupted publication inspectable on restart.
- Configuration and diagnostics remain separate from game saves. Archive operations are one-shot workers, not extra schedulers.

The current contracts are described in [process architecture](process-architecture.md), [telemetry](telemetry.md) and the [UI contract](ui-ux-contract.md).

## Original work packages

| Packages | Deliverable |
| --- | --- |
| A01–A02 | UI contracts and a single-target scheduler |
| A03–A07 | Database revisions, event contracts and projections |
| A08 | Direct revision-file access and a bounded thumbnail cache |
| A09–A11 | App lifetime, settings, WinUI shell and save/history views |
| A12 | Manual backup and staged restore |
| A13–A14 | ZIP inspection, import/export and UI integration |
| A15 | Process, crash, storage and user-flow acceptance |

The September 22 record marked A01–A14 implemented, with automated and selected local checks for A15. Native UI and real-play acceptance were still outstanding. That record does not certify later commits; see the [verification report](verification-report.md).

## Superseded assumptions

The original checklist proposed two UI languages, a 100-revision default and no tray mode. Current settings use 18 interface languages, 20 automatic backups and optional tray mode. Manual backups are excluded from automatic-count trimming, but not explicit deletion or orphan cleanup.

Scheduling now includes pause/sleep-aware active time and live character-death observations. Capture uses bounded staging and windowed progress; the earlier unsampled-event proposal is not the current performance contract. App startup rearms periodic timing instead of replaying an old due time.

Use [configuration](configuration.md), [runtime timing](runtime-pause-backups.md) and [stable capture](stable-capture.md) for current behavior. The detailed original checklist remains in Git history rather than being maintained as a second specification.

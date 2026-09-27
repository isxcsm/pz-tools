# UI and projection contract

[Documentation index](README.md) · [User guide](../README.md)

The WinUI 3 interface consumes normalized views from `RevisionedViewStore`. It does not interpret SQLite rows, telemetry events, or worker JSON directly. Navigation does not change AppHost, scheduler, or projector lifetimes.

## Shell and layout

The wide save-management page has navigation, a save list, and save details. Narrow windows show the list and detail one at a time with a Back action; detail actions stack when needed. Logs likewise switch from side-by-side to stacked panels.

The shell uses Mica and shared theme/layout resources. Keep dimensions and breakpoints in those resources rather than duplicating them in page code or documentation.

Buttons use theme-aware WinUI styles and retain keyboard focus and disabled states. Selection, expansion, scroll, and focus belong to the UI; refreshing data must not reconstruct an entire page or reset those states. Selection and insertion animations respect the system animation setting.

## Settings

Settings use grouped Fluent cards in a scrollable page. Standard groups start expanded; advanced settings start collapsed. Inputs resize for narrow windows. Defaults and accepted values belong in [configuration](configuration.md).

Automatic backup governs periodic and death-triggered execution. Turning it off preserves the interval and death-backup preference; the interval remains editable. Manual and already-running backups are unaffected. The retention count applies to automatic backups, not manual backups. Game-save and countdown preferences are separate from scheduling and vehicle extensions.

Invalid paths or values are reported without applying them. Changes to future scheduling and UI preferences can be saved while a worker is running; changing data roots requires conflicting work to finish. Advanced controls open configuration files, validate and apply changes through an app restart, or archive the current configuration before restoring defaults.

## Saves and revisions

The save list offers archive import and shows a thumbnail or placeholder, game mode, name, last-played time, active-play overlay, and dead-character badge. Active and dead states can coexist. Stale observations retain the last information with a status explanation. Selection is keyed by `save_id`.

The detail list starts with the current save, selected by default when opening a save, followed by active backup revisions newest first. Periodic refresh preserves the user's selection. Backup names are editable and stored in the repository without changing revision numbers. New names use the configured UI language; unnamed legacy revisions are initialized once.

Each backup shows two separate local times:

- **Last played:** the root `players.db` modification time preserved in that revision's catalog, or Unknown when unavailable.
- **Recorded:** the revision creation time.

The current save shows only last played. Neither its current file time nor backup creation time substitutes for a missing historical last-played value.

Restore requires a backup revision and is disabled while that save is being played. Export accepts either a backup revision or the current save; live export is disabled during play or when the state projector fails. Manual backup is disabled during conflicting work. Character-recovery actions apply only to eligible current saves and remain subject to activity, freshness, and operation checks.

## Operations and health

Operations use progress cards and, where confirmation or exclusive interaction is needed, a modal. CLI/runner named mutexes remain the final protection against external concurrent execution.

| Operation | Main scope |
| --- | --- |
| Automatic/manual backup, including maintenance | RepositoryWrite |
| Revision restore | RepositoryRead + SaveWrite |
| Backup archive export | RepositoryRead |
| Current-save export | SaveWrite |
| Archive import | SaveWrite |

The foreground archive/restore card is shown above the backup card. Progress comes from `OperationView` through this path:

```text
telemetry.db → TelemetryProjectionHost → reducers
            → RevisionedViewStore → ViewModel → WinUI
```

Producers accumulate progress per file and periodically publish the latest snapshot, including a final snapshot at phase changes and completion. The UI distinguishes Waiting, Healthy, Stale, Disabled, Unreadable, and UnsupportedSchema. Workflow/process state determines whether work is running and which buttons remain locked; missing telemetry must not unlock an active operation.

Projector failures appear in a persistent status card. State failure blocks restore and live export; backup failure blocks restore and revision export; scheduler failure replaces the next-backup time with an unavailable status. These failures do not by themselves block manual backup. A successful projection clears its failure state.

Running cards remain visible. Terminal cards expire automatically: success and no-change use the success lifetime (five seconds by default); other outcomes use the failure lifetime (ten seconds). These lifetimes are configurable in the app TOML. Terminal cards hide progress animation and show the outcome even if telemetry was incomplete. Temporary telemetry sources are unregistered when their cards expire.

Restore resolves the revision's numeric `source_id` to its repository `source_key` before passing the logical save key to the CLI's `--source-id`. Original and imported saves have independent revision numbering.

## Logs

`TelemetryProjectionHost` feeds `LogInboxStore`; `LogsView` carries updates and unread-problem state, and `ReadPageAsync` supplies the list. Column headers are accessible filter controls:

| Column | Filter |
| --- | --- |
| Number | Exact 64-bit number or inclusive range, such as `42` or `40-50` |
| Level | Cycle the minimum displayed level, starting at the recording minimum |
| Time | Local date/time range |
| Message | Operation category |
| Operation | Exact operation number or inclusive range |

All filters combine with AND before grouping, counting, and paging. Conditions and page snapshots are part of the cache key. New arrivals do not shift an existing paging snapshot; changing a filter returns to the first page.

Text filters are debounced; Enter and calendar/time selections apply immediately. Opening a filter does not apply a default range. Invalid text preserves the previous filter. Active conditions appear as removable chips, with a Clear all action. Filters last only for the current screen session and do not change recording or retention settings.

Time input accepts `yyyy-MM-dd HH:mm`, optional seconds, and explicit UTC offsets. Empty bounds are open-ended; the entire final entered minute or second is included. Ambiguous or nonexistent daylight-saving times require an unambiguous value rather than a guessed conversion, for example `2026-11-01 01:30 -04:00`.

Ordinary successful polling events such as `tick.completed` and `collector.completed` are projected as Trace. Failures remain errors; Busy, degraded, cancelled, and unknown outcomes remain warnings. Actual backup-result events retain their information level. Existing grouping, acknowledgement, details, copy, and newest-first ordering remain available.

## Archives

Import follows file selection → inspection → confirmation → import. The preview shows available thumbnail and save metadata, stacks in narrow windows, and does not reserve space for a missing image. Cancel is the default confirmation action.

Invalid or corrupt archives are rejected before import. Name collisions use `SaveName(1)`, `SaveName(2)`, and so on. New archives store game files as `Mode/SaveName/file`; legacy v1 root-file archives remain readable.

After a successful import, the existing state runner collects immediately, retaining its global run numbering and StateCollection mutex. Bounded Busy retries precede serialized state → backup → detail projection. The UI refreshes before showing completion. A refresh failure is distinguished from an import failure so the user does not import the same files again. Save deletion uses the same recollection path; revision deletion refreshes the relevant views without collection.

Live export creates no backup revision. The archive worker takes SaveWrite, copies to staging, and compares paths, lengths, and modification times before/after copying and before replacing the final output. It rejects reparse points and output inside the save, aborts if files change, and preserves an existing output on failure. This is not an atomic snapshot of a running game; use it after leaving play. Live-export manifests use `sourceId=0` and `revision=0`.

## Deletion

Save rows and backup-revision rows have delete actions; the current-save detail row does not duplicate the save-list delete action. Confirmation identifies the exact target and scope, defaults to Cancel, and explains that source-save deletion is permanent.

Deleting a save permanently removes its exact `SavesRoot/Mode/Name` directory and marks that save's backups deleted. It does not use the Recycle Bin. Activity, stale/unknown state, conflicting operations, or relevant projector failures block deletion. Path escape, reparse points, missing `players.db`, and known locked/read-only files are rejected before removal.

Repository deletion marking is prepared under a writer lease, committed after folder deletion, and rolled back if folder deletion fails. Filesystem and database changes cannot be atomic together: an OS failure may leave some files deleted, and a later database commit failure is reported as a partial failure. Other saves and previously exported archives are unaffected.

Deleting a revision uses `MarkRevisionDeletedAsync` under the writer lease and operation mutex. The latest or last visible revision may be deleted. Marked revisions immediately disappear from restore/export choices, while physical cleanup and any required internal incremental base remain maintenance responsibilities.

## Game extensions

The extension-wide switch stays at the right of each expander header. Expanded rows place descriptions on the left and independent feature switches on the right. Vehicle controls and the version-range override are inline; developer tuning stays in TOML.

Switches show saved preferences; a separate status reports whether the JVM has applied them. Settings remain editable while offline or waiting to apply, and the UI explains the reason for a delay. Refresh and saving preserve expansion, scroll, and focus. Confirmed failures revert only the matching saved request through compare-and-swap, while `RestartRequired` stays locked until the game restarts. Detailed revisions, hashes, and transition reasons belong in logs. See the [vehicle test guide](e2e-vehicle-drivetrain.md).

## View boundaries

| View | Responsibility |
| --- | --- |
| `SettingsView` | Effective settings and validation errors |
| `SaveListView` / `SaveDetailView(save_id)` | Current saves and backup revisions |
| `ScheduleStatusView` | Enablement, target, mode, next due time, last result |
| `OperationView(operation_id)` | Execution state, progress, telemetry health |
| `MetricsView(producer)` / `TelemetrySourceView` | Retained metrics and producer health |
| `LogsView` | Normalized logs and structured payloads |
| `ProjectorHealthView` | Projector failures and action-safety policy |

Each view has a session-local `view_revision`, incremented only for a meaningful snapshot change. Selection, hover, focus, and countdown rendering do not change projection revisions.

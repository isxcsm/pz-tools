# UI and projection contract

[Documentation index](../README.md) · [User guide](../../README.md) · [Glossary](glossary.md)

This page is for anyone changing the PZ Tools desktop app's interface: the WinUI 3
window where saves, backups, performance recordings, settings, logs and game extensions
are managed. It lists the
rules each screen follows: what it shows, when a button is locked, how the progress
cards behave, and where the data on screen comes from. For how the app fits with the
background processes, read the [overview](overview.md).

## Rules for every screen

- **The screen shows prepared views, not raw data.** Pages read normalized views from
  `RevisionedViewStore` (see [where the data comes from](#where-the-data-comes-from)).
  They never interpret SQLite rows, [telemetry](glossary.md#telemetry) events or worker
  JSON themselves.
- **Moving between pages changes nothing in the background.** Navigation does not start,
  stop or restart `AppHost`, the schedulers or the projectors.
- **The user's place on screen belongs to the UI.** Selection, expansion, scroll position
  and keyboard focus are kept by the page. Refreshing data must not rebuild a whole page
  or reset any of them.
- **Buttons use theme-aware WinUI styles** and keep their keyboard focus and disabled
  states.
- **Animations follow Windows.** Selection and insertion animations respect the system
  animation setting.
- **Sizes live in shared resources.** The shell uses Mica and shared theme and layout
  resources. Keep dimensions and breakpoints there, not in page code or in this
  documentation.

## Layout

In a wide window the save-management page shows three parts side by side: navigation,
the save list and the save details. In a narrow window the list and the details are
shown one at a time, with a **Back** action, and the detail actions stack when they no
longer fit in a row.

The Logs page works the same way: side-by-side panels in a wide window, stacked panels
in a narrow one.

## Home page

The first page shown. It fills the window's width.

- **Title and one line** saying what the app manages, with the illustration at the
  right. The illustration may hang into the empty end of the *Features* heading line, so
  it can be large without pushing the cards down.
- **Three state rows** under the line, each opening its page: whether the game is
  running (and "automatic backup off" when it is); the save being played, or else the
  last one played, with the time of its last backup, or a warning-coloured "no backup";
  the vehicle extension on, off or waiting for a supported game version, with how many
  of its options are on. The shell builds these from the live views
  (`HomeStatusSource`); the page itself reads nothing.
- **Four feature cards**: backup and restore, character recovery, performance and
  game extensions. Each opens its page.
- **Footer**: links, the selectable version and the unofficial-tool notice.

Text is plain and factual: what a feature does, and one fact or limit worth knowing.
Korean text breaks only between words; the page joins the syllables of each word so a
narrow window never splits one.

## Settings page

Settings are grouped Fluent cards on a scrollable page: Version, Display, Paths, Backup,
Game (game memory), Performance, Hotkeys and Advanced. Version and Advanced start
collapsed, the rest expanded. Inputs shrink to fit narrow windows.
Defaults and accepted values are listed in [configuration](../reference/settings.md), not here.

**Automatic backup** is the switch for both periodic and death-triggered backups.

- Turning it off keeps the interval and the death-backup preference, and the interval
  stays editable.
- It does not affect manual backups or a backup that is already running.
- The [retention](glossary.md#retention) count applies to automatic backups only, not
  to manual ones.
- The game-save and countdown preferences are separate from scheduling and from the
  vehicle extensions.

**Saving settings.**

- An invalid path or value is reported and not applied.
- Changes to future scheduling and to UI preferences can be saved while a worker is
  running. Changing a data folder has to wait until conflicting work has finished.
- The advanced controls can open the configuration files, validate changes and apply
  them by restarting the app, or archive the current configuration before restoring the
  defaults.

## Saves page

### Save list

The save list offers **archive import**. Each row shows:

- a thumbnail, or a placeholder when there is none
- the game mode and the save name
- the last-played time
- an overlay while the save is being played
- a badge when the character is dead

A save can be active and dead at the same time. When the
[observation](glossary.md#observation-fresh-stale) is stale, the row keeps its last known information and adds a status explaining why.
Selection is keyed by `save_id`.

### Save details

The detail list starts with the **current save**, which is selected by default when a
save is opened. Below it come the save's active backup
[revisions](glossary.md#revision-backup), newest first. A periodic refresh keeps the
user's selection.

**Backup names** are editable. A name is stored in the [repository](glossary.md#repository)
and does not change the revision number. New names use the configured UI language.
A backup stored without a name (for example by an older version of PZ Tools) gets the
default name when the app starts: *Manual backup*, *Automatic backup* or *Backup*,
followed by its revision number, in the current UI language. Once named it keeps that
name; changing the UI language later does not rename it. If another job is using the
backup folder at start-up, naming waits for the next start.

Each backup shows two separate local times:

| Label | Meaning |
| --- | --- |
| **Last played** | The modification time of the save's root `players.db`, as preserved in that revision's [catalog](glossary.md#catalog). *Unknown* when it is not available. |
| **Recorded** | When the revision was created. |

The current save shows only **Last played**. When a backup's historical last-played
value is missing, neither the current file time nor the backup's creation time is shown
in its place.

**Game version.** A row shows *Version 42.21* at its bottom right when the version is
known; the tooltip says where it comes from.

| Row | Version shown |
| --- | --- |
| A backup | The running game's version when the backup was made. Backups made without the game have none. |
| The current save | First the version of the game running this save now; otherwise the last version PZ Tools saw this save loaded with (remembered in `%LOCALAPPDATA%\PzTools\save-versions.json`); otherwise the version of the newest backup that recorded one. |

A save file itself records no game version, only an internal world format number that
several game builds share, so the current save's version is always one of these
observations.

### Available actions

| Action | Works on | Disabled when |
| --- | --- | --- |
| Restore | A backup revision only | That save is being played, or a [projector failure](#projector-failures) blocks it |
| Export | A backup revision or the current save | Current save (live export): the save is being played or the state projector has failed |
| Manual backup | A save | Conflicting work is running |
| Character recovery | Eligible current saves only | The activity, freshness or operation checks fail |
| Delete | Save rows and backup-revision rows; see [deletion](#deletion) | Checks listed under deletion fail |

## Progress cards

Every operation reports its status as a card in the footer of the navigation pane, which
stays visible on every page. Where an operation needs a confirmation or exclusive use of
the window, it also opens a modal dialog.

There are three kinds of card, and each has a fixed place:

| Kind | What it is | Leaves |
| --- | --- | --- |
| Automatic work | Background cleanup and automatic backups | When finished and its time is up |
| The user's work | Everything the user started, including the result of an action that runs no worker | When finished and its time is up |
| Needs attention | A condition the user should know about or act on | When the condition clears, or through its ✕ |

### One card per piece of work

There is one card per piece of work as the user sees it, not one per process:

- The [scheduler, runner and worker](glossary.md#scheduler-runner-worker) of one backup
  share a card.
- The separate cleanup processes share a single "backup cleanup" card, which shows as
  working while any of them works.
- Work the user starts first shows an app placeholder card, which the worker's own
  progress then takes over. Once the placeholder's result has expired, the worker's
  record of the same work never comes back as a second card.
- An action that runs no worker (a rename, a deletion, a setting that could not be saved,
  work refused before it started) reports its result as a card in the same place as the
  user's other work, titled with the action. There is no separate notice area, so the
  result of an action is always found in one place.

### Order and limit

Cards stack above the fixed next-backup line. From top to bottom:

| Position | Card |
| --- | --- |
| Top | Background cleanup |
| | Automatic backups |
| | What the user asked for: manual backup, restore, export, import, character recovery, deletion, performance recording, and the results of actions that run no worker |
| | Cards that need attention ([below](#cards-that-need-attention)) |
| | The next-backup line |
| Bottom | A newer release of the app: one grey line, right above Settings |

The release line is about the app itself, not the game or its saves, so it has a fixed
place of its own, last, next to Settings where the version and its details are. It stays
until the app is updated or the notice is turned off in Settings, and pressing it opens
the release's page. While the pane is folded to its icons it becomes a dot on the
Settings icon. Other notices about the app itself, should there be any, would join it
there.

All cards share one measure: the title in 13-point type, everything else in 12 (as the
next-backup line), 12 × 10 pixels of padding and 6 between cards.

Within one priority, a new card enters at the bottom and pushes older cards up.

When more than four cards would show, finished cards leave first, starting with the
lowest priority and the oldest. Active work is never removed. Because several finished
cards can be visible at once, each one names its work.

The menu items always keep the height they need. The cards use only the room left
between them and the settings item; finished cards that do not fit are left out by the
same rule, least important and oldest first. Running work, the cards that need attention
and the next-backup line always stay.

### How long cards stay

- A running card stays visible. Its title is on the left and the percentage, when known,
  on the right; below the progress bar the amount (*4.5 / 16.0 MB*, or a count) is on the
  right. A step is named on the left only when it explains a wait: the game saving before
  a backup (it may stall a moment) and a recording being made into a file after it
  stopped; while the total is still unknown, the count of files found so far. How the
  work is done inside is for the logs. Each is one line, shortened with an ellipsis if it
  has to be, so the card keeps its height while the numbers change.
- Card titles use the normal weight. The default Korean font has no semibold, so a
  semibold title would be drawn fully bold; hierarchy comes from colour instead.
- A finished card expires on its own. Success and *no change* use the success lifetime
  (five seconds by default); every other outcome uses the failure lifetime (ten seconds
  by default). Both are set in the app's TOML (`success_card_seconds`,
  `failure_card_seconds`; see [advanced runtime configuration](../reference/advanced-settings.md)).
  The same rule applies to the app's own placeholder cards and action results.
- A card leaves when its time is up, even if no newer progress has been read since.
- While the pointer rests on the cards, finished cards stay, so a message can be read to
  the end. They leave a second after the pointer moves away.
- A failure or warning that only a card reports (an action that ran no worker) is also
  written to the logs, where it stays unread until acknowledged. Worker failures are
  logged by the worker. A card that has left therefore never takes a problem with it.
- A finished card hides its progress animation and shows the outcome, even when its
  telemetry was incomplete.
- A finished card is titled with its work alone (*ZIP export*, not *ZIP export · Done*);
  an icon beside the title gives the outcome: a check for success or no change, a warning
  sign for failure or a partial result, an information sign for cancelled, postponed or
  skipped work. A plain success is that one line and nothing more. Any other outcome, and
  a success that has something specific to say, adds a line below.
- For a failure, a partial result, or work that could not run because something else was
  busy, that line is shown in full: it is what the user has to read, and rarely more than
  one such card is up. For any other outcome it shows at most two lines; the full text
  appears when the pointer rests on it, and in the logs. Such messages are worded to fit
  those two lines in every language, and say what happened rather than repeat what the
  user was told before confirming (a revival reports *Character revived. Items recovered:
  7.*, not that traits were kept).
- When a card expires, its temporary telemetry sources are unregistered.

### Background cleanup card

Background cleanup shows a card only while it is visibly working: straight away when it
has announced real work, otherwise once it has run for two seconds. A routine check with
nothing to do shows no card.

- Cleanup that gives way to a backup or to the game is shown as *postponed* for the
  success lifetime. It is not shown as a failure.
- A cleanup failure is always shown.
- While a cleanup card is running, conflicting actions are locked, as for any other
  running operation.

<a id="cards-that-ask-for-a-choice"></a>
### Cards that need attention

These cards form their own group below the operation stack, directly above the
next-backup line, because they outrank every status card. They never expire: each leaves
when its condition clears, or through the ✕ that shows at its corner while the pointer
is on the card or the keyboard is in it (still reachable with Tab when unseen).

| Card | Leaves |
| --- | --- |
| The app folder is not as published ([checking the folder](../reference/files-and-folders.md#the-app-folder)), first of all; its button opens the download page | Through ✕, for this run |
| Part of the saves page keeps failing to load ([projector failures](#projector-failures)) | When it loads again, or through ✕ |
| App components blocked by Windows | When nothing is blocked any more, or through ✕ |
| The game cannot be read ([game-aware timing](runtime-pause-backups.md#when-the-game-cannot-be-read)), or PZ Tools was updated and the game needs a restart | When the game can be read again, or through ✕; the restart card has no ✕, as automatic backups wait for the restart |
| A game update put the game's own memory back over the chosen one ([game memory](game-memory.md#after-a-game-update)); its button applies the choice again | When the choice is in the game's file again, or through ✕ |

The blocked-components card reports that a Windows security policy (for example Smart App
Control) refused to start part of the app. Which files were refused is in the logs, not
on the card.

- **Open settings** opens the Smart App Control page of Windows Security. The app never
  suggests turning it off: once off, Smart App Control cannot be turned back on without
  reinstalling Windows.
- The card also leaves when a later check finds nothing blocked. It comes back only if a
  different set of components is blocked.

The game-link card names a cause the player can change when the attach found one: a
launch option that turns connecting off. After an app update with the game running it
says to restart the game, and cannot be closed while automatic backups wait for that.
Otherwise it says what backups do meanwhile. See
[when attaching fails](game-bridge.md#when-attaching-fails).

### Writing a card

Cards are read by players, in a pane about 200 pixels wide. Every card, notice and error
message follows these rules, in English and in every translation:

- **A card only when there is something to know or do.** A passing state the user can do
  nothing about gets no card; one that lasts says precisely what is wrong (see
  [projector failures](#projector-failures)). Messages live in the pane's cards, never in
  banners on a page.
- **Title, at most one line, at most one action.** The title says what happened, without
  a final period; the line says what to do or what it means, as a sentence; an action is
  a plain grey button with an arrow. Nothing needed is hidden in a tooltip or behind a
  click.
- **What happened first, then what to do.** *PZ Tools was updated* / *Restart the game.*,
  not the other way round. The line does not repeat the title.
- **The player's words.** No technical terms, file names or inner workings, and no words
  that leave the reader guessing (*some information*). Names the user must find are kept:
  a Windows setting, a menu or setting of the app, a key, a version.
- **Nothing irreversible is suggested.** An action opens the place to decide, no more.
- **"The save is unchanged"** is said only after work that could have changed a save
  (recovery, restore, deletion), and briefly.
- **"Check the logs"** ends a failure whose reason the card cannot give.

The app checks this by starting every worker executable with a no-op `--probe` argument:
at startup, then every five minutes while something is blocked and every six hours
otherwise.

### Projector failures

A projector turns stored data into the views the screen shows (see
[where the data comes from](#where-the-data-comes-from)). It tries again on its own, and
there is nothing for the user to do. A failure that passes within ten seconds (a file
briefly locked) is not shown. One that lasts is said precisely, and some actions are
blocked meanwhile.

| Failed projector | Said where | Effect |
| --- | --- | --- |
| State | A card *Could not load the save list* / *Trying again.*; an empty list also says it in its place | Restore and live export are blocked |
| Backup | The same card, for the backup list | Restore, revision export, deletion and renaming of backups are blocked |
| Details | The same card, for the save details | — |
| Scheduler | The next-backup line: *Next backup time unknown* | — |
| Telemetry | The logs page says it could not load | — |

Only one load card shows, for the first of state, backup and details that fails. Its ✕
keeps it closed until everything has loaded again.

These failures do not by themselves block a manual backup. A successful projection
clears the failure.

### Next-backup line

The schedule card shows a remaining time only when it means something: while counting
down, or held while the game is paused or the character is asleep.

An unknown game state shows its message alone, and only once it has lasted about three
seconds. Until then the previous text stays, so starting the app or the game connecting
does not make it flicker. While a world is loading, the card says so. A game seen
starting says *Game starting* rather than checking, and after an app update with the game
running the line says *Automatic backups after a game restart*, not a time.

## Logs page

Each column header is an accessible filter control:

| Column | Filter |
| --- | --- |
| Number | Exact 64-bit number or inclusive range, such as `42` or `40-50` |
| Level | Cycle the minimum displayed level, starting at the recording minimum |
| Time | Local date/time range |
| Message | Operation category |
| Operation | Exact operation number or inclusive range |

How filters behave:

- All filters combine with AND, before grouping, counting and paging.
- Text filters apply after a short pause in typing. **Enter** and calendar or time
  selections apply at once.
- Opening a filter does not apply a default range.
- Invalid text keeps the previous filter.
- Active conditions appear as removable chips, with a **Clear all** action.
- New log entries do not shift the page being viewed. Changing a filter returns to the
  first page.
- Filters last only for the current screen session. They do not change recording or
  retention settings.

**Time input** accepts `yyyy-MM-dd HH:mm`, optional seconds, and an explicit UTC offset.

- An empty bound is open-ended.
- The whole of the last entered minute or second is included.
- A daylight-saving time that is ambiguous or does not exist must be entered with an
  offset, for example `2026-11-01 01:30 -04:00`; the app does not guess.

**Log levels.**

| Events | Level |
| --- | --- |
| Ordinary successful polling, such as `tick.completed` and `collector.completed` | Trace |
| Background cleanup that had work: an announced start, its completion, any completion that affected items, a postponement | Information |
| Background cleanup routine checks that found nothing to do | Trace |
| Actual backup results | Information |
| Failures | Error |
| Work that did not start: `run.busy`, `run.unavailable` | Information |
| An automatic backup put off during preparation, tried again on its own: `run.cancelled` with `source-deferred` or `source-skipped` | Information |
| Busy, degraded, cancelled and unknown outcomes | Warning |

The default settings do not record Trace. Grouping, acknowledgement, details, copy and
newest-first ordering are available for all entries.

## Archives

**Import** runs in four steps: choose a file, inspect it, confirm, import.

- The preview shows the thumbnail and save metadata that are available. It stacks in
  narrow windows and does not reserve space for a missing image.
- **Cancel** is the default action of the confirmation.
- Invalid or corrupt archives are rejected before anything is imported.
- When the name is taken, the save is imported as `SaveName(1)`, `SaveName(2)` and so on.
- New archives store game files as `Mode/SaveName/file`. Version 1 archives from older
  versions, with files at the root, can still be read.
- Files keep the times they had in the save, so an imported save's **Last played** is
  when it was last played, not when it was imported. `players.db` takes the exact time
  from the manifest; archives made before this keep their other files' export times.
- The screen refreshes before completion is shown. If the refresh fails, that is
  reported separately from an import failure, so the user does not import the same files
  again.

**Export** of the current save (*live export*) creates no backup revision. Leave the game
before using it; see [limits](#limits).

## Deletion

Save rows and backup-revision rows have delete actions. The current-save row in the
details does not repeat the save list's delete action.

The confirmation names the exact target and scope, has **Cancel** as the default, and
explains that deleting a source save is permanent.

**Deleting a save** removes its exact `SavesRoot/Mode/Name` folder and marks that save's
backups deleted. It is blocked by:

- activity, or a stale or unknown state
- conflicting operations
- a relevant projector failure

**Deleting a revision** is allowed for any revision, including the latest or the last
visible one. A marked revision disappears at once from the restore and export choices.

Other saves and previously exported archives are not affected by either kind of
deletion.

## Performance page

Recording, the frame graph and the results are described in
[performance recording](profiler.md). The rules that concern the screen:

- The record button is enabled only when exactly one game is running (or the count is
  not yet known); its tooltip says why otherwise. Pressing it with no game is reported
  as information, not as a failure.
- The results list has headings like the table beside it. The heading over the
  numbers explains, on hover, what they measure; on the Lua tab it carries the total
  for all scripts. Counts carry a unit so they are not read as shares.
- The copy button copies what the page shows, as text.

## Game extensions page

Each extension has an expander, expanded at first when it is the only extension. Its
extension-wide switch stays at the right of the header. In the expanded rows,
descriptions are on the left and the independent feature switches on the right. The
vehicle options (acceleration and shifting, reversing, precise keyboard steering, light
around the vehicle) and the version-range override are inline; the options start on
while the extension itself starts off. Developer tuning stays in TOML. See
[game extensions](game-extensions.md).

- Switches show the saved preferences. A separate status says whether the game's JVM
  has applied them (see [settings revision](glossary.md#settings-revision)).
- Settings stay editable while the game is offline or a change is waiting to apply, and
  the UI explains why it is delayed.
- Refreshing and saving keep expansion, scroll and focus.
- A confirmed failure reverts only the matching saved request (compare-and-swap).
- `RestartRequired` stays locked until the game restarts
  ([restart required](glossary.md#restart-required)).
- Detailed revisions, hashes and transition reasons belong in the logs, not on this page.

For checks in a real game, see the [vehicle test guide](../contributing/e2e-vehicle-drivetrain.md).

## Limits

- **Live export is not a snapshot.** It is not an atomic copy of a running game, and it
  stops if files change while it is being written. Use it after leaving play.
- **Deleting a save is permanent.** It does not use the Recycle Bin.
- **Files and database cannot change together.** An operating-system failure during a
  save deletion may leave some files deleted. If the database commit fails afterwards,
  the deletion is reported as a partial failure.
- **Deleting a revision frees no space at once.** Physical cleanup, and keeping any
  internal incremental base another revision still needs, are left to maintenance
  ([housekeeping](repository-housekeeping.md)).
- **The app never changes a security setting itself.** It only reports blocked
  components and opens the Windows Security page.
- **The UI locks are not the last line of defence.** Named mutexes in the CLI and the
  runners still stop conflicting work started outside the app.

## How it works inside

### Where the data comes from

Progress reaches the screen through `OperationView` along this path:

```text
telemetry.db → TelemetryProjectionHost → reducers
            → RevisionedViewStore → ViewModel → WinUI
```

- Producers add up progress per file and publish the latest snapshot at intervals,
  plus a final snapshot at each phase change and at completion.
- The UI tells apart these telemetry health states: Waiting, Healthy, Stale, Disabled,
  Unreadable and UnsupportedSchema.
- Whether work is running, and which buttons stay locked, comes from the
  [workflow](glossary.md#workflow) and process state, not from telemetry. Missing
  telemetry must never unlock an active operation.

For the Logs page, `TelemetryProjectionHost` feeds `LogInboxStore`. `LogsView` carries
updates and the unread-problem state, and `ReadPageAsync` supplies the list. The filter
conditions and page snapshots are part of the cache key.

### Views

| View | Responsibility |
| --- | --- |
| `SettingsView` | Effective settings and validation errors |
| `SaveListView` / `SaveDetailView(save_id)` | Current saves and backup revisions |
| `ScheduleStatusView` | Enablement, target, mode, next due time, last result |
| `OperationView(operation_id)` | Execution state, progress, telemetry health |
| `MetricsView(producer)` / `TelemetrySourceView` | Retained metrics and producer health |
| `LogsView` | Normalized logs and structured payloads |
| `ProjectorHealthView` | Projector failures and action-safety policy |

Each view has a session-local `view_revision`. It goes up only when the snapshot changes
in a meaningful way. Selection, hover, focus and countdown rendering do not change
projection revisions.

### Operation scopes

Each operation claims a main scope, which decides what it conflicts with:

| Operation | Main scope |
| --- | --- |
| Automatic/manual backup, including maintenance | RepositoryWrite |
| Revision restore | RepositoryRead + SaveWrite |
| Backup archive export | RepositoryRead |
| Current-save export | SaveWrite |
| Archive import | SaveWrite |

The CLI and runner named mutexes remain the final protection against concurrent runs
started outside the app.

### Restore

Restore looks up the revision's numeric `source_id` to find its repository `source_key`,
and passes that logical save key to the CLI's `--source-id`. Original and imported saves
have independent revision numbering.

### Refresh after import and deletion

After a successful import, the existing state runner collects at once. It keeps its
global run numbering ([run index](glossary.md#run-index)) and the `StateCollection`
mutex. A bounded number of retries on *Busy* comes first, then the state, backup and
detail projections run one after another.

Deleting a save uses the same recollection path. Deleting a revision refreshes the
relevant views without collecting.

### Live export safeguards

The archive worker takes SaveWrite, lists the save's paths, lengths and modification
times, and compresses the files straight from the save into a temporary archive. It
reads each file only up to the length it was listed with. Once the archive is complete
it lists the save again and compares, before replacing the final output. There is no
intermediate copy of the save: it would write each of the save's many small files a
second time and make export several times slower, without adding a check.

- It rejects reparse points, and an output location inside the save.
- It aborts if files change: a file that is longer or shorter than listed when it is
  read, or any difference in the second listing.
- On failure, an existing output file is kept.
- Live-export manifests use `sourceId=0` and `revision=0`.

Exporting a backup revision works the same way without the save: each stored object is
read from the repository, verified, and written straight into the temporary archive.
Nothing is restored to disk on the way. A damaged object fails the export, and an
existing output file is kept. Like a restore, the export holds the repository's
[writer lock](glossary.md#writer-lock) while it reads, so background cleanup cannot rewrite
or remove a pack underneath it. If cleanup or a backup holds the lock, the export ends as
*busy* and can be started again.

### Deletion safeguards

Before a save folder is removed, these are rejected: a path that escapes the saves
folder, reparse points, a missing `players.db`, and files known to be locked or
read-only.

The repository side of a save deletion:

1. The deletion marks are prepared under the [writer lease](glossary.md#writer-lock).
2. The save folder is deleted.
3. The marks are committed, or rolled back if the folder deletion failed.

A revision is deleted with `MarkRevisionDeletedAsync`, under the writer lease and the
operation mutex.

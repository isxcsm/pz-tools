# UI contract

[Documentation index](../README.md)

The rules to keep when changing the app's screens in [src/PzTools.App](../../src/PzTools.App). What each screen
shows to the player is in the [reference](../reference/settings.md) and the [guides](../guides/getting-started.md);
this page is about how the screens are built and what a change must not break. Terms are in the
[glossary](glossary.md).

## Window and navigation

[MainWindow](../../src/PzTools.App/MainWindow.xaml.cs) holds one
[MainWindowShell](../../src/PzTools.App/MainWindowShell.xaml), on a Mica backdrop with the content drawn into the
title bar (the top 32 pixels are the drag region). When the backup or saves folder changes, the app replaces the
whole shell with a new one, because a shell owns the view subscriptions and revision cursors of one `AppHost`.
Anything the window needs on every shell (closing tooltips on a click or a key, for example) is attached by the shell,
not the window.

The navigation pane lists **Home**, **Save manager**, **Performance**, **Game extensions** and **Logs**, with
**Settings** at the bottom. The pane is 248 pixels wide and folds to its icons when the window is narrower than 900
pixels. It never hides completely and has no toggle button. While it is folded, the cards, the next-backup line and the
update line are hidden, and a newer release shows as a dot on the **Settings** icon. The **Logs** item carries a
badge with the number of unread problems.

Every page is created once and stays in the tree. Navigation only changes which one is visible:

- The Save manager is never collapsed. While another page shows, it is transparent, not hit-testable, disabled and
  hidden from screen readers, so its rows, selection and scroll position survive. Do not replace this with
  `Frame.Navigate` or by collapsing it ([MainWindowShell.Navigation.cs](../../src/PzTools.App/MainWindowShell.Navigation.cs)).
- Opening a page does not start, stop or restart background work. Settings, Game extensions, Logs and Performance
  refresh their own data when shown.
- The page change fades out in 83 ms, then fades in over 167 ms while the content rises 20 pixels over 250 ms, on
  the content area only. With Windows animations turned off it is immediate. Several quick selections collapse into
  one change.

Pages show prepared views from `RevisionedViewStore`, read with `ReadIfChanged` and a revision cursor per view. They
do not read telemetry or worker output themselves. Two pages read stored data of their own, off the UI thread: Logs
pages through `logs.db` with `AppHost.LogInbox.ReadPageAsync`, and Performance opens recording files with
`ProfileRecording.Load`. Home reads no view at all: the shell builds its status rows with
[HomeStatusSource](../../src/PzTools.App/HomeStatusSource.cs) and hands them over.

## The sidebar

The pane's footer is one column, top to bottom:

| Place | What | Built by |
| --- | --- | --- |
| 1 | Operation and result cards | `ApplyOperations` from `OperationCardStack` |
| 2 | Cards that need attention | `AttentionCard` elements, one `Apply*` method each |
| 3 | The next-backup line | `UpdateCountdown` |
| 4 | **Get new version {0}**, when a newer release exists | `ApplyUpdate` |

Above the menu are the logo with the app name (drawn over the pane header) and the **Buy me a coffee** button.

### Next-backup line

Always shown while the pane is open. Its text comes from
[ScheduleCountdownPresentation](../../src/PzTools.App.Core/ScheduleCountdownPresentation.cs), which only chooses words
and never changes the schedule. Every message and when it shows is listed in
[backups](../reference/backups.md#the-next-backup-line). The first matching condition wins, in this order: scheduler
view not loaded, game not running, automatic backups off, restart required, clock fallback, skipped interval, main
menu, loading, character dead, then the holds of the pause-aware schedule (two games, state unknown, no world,
sleeping, paused) and finally the countdown. A remaining time shows on a second line as **{0} remaining** (mm:ss) only
with a countdown or a held time.

A held time is dimmed and blinks once a second (opacity 1 and 0.35, stepped by the countdown timer, not by a
composition animation, which cost about 3% of a core). It does not blink with Windows animations off.
**Checking game status** replaces the previous text only after it has lasted three seconds
(`CountdownDisplayStabilizer`), so starting the app or the game connecting does not make the line flicker. The line
assigns its text only when it changed: each assignment makes the window draw a frame, every second, even minimised.
How the schedule itself behaves is in [game-aware backup timing](runtime-pause-backups.md).

### Operation and result cards

There is one card per piece of work as the user sees it, not one per process
([OperationCardStack](../../src/PzTools.App.Core/OperationCardStack.cs)):

- The scheduler, runner and worker of one backup share its run index and one card.
- All background cleanup processes share one card, shown as working while any of them works.
- Work the user starts first shows an app placeholder card (`StartLocalOperationProgress`). The worker's own record
  takes it over once it reports. After the placeholder's result has expired, the worker's record of the same work
  never comes back as a second card (`RetiredWork`).
- An action that runs no worker (a rename, a backup deletion, a setting that could not be saved, a refusal) reports
  through `ShowSidebarNotification`, as a card with the user's other work. There is no other place for action results.

**Order.** Cards stack in three tiers: background cleanup on top, then automatic backups, then the user's work (manual
backup, restore, export, import, character recovery, save deletion, performance recording and action results).
Within a tier a newer card enters at the bottom, next to the attention cards. When more than four cards would show,
finished cards leave first, top tier and oldest first. Running and waiting work is never removed. The menu items keep
the height they need; finished cards that do not fit in the room left are hidden by the same rule (`FitOperationCards`).

**Lifetime.** Running work stays. A finished card expires on its own timer, even if no new projection arrives:

| Outcome | Lifetime |
| --- | --- |
| Success, no change, postponed cleanup | `success_card_seconds` |
| Anything else (failure, partial result, cancelled, skipped) | `failure_card_seconds` |

Both are `[runtime]` keys of the app; their defaults and ranges are in
[advanced settings](../reference/advanced-settings.md#app). The rule is `OperationCardLifetime.Of`, shared by the
projection and the app. While the pointer rests on the cards, finished cards stay in place; they leave one second
after it moves away.

**Content.**

- Title on the left in normal weight, percentage on the right while running. Below the bar, a step on the left and the
  amount (*4.5 / 16.0 MB* or *3 / 12*) on the right, each one line, trimmed with an ellipsis, so the card keeps its
  height. Only two steps are named, because they explain a wait: **Saving the game** before a backup, and a
  recording being converted after it stopped. While a total is unknown, the step line counts the files found so far.
  When progress cannot be read, the bar runs without numbers.
- A finished card is titled with its work alone, and an icon gives the outcome: a check for success or no change, a
  warning sign (red for failure, amber for a partial result), an information sign for cancelled, skipped or postponed
  work. A plain success is that one line. A waiting card is titled *{work} · Waiting*.
- The line under a failure, a partial result or a *busy* refusal is shown whole. Any other line shows at most two lines
  with the full text in a tooltip; write those messages to fit two lines in every language. A worker's error code
  never reaches the screen: a failed worker card says **Failed. Check the logs.** unless the app has a sentence for
  it (`ExplainOnOperationCard`, `UserFacingError`).
- Report a failure once. `RunWithProgressAsync` puts a failure on its own card and throws `ReportedOnCardException`,
  which `ShowActionError` ignores.
- A failure or warning raised through `ShowSidebarNotification` is also written to the logs as unread
  (`RecordActionIssue`), so a card that has expired never takes a problem with it. Worker failures are logged by the
  worker.

**Background cleanup** shows a card only while it is visibly working: at once when it announced real work, otherwise
after it has run for two seconds. A routine check with nothing to do shows none. Cleanup that gave way to a backup or
the game finishes as *postponed* (**Will tidy up next time.**) with the success lifetime. A failure always shows.

### Cards that need attention

A condition the user should know about or act on. These cards sit below the operation stack, directly above the
next-backup line, and never expire. Each leaves when its condition clears, or through its ✕. All share one shape,
[AttentionCard](../../src/PzTools.App/AttentionCard.xaml.cs), in the order below (the XAML order in `InteractiveCards`):

| Card (English title) | Action | Leaves |
| --- | --- | --- |
| **PZ Tools files are not intact** (the app folder differs from the published files; see [files and folders](../reference/files-and-folders.md)) | **Open download page** | ✕, for this run |
| **Could not load the save list** / **backup list** / **save details**, with **Trying again.** | — | When that part loads again; ✕ keeps it closed until everything has loaded once |
| **Blocked by Windows Security** | **Open settings** | When nothing is blocked; ✕ keeps it closed until a different set of components is blocked |
| **Not connected to the game**, or **PZ Tools was updated** / **Restart the game.** | — | When the game can be read again; ✕ for this outage. The restart card has no ✕, because automatic backups wait for the restart |
| **Game memory back to {0}** / **A game update undid the setting.** | **Apply {0} again** | When the game's file has the chosen value again; ✕ until the chosen or the file's value changes |

- **Blocked by Windows Security.** The app starts each worker executable with a no-op `--probe` argument, and the
  bundled Java with `-version`, at startup, then every five minutes while something is blocked and every six hours
  otherwise ([ComponentLaunchCheck](../../src/PzTools.App.Core/ComponentLaunchCheck.cs)). Which files were refused is
  in the logs, not on the card. **Open settings** opens the Smart App Control page of Windows Security
  (`windowsdefender://smartapp/`). The app changes no security setting itself.
- **Not connected to the game.** The line names a launch option that turns the connection off when the attach found
  one (**A game launch option is blocking the connection.**); otherwise it says what backups do meanwhile. See
  [saving the game before a backup](game-bridge.md).
- **Could not load.** A projection failure that clears within ten seconds (a file briefly locked) shows nothing. Only
  one load card shows: the save list if it has failed that long, else the backup list, else the details.
- **Game memory.** See [game memory](game-memory.md).

How an attention card behaves:

- The ✕ is invisible until the pointer is on the card or the keyboard is inside it. It is still in the Tab order, and
  focusing it shows it. `CanClose = false` removes it.
- The card's automation IDs are its `x:Name` plus `Close` and `Action` (for example `GameLinkCardClose`), for UI
  scripts and screen readers.

To add one: put an `AttentionCard` in `InteractiveCards` at its priority, write an `Apply*` method that sets
`Title`, `Message` and `ActionLabel` from the resources and its `Visibility`, then calls `UpdateInteractiveCards`.
Call that method again from `ApplyLocalizedText` and call the card's `Localize()` there, so a language change
redraws it. `InstallCard` and `GameMemoryCard` are not handled there yet: after a language change they keep the old
language until their state changes. Add a preview key to [MainWindowShell.CardPreview.cs](../../src/PzTools.App/MainWindowShell.CardPreview.cs):
developer builds list it under Settings > Advanced, and `PZTOOLS_PREVIEW_CARDS=blocked,update` (or `all`) shows cards
from startup. Published builds compile none of the preview code.

### Writing a card

Cards are read by players, in a pane about 200 pixels wide. Every card, notice and error message follows these
rules, in English and in every translation:

- **A card only when there is something to know or do.** A passing state the user can do nothing about gets no card;
  one that lasts says precisely what is wrong. Status and results live in the pane's cards, not in banners on a page.
- **Title, at most one line, at most one action.** The title says what happened, without a final period. The line
  says what to do or what it means, as a sentence. An action is the grey strip across the card's bottom with an arrow.
  Nothing needed is hidden in a tooltip or behind a click.
- **What happened first, then what to do.** *PZ Tools was updated* / *Restart the game.*, not the other way round.
  The line does not repeat the title.
- **The player's words.** No technical terms, file names or inner workings, and no vague words (*some
  information*). Names the user must find are kept: a Windows setting, a menu or setting of the app, a key, a version.
- **Nothing irreversible is suggested.** An action opens the place to decide, no more.
- **Say what happened, not what was promised.** A revival reports *Character revived. Items recovered: 7.*, not what
  the confirmation already said.
- **"The save is unchanged"** only after work that could have changed a save (recovery, restore, deletion), and briefly.
- **"Check the logs"** ends a failure whose reason the card cannot give.

The look is shared in [CardStyles.xaml](../../src/PzTools.App/CardStyles.xaml), for cards in XAML and in code alike:
font size 13 for the title, 12 for everything else (as the next-backup line), 12 × 10 pixels of padding, 6 between
cards. Titles use the normal weight and are set apart by size and colour, because the default Korean font has no
semibold and would draw it fully bold. The action strip's margin is the card's padding turned outward; change one, change the other.

### Update line

A newer release, while **New version notice** is on in Settings, shows as one grey line under the next-backup line, next
to **Settings**. Pressing it opens the release page; its tooltip is the page's address. It stays until the app is
updated or the notice is turned off.

## Save manager

The page is part of the shell ([MainWindowShell.xaml](../../src/PzTools.App/MainWindowShell.xaml)), not a page of
its own. How export, import and the deletions work underneath is in [archives and deletion](archives-and-deletion.md).

### Layout

A wide page shows the save list (420 pixels, at least 320) beside the details. Below 860 pixels the two show one at a
time, and the details get **Back to list**. The header buttons move under the title below 390 pixels (list) and 520
(details). Below a details width of 520 the bottom-right buttons stack.

While a newly selected save loads, the previous details stay on screen, a thin progress bar appears after
`DetailProgressDelayMs`, and the bottom buttons keep their previous state so they do not flicker off and on. Their
handlers still refuse while loading.

### Save list

Header: **Save manager** and **Import archive**. Each row shows:

- the thumbnail (96 pixels), with a green play overlay while the save is being played and the observation is fresh, and
  a skull when the character is dead
- the save name (tooltip with the full name), the game mode, and the last-played time or **No play history**
- a delete button (**Delete save {0}**)

Placeholders in the list's place: **Loading saves…**, **No saves found**, **Could not load the save list.**
Selection is kept by save ID across refreshes; the list is reconciled in place, never rebuilt.

### Current save and backups

The details list is headed **Current save and backups**, with **Delete all backups**. The first row is
**Current save**, selected when a save is opened; the save's backups follow, highest revision first. A refresh keeps
the selected row.

| Part of the row | Current save | Backup |
| --- | --- | --- |
| Name | **Current save** | The backup's name, editable |
| Second line | **Character: {0}** | **Character: {0}** |
| Third line | **Survival time: {0}** | **Survival time: {0}**, with a spinner while it is still being read, and a tooltip when reading failed |
| Time | **Last played: {0}** (the save's file time), or **Last played: unknown** | **Backed up: {0}**, when the backup was made |
| Right column | **Save folder** | The backup's size |
| Top right | — | **Automatic backup** for an automatic backup |
| Bottom right | **Version {0}** when known, with a tooltip saying where it comes from | **Version {0}** when the game was running at backup time |
| Button | **Heal character** | **Delete {0}** |

A backup row does not show a last-played time. The current save's version is, in order: the version of the game
running this save now; the last version PZ Tools saw it loaded with (`save-versions.json` in the app data folder); the
version of its newest backup that recorded one. A save file itself records no game version.

**Names.** A backup whose stored name is empty or still a default name (`LanguageCatalog.IsDefaultBackupName`) is
shown as *Manual backup 12*, *Automatic backup 12* or *Backup 12* in today's language. **Rename {0}** (the pencil)
turns the name into an inline box of at most 100 characters. Enter or leaving the box saves, Escape cancels, an empty
box saves the default name, and **Clear name** empties it. The rename button follows the same rule as the delete
button of that backup. A failed rename puts the old name back and reports on a card.

### Actions and when they are available

"Busy" below means `HasConflictingOperation`: the page is already running one of its own actions, including one whose
dialog is open, or any operation in the operations view is running, except a performance recording, which holds no
save and no repository.

| Control | Available when | Reason shown when not |
| --- | --- | --- |
| **Restore** | A backup row is selected; the save is not being played; the state and backup views loaded; not busy | **Select a backup in the list to restore it**, or the stop-playing message |
| **Export ZIP** | Current save: not being played, state view loaded. Backup: backup view loaded. Not busy | The stop-playing message for the current save |
| **Back up now** | A save is selected; details not loading; not busy | — |
| **Import archive** | Not busy | — |
| **Delete all backups** | The save has backups; backup view loaded; not busy | Tooltip names the save |
| **Delete save {0}** | Fresh observation, not being played, state view loaded, not busy | **The save cannot be deleted while playing.** … |
| **Delete {0}**, **Rename {0}** | Backup view loaded; details not loading; not busy | — |
| **Heal character** | Current save row; fresh and not being played; state and backup views loaded; not busy | **Cannot heal while playing.** … |

Each click handler checks these conditions again, because the button state can lag, and again after its dialog
closes, because the world may change while the dialog is open. The page sets its busy flag before it shows a
dialog: WinUI allows one `ContentDialog` at a time and throws on a second.

A tooltip cannot be shown on a disabled button, so **Restore** and **Export ZIP** sit in transparent `Border` hosts
that carry the tooltip, and the button carries the same reason as `AutomationProperties.HelpText`.

These locks are a convenience. Named mutexes in the workers and the CLI stop conflicting work started outside the app.

### Import and export

- **Import archive** opens a file picker (.zip, .pzsave), then a dialog that inspects the archive with a progress bar.
  **Import** stays disabled until the inspection is done, and closing the dialog cancels it. The preview is the
  window's width less 96 pixels, at most 640. It puts the thumbnail beside the details when that is at least 480
  pixels, above them otherwise, and reserves no space for a missing image.
- After a successful import the app collects the save state again before it shows completion. If that refresh fails,
  the card says **Done, but the list may update late. Do not run it again.**, so the user does not import twice.
- **Export ZIP** suggests `<mode>-<save>-current.zip` or `<mode>-<save>-r<revision>.zip`. Exporting the current save
  makes no backup and fails if the save changes while it is written; an existing output file is replaced only by a
  finished archive ([ZomboidArchiveService](../../src/PzTools.Zomboid.Archive/ZomboidArchiveService.cs)).
- Pickers are the Windows App SDK pickers, created with the window's `AppWindow.Id`; they work while the app runs as
  administrator.

## Other pages

- **Home.** Title and one line with the illustration, three status rows (game, the save being or last played with its
  last backup, the vehicle extension), four feature cards (backup and restore, character recovery, performance, game
  extensions) and a footer with links, the selectable version and the unofficial-tool notice. Korean text gets a word
  joiner between the syllables of each word (`HomePage.KeepWords`), so a narrow window breaks only at spaces.
- **Settings.** `SettingsExpander`s, in order: **Version**, **Appearance and behavior**, **Folders**, **Backup**,
  **Game**, **Performance**, **Hotkeys**, **Advanced**. **Version** and **Advanced** start collapsed. What each
  setting does is in the [settings reference](../reference/settings.md).
- **Performance.** The record button reads **Start recording** while idle and is enabled when exactly one game is
  running or the count is not known yet; otherwise its tooltip says why. While recording it reads **Stop recording**
  and is enabled once the game has confirmed the recording. See the
  [Performance page reference](../reference/performance-page.md) and [performance recording](profiler.md).
- **Game extensions.** One expander per extension, expanded at first when it is the only one. Refreshes update the
  existing controls in place, so expansion, scroll and focus stay. A settings file that cannot be read or written is
  reported in an `InfoBar` on this page, an exception to the card rule. (The Performance page's few-samples
  `InfoBar` is not one: it describes the recording on screen.) See [game extensions](game-extensions.md).
- **Logs.** Filters combine and apply after a short pause in typing (`LogFilterDebounceMs`), or at once on Enter or a
  calendar choice; opening the date picker applies nothing. Active filters show as chips with **Clear all**. Column
  widths are measured from the current language's level names and time formats (`LogColumns.Fit`). What the page
  shows is in the [Logs page reference](../reference/logs-page.md); how entries are recorded is in
  [telemetry](telemetry.md).

## Dialogs

- Every confirmation is a `ContentDialog` with **Cancel** as its close button and `DefaultButton = Close`, so Enter
  never confirms a destructive action by accident. This holds for delete save, delete backup, delete all backups,
  restore, import, heal, exit, and the dialogs on the Settings and Performance pages.
- The body names the exact target: the save name and folder, the backup name, the number of backups.
- A dialog whose content can grow (heal with several characters) puts it in a `ScrollViewer` limited to the window's
  height.

## Tooltips

Use [AppToolTip](../../src/PzTools.App/AppToolTip.cs) (`local:AppToolTip.Tip` in XAML, `AppToolTip.SetTip` in code),
not `ToolTipService` or a `ToolTip` of your own. It reproduces Windows' own timing for tips opened by hand:

- 350 ms of rest before the first tip. Within 500 ms of a tip closing, or while one is open, the next opens at once.
- Leaving and coming back within 200 ms keeps the tip open, so a one-line element does not replay its appearance.
- 20 pixels from the element for the pointer, 12 for keyboard focus. Keyboard focus opens the tip; touch does not.
- One tip waits at a time: entering a child cancels its parent's pending tip, and the innermost element wins. When
  the pointer leaves a child for its parent, the parent's tip shows again.
- A press closes the tip, and it stays closed until the pointer has left. The shell also closes the open tip on any
  pointer press or key anywhere, and the window does when it is deactivated or closed.
- No tip opens while a flyout or menu is open that the element is not part of.
- Setting the text to null or empty removes the tip. Setting the same text again changes nothing on screen.

Information the user needs is never only in a tooltip.

## Theme

The theme chosen in Settings is applied as `RequestedTheme` on the window's content. Application resources still
resolve in Windows' theme, not the app's, so a brush read in code from `Application.Current.Resources` can be the light
colour on a dark page. Instead:

- Set colours through a style whose setters use `{ThemeResource …}` (as [CardStyles.xaml](../../src/PzTools.App/CardStyles.xaml)
  does); the element resolves them in its own theme.
- For brushes that code needs, read them from collapsed probe elements in the page, as the `ThemeProbes` panels in
  [SettingsPage.xaml](../../src/PzTools.App/SettingsPage.xaml) and [ProfilerPage.xaml](../../src/PzTools.App/ProfilerPage.xaml)
  do. After `ActualThemeChanged`, read them in a queued callback, when the probes have the new theme, and redraw
  whatever code drew with the old brushes.
- Do not read a brush from `Application.Current.Resources` in code. Two places still do, for the secondary text
  colour of the heal dialog's survival line (`CreateCharacterChoice`) and of [RemainsQuestion](../../src/PzTools.App/RemainsQuestion.cs),
  and show Windows' colour when the app's theme differs.
- The title bar's caption buttons get their foreground on `ActualThemeChanged`.

## Text and languages

- Every visible string and every accessible name comes from `Strings/<language>/Resources.resw` through `Localizer`.
  Text or content written in XAML is a placeholder that `ApplyLocalizedText` (or `x:Uid`) replaces.
- A new key goes into every language's file with the same format placeholders; `LocalizationTests` and
  [check-localization.py](../../scripts/check-localization.py) fail otherwise. The languages and the process are in
  [localization](../contributing/localization.md).
- The language changes without a restart. `RefreshLocalization` calls each page's `ApplyLocalizedText` and resets the
  view cursors so every row is formatted again. Text set in code must be set again there, and a property formatted when
  read must raise its change notification on a language change (see `SaveVersionUiItem.SetGameVersion`).
- Format with `Localizer.Culture` and `Localizer.Format`: dates with `"G"` or `"g"`, numbers with `N0`/`N1`, sizes
  with `Units`. The thread's culture can still be the one the app started with. The operation card's amount
  (`ApplyProgress`) still writes `MB` itself instead of the language's unit.
- Assume nothing about length or script. Text wraps or trims instead of relying on a width; widths that must fit are
  measured in the current language. Whole sentences come from one resource with placeholders, never from joined
  fragments, because word order differs. Stored text that was written in another language (default backup names, log
  messages through `Localizer.Translate`) is shown in today's language.

## Threading

- Touch UI elements only on the UI thread. From any other thread, queue work with `DispatcherQueue.Enqueue` and create
  timers with `DispatcherQueue.Timer` from [UiQueue](../../src/PzTools.App/UiQueue.cs). A failure in a raw
  `TryEnqueue` callback or `CreateTimer` tick ends the app without a crash report; `UiQueue` rethrows it where
  `Application.UnhandledException` sees it. `UiQueueSourceTests` fails on any raw call outside `UiQueue.cs`.
- `UiQueue.Timer` repeats unless `IsRepeating` is set to false.
- An `async void` event handler catches every exception and reports it on a card. An exception that escapes it ends
  the app.
- Keep the UI thread free: worker dispatch runs in `Task.Run` (`RunWithProgressAsync`), thumbnails are read off the UI
  thread behind a semaphore (`ThumbnailReadConcurrency`), save deletion runs in `Task.Run` and the UI samples its
  latest progress on a timer.
- After every `await`, check that the result still belongs to what is on screen: the selected save, the current host,
  the same generation counter (`saveListApplyGeneration`, `detailApplyGeneration`). Results for an old selection are
  dropped.
- Idle costs matter, because the app runs for hours in the tray: assign text only when it changed, set a
  `ProgressRing` active only while it is visible, and switch an indeterminate `ProgressBar` off when it is hidden.
  Hidden animations keep running on the compositor.

## Accessibility

- A button with an icon and a label gets its label as `AutomationProperties.Name` (`SetIconContent`). An icon-only
  button gets a name from the resources that includes its target (**Delete save {0}**, **Rename {0}**, **Close**), and
  its reason as `HelpText` when it is disabled for one.
- A page that is not shown is out of the Tab order and out of the screen reader's view (the Save manager host is
  disabled and set to the `Raw` accessibility view).
- Page titles carry `HeadingLevel`. The save list's failure text is a polite live region. Decorative images (the logo,
  the support cup) use the `Raw` view. A composite choice is read as one item: each character in the heal dialog is
  named *name, Dead, survival time*.
- Everything works from the keyboard: the cards' ✕ through Tab, tooltips on keyboard focus, Enter and Escape in the
  rename box.
- Motion follows the Windows animation setting for page changes, the countdown blink, the support button and some
  Performance page motion. The animated selection bars (`AnimatedListSelectionBar`, on the Save manager, Logs and
  Performance lists and the Performance tabs) and the Save manager's row insertion and entrance animations do not
  check it yet.

# Logs page

[Documentation index](../README.md)

The **Logs** page lists what PZ Tools and its background work recorded: backups, restores, ZIP imports and exports,
backup cleanup, revives, performance recordings, and the problems they ran into. Warnings and errors stay unread until
you mark them reviewed. How entries are recorded and given a level is in [telemetry](../design/telemetry.md#the-logs-pages-data).

## The list

| Column | Shows | Clicking the header |
| --- | --- | --- |
| **Number** | The entry's log number, such as `#42`. A dot before it marks an unread warning or error. | Filters by log number |
| **Level** | **Trace**, **Information**, **Warning**, **Error** or **Critical**, in colour. The header shows the lowest level currently shown. | Changes the lowest level shown |
| **Time** | When it happened, by this PC's clock. Resting the pointer on it shows the full date and time. | Filters by time |
| **Event** | What happened, in plain words. Resting the pointer on it shows the whole text. | Filters by activity |
| **Operation** | The number of the operation the entry belongs to, or `—`. A number longer than eight digits is shortened to `#…` and its last six digits; the pointer shows all of it. | Filters by operation number |

The **Time** column is short:

| When | Shown as |
| --- | --- |
| Today | Hours, minutes and seconds, such as `14:05:09` |
| Yesterday | **Yesterday 22:48** |
| Earlier this year | Abbreviated month and day with the time, in the app language's order |
| Another year | The date alone, in the app language's short date format |

The full time, in the tooltip and the details, is the app language's date and time. Neither shows a time zone or a
UTC offset.

| Level | Typical entries |
| --- | --- |
| **Trace** | Routine checks that found nothing to do. Not stored by default. |
| **Information** | Work started and finished, backups saved, cleanup that did something, an automatic backup skipped, work that did not start because other work was running |
| **Warning** | Partial results, cancelled work, a backup made without saving the game first, warnings from actions shown on a card |
| **Error** | Failures |
| **Critical** | Events a component reports as critical |

### Rows and pages

| Rule | Detail |
| --- | --- |
| One row per problem | Warnings and errors with the same operation number are one row. Without an operation number, repeats of the same event from the same source are one row. |
| A grouped row | Takes the highest level of its entries, the time of the latest, and the message of the entry that says most about the failure. **Number** shows that entry's number. |
| Information and Trace | One row per entry |
| Order | Highest log number first |
| Page size | 100 rows. With more than one page, the pager under the list has arrows and page numbers; with more than 8 pages it also has **…**, which opens **Page number** and **Go**. The line below always reads, for example, **1–100 of 1,234**. |
| New entries | Appear at the top while page 1 is shown. Other pages keep the entries they had when you opened them, so nothing shifts while you read. |
| Narrow window | Below 902 pixels wide, the details move under the list. |

| Message in the list | When |
| --- | --- |
| **Loading logs…** | The list is being read |
| **Logs could not be loaded.** | Reading the log failed |
| **No logs match the selected filters.** | A number, time, activity or operation filter matches nothing. **View all logs** clears every filter. |
| **No Warning or higher logs.** (with the level shown) | Nothing at the chosen level or above. **View all logs** appears while the level is above the lowest stored level, which it is when the page opens. |
| **There are no logs to display.** | Nothing is stored. When the lowest stored level is **Warning** or above, the page says **No Warning or higher logs.** instead. |

## Filters

Each column header is a filter. The filters combine: a row shows only when it passes all of them. Changing a filter
returns to page 1.

| Header | What you set | Accepts |
| --- | --- | --- |
| **Number** | A box, **Number** | One number (`42`) or a range from lowest to highest (`40-50`). A `#` before a number and an en dash (`40–50`) also work. Blank removes the filter. |
| **Operation** | A box, **Operation number** | The same as **Number** |
| **Time** | Two boxes, **From** and **Through** | See [time filter](#time-filter) |
| **Event** | A menu | **All**, **Backup**, **Restore**, **Character recovery**, **Archive**, **Performance recording**, **Game status check**, **Backup schedule**, **Backup cleanup**, **Other activity** |
| **Level** | No box | Each click raises the lowest level shown by one step. After **Critical** it goes back to the lowest stored level. |

- A box applies what you type after a short pause (`[runtime] log_filter_debounce_ms`, 180 ms, in the
  [advanced app settings](advanced-settings.md#app)), or at once on Enter. Closing the box keeps the last valid value.
- Text that is not valid shows a message under the box, such as **Enter a whole number or a range from lowest to
  highest.**, and the previous filter stays.
- Each active filter shows as a chip under the headers, such as **Number: 40–50 ×**. Clicking a chip removes that
  filter. **Clear all** removes every filter and sets the level to the lowest stored level.
- The first time you open the page after starting PZ Tools, it shows **Warning** or higher. With the default stored
  level, the chip **Level: Warning or higher** is there from the start. Clear it to see Information entries too.
- Filters stay as you left them while the app runs, and are not saved when it closes. They change only what the page
  shows, never what is recorded or kept.

<a id="time-filter"></a>
### Time filter

The box says **Choose times by this PC’s clock.** It has a **Last 24 hours** button, and a calendar button (**Choose
date and time**) beside **From** and **Through** that picks a date and a 24-hour time.

When no time filter is set, the boxes open filled with the last 24 hours, but nothing applies until you change a box,
press Enter, press **Last 24 hours** or pick a date or time. A pick applies at once.

| You type | Means |
| --- | --- |
| `2026-10-05 14:30` | That minute. In **Through**, the whole minute is included. |
| `2026-10-05 14:30:15` | That second. In **Through**, the whole second is included. |
| `2026-11-01 01:30 -04:00` | That clock time at that UTC offset |
| Nothing | No limit on that side |

The date is year-month-day and the clock is 24-hour. **From** must be at or before **Through**; otherwise the box says
**Enter valid dates and times. The start must be at or before the end.**

### Daylight saving time

| Case | What happens |
| --- | --- |
| You type a time in the hour that repeats when clocks go back, or in the hour skipped when they go forward, without an offset | Refused. The app does not guess which moment you mean. Add the offset, such as `-04:00` or `-05:00`. |
| **Last 24 hours** produces a bound in a repeated hour | The bound is written with its offset, such as `2026-11-01 01:30 -04:00`, so it names one moment |
| The calendar picks a time in a repeated or skipped hour | It writes the time without an offset, which is refused; add the offset by hand |
| Entries from a repeated hour in the list | Two entries can show the same time. Their log numbers give the order. |

## Details

Select a row to see its details. The top card shows **Log number #42**, the message, and the time and activity. Its
buttons:

| Button | Shown | Does |
| --- | --- | --- |
| **Mark this operation reviewed** | The row is unread and has an operation number | See [reviewing](#reviewing-warnings-and-errors) |
| **Mark this alert reviewed** | The row is unread and has no operation number | See [reviewing](#reviewing-warnings-and-errors) |
| **Copy details** (copy icon) | Always | Copies the details as text and shows a **Copied.** card |

### Failure details

Shown when the entry carries information about a failure. Only fields with a value appear.

| Field | Shows |
| --- | --- |
| **Save** | The save involved, as `Mode/Save` |
| **File** | The file involved |
| **Reason** | Why it failed, in the app's language |
| **Failed step** | The step that failed, such as **Copying save files** or **Starting the worker** |
| **Files not cleaned up** | How many files cleanup could not remove |
| **Affected files** | Which files those are, up to 8 |
| **Error message** | The error explained in the app's language. For a warning or error from a card, the card's text; the failure behind the card is the **Original message**, and a settings file it names is the **File**. |

When the entry has no save or file to show and its reason cannot be explained in the app's language, **Reason** says **This error could not be explained here.
See the original message in the technical details.** An old entry without a recorded reason says **This older record
does not contain the detailed failure reason.**

### Related records

Shown when the row groups several entries; the title counts them (**5 related records**). It lists up to the 12
latest, oldest first, as number · time · message, then **7 more** for the rest.

### Technical details

Collapsed until you open it.

| Field | Shows |
| --- | --- |
| **Time** | The full local time |
| **Activity** | The kind of work, such as **Backup** or **Archive import** |
| **Operation number** | The operation number, `0` when there is none |
| **Event code** | The internal event name, such as `run.failed` |
| **Record source** | Which component's record the entry came from |
| **Event ID** | The entry's number within that record |
| **Recording session ID** | The ID of that record |
| **Error code** | The failure's code, or `—` |
| **Original message** | Only when the failure's own words could not be explained: the text as the failing component or Windows wrote it, possibly in Windows' language |
| **Raw record** | The entry's data, with text in every language as written. For a grouped row, every related entry with its log number, local time, event code and data. **No additional details.** when there is none. |

**Copy details** copies, in this order: the log number, the event, the level, the time, the activity, the operation
number (when there is one), **Failure details**, **Related records**, the remaining technical fields, **Original
message** and **Raw record**, each only when it has a value. **Error code** is left out when the page shows `—`.

## Reviewing warnings and errors

A warning, error or critical row is unread until you mark it reviewed. Information and Trace rows are never unread.

| Control | Where | Marks reviewed |
| --- | --- | --- |
| **Mark this operation reviewed** | Details of an unread row with an operation number | Every warning and error of that operation so far |
| **Mark this alert reviewed** | Details of an unread row without an operation number | That alert and its repeats so far |
| **Mark all 3 items reviewed** | Right of the page title, while anything is unread | Every unread row |

- The **Logs** item in the navigation pane shows a badge with the number of unread rows, the same number **Mark all**
  counts.
- A new warning or error in a reviewed operation, or a new repeat of a reviewed alert, makes the row unread again.
- Reviewing changes nothing else. Reviewed and unread entries are deleted alike when the log is full.

## Warnings, errors and the sidebar cards

Cards in the sidebar leave after a few seconds. The log keeps what they reported.

| Card | In the log |
| --- | --- |
| An operation run by a background worker: backup, restore, ZIP export or import, revive, backup cleanup, recording | The worker's own entries, under its operation number. A failure is an unread **Error** row. |
| An action that ran no worker, with an error: a rename, a deletion, a setting that could not be saved, work refused before it started, a failed copy on this page | An unread **Error** row, **<card title> failed.**, with no operation number. **Error message** holds the card's text. |
| The same with a warning | An unread **Warning** row, **Recorded activity for <card title>.** |
| A worker that could not start (a file missing, blocked by Windows) | An **Error** row with **Failed step** **Starting the worker** |
| A success or information card from an action | Nothing is added |

A card that ends with **Check the logs.** means the reason is in the matching unread row. Card lifetimes are set by
`success_card_seconds` and `failure_card_seconds` in the [advanced app settings](advanced-settings.md#app).

Restores and ZIP operations run from the [command line](command-line.md) appear on this page after the app's next
start.

## What is stored

The entries are kept in `logs.db` in the [data folder](files-and-folders.md#the-data-folder).

| Setting | File | Default | Effect |
| --- | --- | --- | --- |
| `[logs] record_minimum_level` | [Advanced app settings](advanced-settings.md#app) | `Information` | The lowest level stored. Lower entries never reach this page, so the **Level** filter cannot bring them back. |
| `[logs] max_entries` | Advanced app settings | 100000 (10000–500000) | Entries kept. When full, the oldest are deleted first, unread ones included. |
| `[logs] display_limit` | `settings.toml` | 1000 (100–10000) | How many of the newest entries the app watches for changes. The list itself pages through every stored entry. The Settings page has no control for it. |

The page's filters are not saved in any file: after each start of the app it shows **Warning** or higher.

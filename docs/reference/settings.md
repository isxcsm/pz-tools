# Settings

[Documentation index](../README.md)

Every setting on the app's **Settings** page, in the order the page shows them. There is
no Save button: a change is saved about half a second after your last edit, and a folder
typed into a box is saved when you leave the box. The TOML files behind **Advanced** are
described in [advanced settings](advanced-settings.md).

Some switches need the running game. While the game cannot be reached, those switches are
locked and their description ends with "Not applied right now because the game cannot be
reached." Your choice is kept and applies again once the game can be reached.

## Version

The section header shows the installed version (for example `v1.2.3`) and one of: **Up to
date**, **New version out: …**, **Not checked yet**, **Checking…** or **Could not check.
Check the internet connection.**

| Setting | Default | What it does | Takes effect |
| --- | --- | --- | --- |
| **Check for updates** | | **Check now** asks GitHub for the latest release. When a newer one is known, **Get it** opens its release page in your browser. Nothing is downloaded or installed by the app. | At once |
| **Download page** | | **Open** opens the releases page in your browser. | At once |
| **New version notice** | On | While on, the app checks about 20 seconds after it starts and then every hour, and shows a newer version in the sidebar. Off stops the automatic checks; **Check now** still works. | At once |

## Appearance and behavior

| Setting | Default | Choices | What it does | Takes effect |
| --- | --- | --- | --- | --- |
| **Language** | Your Windows display language if the app has it (or its nearest variant), English otherwise | The 18 app languages, listed by their own names | Language of the app, of new backup names and of the in-game save notices. Untranslated text appears in English. | At once |
| **Theme** | **System** | **System**, **Light**, **Dark** | **System** follows the Windows light or dark mode. | At once |
| **System tray** | Off | On, Off | On: closing the window hides PZ Tools next to the taskbar clock and it keeps running. To quit, right-click its icon and choose **Exit**. Off: closing the window asks whether to exit. | At once |

## Folders

Each folder has a text box, **Browse** to pick a folder and **Open folder** to show it in
File Explorer. **Open folder** opens what the box shows; a folder that does not exist is
reported, not created.

| Setting | Default | What it is |
| --- | --- | --- |
| **Save folder** | `%USERPROFILE%\Zomboid\Saves` | Where Project Zomboid keeps its saves. |
| **Backup folder** | `%USERPROFILE%\Zomboid\Backups` | Where PZ Tools keeps its backups. |

A new folder is used as soon as it is saved. PZ Tools does not move backups that are
already in the old folder. While a backup, restore or other operation is running, the
change is refused with "Try again when the current work is done." If the new folder
cannot be used, the previous folders are restored and the app says "This folder cannot be
used, so the previous settings are back."

## Backup

| Setting | Default | Range | What it does | Takes effect |
| --- | --- | --- | --- | --- |
| **Automatic backups** | On | On, Off | Backs up the save you are playing at the set interval. When your character dies, automatic backups stop until you start a new character or revive this one. Manual backups work either way, and turning this off keeps the interval. | At once (saved without the half-second wait). Turning it on starts a new interval. |
| **Backup interval** | 5 minutes | 1–60 minutes | Time between automatic backups. | At once. Changing it restarts the count. |
| **Delay scheduled backups while paused or asleep** | On | On, Off | While the game is paused or your character is asleep, the remaining time stops and resumes when you play again. Off: backups run at every interval regardless. If the game cannot report sleep, only pausing applies. Needs the game. | At once |
| **Automatic backups to keep** | 20 | 1–100 | Keeps this many of the newest automatic backups of each save and deletes older ones. Manual backups are not counted and are not deleted by this setting. | For each save, right after its next automatic backup. Disk space comes back later; see [Backups](backups.md#when-disk-space-comes-back). |
| **Back up when the character dies** | Off | On, Off | Makes one backup right after your character dies. Available only while **Automatic backups** is on. Needs the game. | At once |
| **Save game before backup** | On | On, Off | Saves the game right before each backup so it holds your latest progress. The game may hitch for about half a second. Off: progress since the game last saved is left out of backups, and the card turns to a warning colour. Needs the game. | From the next backup |
| **In-game save countdown** | On | On, Off | Before an automatic backup saves the game, shows a countdown above your character from 5 seconds before, then the result. Off: the game is still saved, without the notices. A backup started from the app saves at once and never shows them. Available only while **Save game before backup** is on. Needs the game. | From the next backup |

## Game

The game's own launch settings. They are written into the game's
`ProjectZomboid64.json` in the game folder, not into PZ Tools' settings.

| Setting | Default | Choices | What it does | Takes effect |
| --- | --- | --- | --- | --- |
| **Game memory** | **Game default (…)**, the game's own value | 4, 6, 8, 12, 16, 24 or 32 GB, up to half of this PC's memory. 6 GB is marked **(recommended)** on a PC with 16 GB or more, 8 GB on one with 32 GB or more. | The most memory the game may use. Give it more if it stutters often with many mods. | From the game's next start. A game started from a `.bat` launch script sets its own memory and ignores this. |

While the list is open, the size the running game was started with is marked
**· running**. The card says when the game folder was not found (start the game once),
when the game's file is not as expected (it is left alone), or when a game update undid
your choice (choose it again). See [more game memory](../guides/more-game-memory.md).

## Performance

The game can keep its last few minutes of performance data, so a stutter can be saved
after it happened. See [find a laggy mod](../guides/find-a-laggy-mod.md).

| Setting | Default | Range | What it does | Takes effect |
| --- | --- | --- | --- | --- |
| **Keep the last minutes** | Off | On, Off | While on, the game keeps its last few minutes whenever it runs. Standard mode costs the game almost nothing. | At once |
| **Mode** | **Standard** | **Standard**, **Detailed** | **Detailed** shows more but slows the game by about 20% for as long as it is on. | At once |
| **Length (minutes)** | 2 | 1–10 | How many minutes are kept. A longer window costs the game the same, only more disk. | At once |

## Hotkeys

Key combinations for app actions that also work while the game has focus. While PZ Tools
runs, a combination set here is taken from every other program. Each press answers with a
Windows sound and a short note over your character's head; both can be turned off in
[advanced settings](advanced-settings.md#app).

| Action | Default key | What it does |
| --- | --- | --- |
| **Save last minutes** | `Ctrl+Shift+F9` | Saves the minutes the game has kept as a recording. Its key is taken only while **Keep the last minutes** is on. |
| **Start/stop performance recording** | None | Starts a recording in the mode set on the Performance page; press again to stop it. |
| **Switch recording mode (Standard/Detailed)** | None | Switches the next recording between Standard and Detailed. A recording under way keeps its mode. |
| **Keep last minutes on/off** | None | Turns **Keep the last minutes** on or off. |
| **Manual backup** | None | Backs up the save you are playing, right away. |
| **Automatic backups on/off** | None | Turns **Automatic backups** on or off. It stays that way until you change it again. |
| **Show status** | None | Shows the time to the next backup, the last backup and what is being recorded, over your character. |

To set a key, click the action's key button and press the combination; **Esc** cancels.
The button beside it clears the key. A combination is refused when:

| Message | Why |
| --- | --- |
| "Press it with Ctrl or Alt." | Letters, digits and other typing keys need Ctrl, Alt or Win. F1–F24, Pause and Scroll Lock may be used alone. |
| "This key cannot be used." | Only letters, digits, F1–F24, the number pad, arrows, Insert, Delete, Home, End, Page Up, Page Down, Pause and Scroll Lock can be used. |
| "Already used by another action." | Each combination can belong to one action. |
| "Used by another program." | Another program holds it. A key set earlier that another program has since taken shows this in its description. |

Hotkeys take effect at once.

## Advanced

| Setting | Button | What it does |
| --- | --- | --- |
| **Open configuration files** | **Open folder** | Opens `%LOCALAPPDATA%\PzTools\config`, which holds the advanced settings files. |
| **Apply changes** | **Apply settings and restart** | Checks the edited files and restarts the app. Any running operation must finish first. |
| **Reset advanced settings** | **Restore default settings** | Keeps a copy of the current files, restores the advanced defaults and restarts the app. The settings on this page, your saves and your backups are not changed. |

What the files contain and how applying works is in
[advanced settings](advanced-settings.md).

## Where settings are stored

The choices on this page are kept in `%LOCALAPPDATA%\PzTools\settings.toml`. PZ Tools
rewrites the whole file each time a setting changes, so edit it by hand only while the
app is closed.

| Section | Keys | Setting |
| --- | --- | --- |
| `[ui]` | `language`, `theme`, `system_tray`, `check_updates` | **Language**, **Theme**, **System tray**, **New version notice** |
| `[paths]` | `saves_root`, `backup_root` | **Save folder**, **Backup folder** |
| `[backup]` | `automatic_enabled`, `interval_minutes`, `pause_periodic_during_game`, `retained_revisions`, `backup_on_death`, `save_game_before_backup`, `game_save_countdown` | The **Backup** section, in page order |
| `[logs]` | `minimum_level`, `display_limit` | Not used by the current Logs page, whose filters last only while it is open |
| `[profiler]` | `rolling_enabled`, `rolling_detailed`, `rolling_minutes` | The **Performance** section |
| `[hotkeys]` | `save_last`, `record`, `record_mode`, `rolling_toggle`, `manual_backup`, `backup_toggle`, `status` | The **Hotkeys** section; `""` means none |

`language` holds a locale code such as `en-US`, `ko-KR` or `ja-JP`. A hotkey that is not a
valid combination is read as none. If two actions have the same combination, the action
listed later in the table above loses it.

Other files beside `settings.toml`:

| File | What it holds |
| --- | --- |
| `update.json` | What the last update check found. Deleting it only makes the next check ask again. |
| `game-memory.json` | Your **Game memory** choice and the game's own value from before it. |
| `config\` | The [advanced settings](advanced-settings.md) files. |

The full layout is in [files and folders](files-and-folders.md).

## Backup names

A new backup is named after its kind and number: **Manual backup 12**, **Automatic backup
13**, or **Backup 14** when its kind is unknown. The name is written in the app language of
the day the backup was made. As long as nobody has edited it, the backup list shows it in
the current app language, so changing **Language** renames unedited backups on screen. A
name you edit is kept exactly as typed. Clearing an edited name gives the backup its
default name back.

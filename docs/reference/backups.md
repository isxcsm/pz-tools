# Backups

[Documentation index](../README.md)

How PZ Tools decides when to back up, what the sidebar says about it, what happens to the
game around a backup, and how long backups are kept. For step-by-step help, see
[Getting started](../guides/getting-started.md),
[Go back to an earlier backup](../guides/restore-a-save.md) and
[Troubleshooting](../guides/troubleshooting.md). The settings themselves are listed in
[Settings](settings.md#backup).

## Kinds of backup

| Kind | Made by | Counted by **Automatic backups to keep** |
| --- | --- | --- |
| Automatic | PZ Tools while you play, at the **Backup interval** | Yes |
| Death backup | PZ Tools, once, right after your character dies (only with **Back up when the character dies** on) | Yes; it is an automatic backup |
| Manual | **Back up now** in **Save manager**, or the **Manual backup** hotkey | No |

A backup holds only what changed since the save's previous backup, but each one restores
the whole save. When nothing in the save changed, no backup is added and the operation
ends with "Nothing changed."

## When automatic backups run

Automatic backups back up the save the game has loaded. The **Backup interval** (default
5 minutes) counts time you actually play, not time on the clock. The countdown runs at
real-time speed; a faster game speed does not make it run faster.

| In the game | Countdown |
| --- | --- |
| A single-player world loaded, unpaused, character awake | Runs |
| Game paused | Holds its remaining time |
| Character asleep | Holds its remaining time |
| A debug tool open over the game (the chunk viewer, for example) | Holds, as when paused |
| Character dead | Reset to a full interval and held until a new character or a revival (see [When the character dies](#when-the-character-dies)) |
| Main menu | Nothing runs. Loading a world starts a full interval |
| Loading a world | Holds |
| Leaving a world | Reset to a full interval |
| Two copies of the game running | Holds until one is closed |
| Game not running | Nothing runs |
| Game running, but PZ Tools cannot read it for about 90 seconds | Follows the clock instead (see [When the game cannot be reached](#when-the-game-cannot-be-reached)) |

With **Delay scheduled backups while paused or asleep** off, the countdown follows the
clock and backups run at every interval, paused or asleep. If the game cannot report sleep,
only pausing holds the countdown, and the setting's description says so.

These start a new full interval:

- changing **Backup interval** or **Delay scheduled backups while paused or asleep**
- turning **Automatic backups** on
- returning to the main menu, or loading another world
- starting PZ Tools

A missed interval does not cause a burst of catch-up backups. With **Automatic backups**
off, no automatic or death backups are made; **Back up now** still works.

## The next-backup line

The sidebar shows when the next automatic backup is due. Where a time is shown, it reads
**mm:ss remaining**.

| It says | Time shown | Meaning |
| --- | --- | --- |
| **Next backup** | Yes | The countdown is running. |
| **Next backup: starting soon** | No | The backup is due and about to start. |
| **Next backup: after the current work** | No | The due backup is running now (saving the game, then copying). |
| **Next backup: waiting** | No | No save is being played, or the schedule is not known yet. |
| **Game paused** | Yes, held | The game is paused. |
| **Character sleeping** | Yes, held | Your character is asleep. |
| **Run only one instance of Project Zomboid** | Yes, held | Two copies of the game are running. |
| **Game at main menu** | No | The game is at its main menu. |
| **Game is returning to main menu** | No | The game is leaving a world: saving it, unloading it and reloading mods. This can take minutes with many mods. |
| **Game is loading** | No | The game is loading a world or something else outside one. |
| **Game starting** | No | The game has just been started and has not loaded yet. |
| **Checking game status** | No | The game's state has been unknown for more than about 3 seconds. Shorter gaps keep the previous text. |
| **Character dead – backups waiting** | No | Automatic backups wait for a new character or a revival. |
| **Skipping this backup** | Yes | The last game save may not have finished. This interval is skipped; backups resume when the time runs out. |
| **Next backup (game not connected)** | Yes | The game cannot be read. Backups follow the clock and still try to save the game first. |
| **Automatic backups after a game restart** | No | PZ Tools was updated while the game ran. Automatic backups wait until the game is restarted. |
| **Game is not running** | No | No game process is running. Shown even when automatic backups are off. |
| **Automatic backups off** | No | **Automatic backups** is off. |
| **Next backup time unknown** | No | PZ Tools' scheduler is not reporting. |

The **Show status** hotkey puts the same time over your character.

## Saving the game before a backup

Project Zomboid writes your progress to disk only when it saves. With **Save game before
backup** on (the default), PZ Tools asks the running game to make its own normal save, then
copies the files. The game may hitch for about half a second. The progress card shows
**Saving the game** during that step. Nothing is installed into the game for this.

| Backup | In-game notices (with **In-game save countdown** on) |
| --- | --- |
| Automatic | A countdown from 5 seconds above your character, then a saving notice, then done or failed |
| Death | No countdown; the saving notice, then done or failed |
| Manual | None. The game saves at once |

PZ Tools starts preparing an automatic backup about 8 seconds before it is due, so the
countdown ends on time. Paused frames and a busy disk can still delay it.

A save of the world you are playing is made only when the game has that save loaded. A
manual backup of a save that is not being played copies its files without contacting the
game.

### When the game cannot be saved

| Situation | Manual backup | Automatic backup |
| --- | --- | --- |
| The save is not being played | Backs up the files on disk | Not made |
| The game cannot be reached (connection fails or times out, the game refuses connections) | Backs up the files on disk and logs "Could not connect to the game; backing up without saving it first." | The same |
| The game is busy with another short request | Retried for up to 10 seconds, then no backup | The same |
| The game refuses the save (multiplayer, a mode without saving, another save loaded, a game build PZ Tools does not support) | No backup | No backup |
| The game was asked to save and gave no clear answer | No backup | No backup, and **Skipping this backup** for one interval |
| PZ Tools was updated while the game ran | Backs up the files on disk | Waits for a game restart |
| Two copies of the game are running | No backup of the save being played | Held |

Once the game has been asked to save, an unclear answer is not treated as permission to
copy: the game may still be writing. When it could not be reached at all, nothing was asked
of it, so the files on disk are what there is.

With **Save game before backup** off, the game is not saved and only what it last saved
itself is backed up. Automatic backups still check with the game that it is not paused and
that the backup is due.

### When the game cannot be reached

If PZ Tools cannot read a running game for about 90 seconds, a **Not connected to the
game** card appears with "Backups continue on a timer. If the game cannot save first, the
files are backed up as they are." Meanwhile:

- PZ Tools tells which save the game has open from its locked files, and shows it as played
  in **Save manager**
- automatic backups follow the clock at the set interval, only for that save and only while
  it is open, and the line says **Next backup (game not connected)**. Opening a save starts a
  full interval, as when the game can be read. At the main menu the line says **Next backup:
  waiting**
- each backup still tries to save the game first; if the game cannot be reached, the files
  on disk are copied
- **Delay scheduled backups while paused or asleep**, **Back up when the character dies**,
  **Save game before backup** and **In-game save countdown** are locked, with "Not applied
  right now because the game cannot be reached." Your choices are kept.

When the game can be read again, the card goes and the countdown returns to play time. You
can close the card with its ✕; it comes back at the next outage.

A game started with `-XX:+DisableAttachMechanism` shows "A game launch option is blocking
the connection." at once, without the 90 seconds, and backups follow the clock straight
away: that game refuses until it is restarted without the option. See [Troubleshooting](../guides/troubleshooting.md#cards-in-the-sidebar).

### PZ Tools was updated, Restart the game

The game keeps the connection part it got from the previous PZ Tools version until it is
restarted. After an update of PZ Tools, a running game shows the card **PZ Tools was
updated** with "Restart the game." at once, without the 90-second wait. The card cannot be
closed. Until the game restarts:

- automatic backups wait, and the line says **Automatic backups after a game restart**
- a backup you start yourself still runs, without the game's save

Automatic backups do not copy unsaved files here because a restart fixes the problem, and
copies of files from different moments would push good backups out of the kept number.
Updating PZ Tools while the game is closed avoids this.

### Skipping this backup

When the game was asked to save and no usable answer came back, the game may still be
saving. PZ Tools does not ask again at once. It skips one full interval of play, shows
**Skipping this backup** with the time left, and then resumes by itself. Starting PZ Tools
again starts a new full interval instead.

## When the character dies

When PZ Tools sees your character die in the running game, automatic backups stop. The
line says **Character dead – backups waiting**. This keeps the backups from your
character's life from being pushed out of **Automatic backups to keep** by backups of a
dead character.

| Setting | What happens at a death |
| --- | --- |
| **Back up when the character dies** off (default) | No backup. |
| **Back up when the character dies** on | One backup, about a second after the death, whether or not the game is paused. It counts as an automatic backup. |

Automatic backups resume, with a full interval, when you play a new character or the
character comes back to life ([Bring back a dead character](../guides/revive-a-character.md)).

- Each death gives at most one death backup. Turning the setting on afterwards, or
  reconnecting to the game, does not make one for a death that has passed.
- A character that is already dead when PZ Tools first sees it does not count as a new
  death.
- Deaths are read from the running game, never from the save files.
- **Back up when the character dies** can be changed only while **Automatic backups** is
  on, and turning **Automatic backups** off stops death backups too.

## Names, tags and game version

| Backup | Default name |
| --- | --- |
| Automatic and death | **Automatic backup** *n* |
| Manual | **Manual backup** *n* |
| Older backups whose kind was not recorded | **Backup** *n* |

*n* counts the save's backups in order. Automatic backups also carry an **Automatic
backup** tag in the list. The pencil button renames a backup (up to 100 characters);
clearing the name gives the default back. Unedited names follow the app language. See
[Backup names](settings.md#backup-names).

A backup made while the game had that save loaded shows the game's version, for example
**Version 42.20.4** ("Game version when this backup was made"). Backups made without the
game, and older ones, show none.

## How many backups are kept

| Backups | Removed |
| --- | --- |
| Automatic and death backups beyond **Automatic backups to keep** (default 20, range 1–100) | Right after the save's next automatic backup, and by background cleanup once the game is closed; oldest first, per save |
| Manual backups | Not by the count |
| Every backup of a save you delete with **Delete save** | With the save |
| Every backup, manual included, of a save whose folder is gone | By background cleanup, once the folder is confirmed missing |

The count is checked for each save separately, after each of its automatic backups, and for
every save by the background cleanup that runs while the game is closed. Lowering the number
therefore also reaches a save you no longer play, and works with automatic backups off: the
extra backups go once the game is closed and PZ Tools is running. Raising it does not bring
back backups already removed.

A save folder deleted or moved outside PZ Tools, for example from the game's menu or in
File Explorer, looks the same to PZ Tools. So does a save folder you rename. Cleanup checks
about once a minute, but only while PZ Tools runs and the game is closed, and right after
the game exits. Unreadable folders, links and pending restores are not treated as missing. Export a save's backups first if you want to keep them
([Move a save to another PC](../guides/move-a-save.md)).

## Deleting backups

| Button | What it deletes | Allowed |
| --- | --- | --- |
| The bin button on a backup | That backup | When no other operation is running, also while you play |
| **Delete all backups** | Every backup of the selected save; the save stays | When no other operation is running |
| **Delete save** | The save folder and every backup of it, permanently, without the Recycle Bin | When the save is not being played |

A deleted backup leaves the list at once and can no longer be restored or exported. None
of these can be undone.

## When disk space comes back

Deleting a backup, by hand or by the count, does not free its disk space at once. A
background cleanup does it later, per save:

- as soon as 20 deleted backups of a save are waiting, or
- once the oldest has waited an hour

and only when cleanup is allowed to run: while PZ Tools runs and the game is closed (a game
at its main menu counts as running). When you close PZ Tools, one more cleanup runs after it.
If the game is still closing then, that cleanup waits up to 30 seconds for it; a game still
running after that leaves the work for the next time PZ Tools runs. It also gives way to other work. While it works, an operation card shows **Cleaning
up backups**, with steps such as **Removing old backups**, **Removing backups of deleted
saves** and **Reclaiming unused space**.

Space can stay used after that:

- Data a remaining backup still needs is kept, even when it was first written for a deleted
  one. Manual and older backups often need small pieces of many later files.
- The data of a save's newest backup stays after you delete it, because the save's next
  backup builds on it.
- Partly used data files are compacted only while the game is closed, and only with enough
  free disk space. The Logs page then reports "Reclaimed *n* MB of unused backup space."

The batch size, the wait and the compaction limits are advanced settings of the cleanup
worker; see [Advanced settings](advanced-settings.md) and, for how cleanup works,
[Repository housekeeping](../design/repository-housekeeping.md).

## Which games the save before a backup works with

| Game | Save before a backup |
| --- | --- |
| Project Zomboid Build 42, single player, run on the Java 25 it ships with | Supported |
| Multiplayer, joining or hosting | Refused |
| Last Stand, Tutorial, or a game with saving turned off | Refused |
| A game whose built-in save PZ Tools does not recognise (for example after a game update that changes it, or a modified game file) | Refused until PZ Tools is updated |
| Build 41 and older (an older Java) | The game cannot be reached, so backups copy the files on disk |

PZ Tools does not check the game's version number. Before each save it checks that the
running game's own save and main loop look the way it expects, and refuses rather than
guesses when they do not. A refused save means no backup while **Save game before backup**
is on; with it off, backups go on with the files as they are on disk.

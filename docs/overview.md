# How PZ Tools fits together

[Documentation index](README.md) · [User guide](../README.md) · [Glossary](glossary.md)

This page is the map. Read it before any design page: those pages each describe one
part in detail and assume you already know where that part sits. Words in **bold**
on first use are defined in the [glossary](glossary.md).

## The short version

PZ Tools is a desktop app plus a set of small background programs. The app shows
the interface; the background programs do the work, each in its own process, so a
crash or a slow disk in one of them does not freeze the window or take the others
down.

Two things happen independently:

1. **Backups.** A scheduler decides when a backup is due. A worker copies the
   changed save files into the **backup repository** and records a **revision**.
2. **Watching the game.** Another scheduler keeps track of which save is being
   played and whether the game is paused, asleep or showing a death screen. That is
   what lets backup timing follow real play.

The game is reached through the **game bridge**: a small Java component that PZ Tools
loads into the running game. It asks the game to save before a backup, reports the
game's state, and hosts the optional **game extensions** (currently vehicle driving
improvements). The bridge edits no game file; the one game file the app changes, and only
when asked, is the memory setting in the game's launcher file (see [game memory](game-memory.md)).

## The pieces

```text
PzTools.App (window, settings, cards)
 │
 ├─ Backup scheduler ──► Backup runner ──► Backup worker ─────┐
 │                   └─► Maintenance runner ─► cleanup workers │
 │                                                             │  save request
 ├─ State scheduler ──► state collector / reactor              │
 │    │                                                        ▼
 │    ├─ game-state stream (WATCH) ◄──────────── game bridge inside the game
 │    └─ extension control ────────────────────► extension modules inside the game
 │
 └─ one-off workers: restore, ZIP import/export, character recovery, profiler
```

| Piece | What it does | Details |
| --- | --- | --- |
| App | Interface, preferences, progress cards and logs. Starts the schedulers. | [UI contract](ui-ux-contract.md) |
| Backup scheduler | Decides when an automatic backup is due and keeps the queue. | [Process architecture](process-architecture.md) |
| Runners | Take a **run index**, make sure only one job touches a repository at a time, then start the worker. | [Process architecture](process-architecture.md) |
| Backup worker | Optionally asks the game to save, finds changed files, stores them, commits a revision. | [Stable capture](stable-capture.md), [repository format](repository-format.md) |
| Maintenance | Trims old automatic backups and reclaims disk space later, out of the way of backups. | [Housekeeping](repository-housekeeping.md) |
| State scheduler | Finds the active save, reads the game's live state, runs the extension controller. | [Game-aware timing](runtime-pause-backups.md) |
| Game bridge | Java code loaded into the running game. Saves on request, streams state, hosts extensions. | [Game bridge](game-bridge.md) |
| Extension modules | Optional features that run inside the game. Each one is separate and off by default. | [Game extensions](game-extensions.md) |
| One-off workers | Restore, ZIP import/export, character recovery, performance recording. | [CLI](cli.md), [character recovery](character-recovery.md), [profiler](profiler.md) |

Every background program is also a command-line tool, so it can be run and tested
without the app; see [CLI commands](cli.md).

### The interface is a replaceable head

Only `PzTools.App` uses WinUI. What the window does goes through `PzTools.App.Core`
(the host, operations and the views it reads), which has no interface code, so another
interface could sit on the same core. The interface may use the core's view and contract
types, but does not call the libraries below it to do work.

The shared libraries target plain `net10.0`, not Windows, so they build for any
system. Building is not running, though: no other system is built or tested, and
these parts are written for Windows only:

| Part | Windows feature | Elsewhere today |
| --- | --- | --- |
| NTFS change tracking (`Backup.ChangeTracking.Windows`) | USN journal | Backups fall back to a full scan |
| File identity and times (`WindowsFileMetadataReader`) | Win32 file information | Needs another reader behind the same interface |
| Process hosting (`Process.Hosting`) | Job objects, named mutexes and events, detached launch | Activation and polite stop report "not available"; the rest needs a replacement |
| Game attach (`pztools-attach-bootstrap.dll`) | Native Windows DLL | Needs a native attach for that system |

The executables (app, schedulers, runners and workers) still target Windows, as the
release is Windows x64.

## Where things are stored

| Place | Contents |
| --- | --- |
| The app folder | The program files and read-only default settings. Nothing is written here. |
| `%LOCALAPPDATA%\PzTools` | Your preferences, editable component settings, and the small databases for scheduling, game state and logs. |
| The backup folder you choose | The backup repository: `repository.db` plus compressed **pack** files. |
| The game's `Saves` folder | Your saves. PZ Tools reads them. It writes to them only when you restore a backup, import a ZIP, recover a character or delete a save from the app. |
| The game folder | The game itself. PZ Tools changes only the memory options in `ProjectZomboid64.json`, and only when you set the game's memory. |

See [deployment layout](deployment-layout.md) for the full list and
[configuration](configuration.md) for the settings files.

## What happens during one backup

1. The backup scheduler sees that a backup is due for the save being played. With
   game-aware timing, paused and sleeping time does not count.
2. The backup runner takes the next run index and the repository's lock. If another
   job holds the lock, the backup waits for the next check instead of running twice.
3. The backup worker asks the game bridge to save the game, if that option is on.
   The game saves in the normal way; PZ Tools only triggers it.
4. The worker finds which files changed, using Windows' change journal (**USN**)
   where it can and file comparison where it cannot. Each file is checked after
   copying; one that changed mid-copy is read again until a consistent copy is taken.
5. New content is compressed into pack files. Content that is already stored is not
   stored again, even across saves.
6. The worker commits one revision in `repository.db`. Until that commit, the backup
   does not exist; an interrupted backup leaves nothing half-visible.
7. Maintenance may then trim automatic backups beyond the retention limit.

A finished game save is not a finished backup: steps 4–6 come after it.

## How the app knows what the game is doing

Two sources are combined:

- **Files.** The state scheduler checks every few seconds which save's files the game
  has locked. This works without the game bridge and decides which save is active.
- **The game itself.** Through the game bridge, the game streams its state: which
  world is loaded, paused or not, asleep or not, character alive or dead. This is
  what pauses the backup countdown and triggers death backups.

When the game cannot be read, backups carry on with the files on disk. Each
game-dependent feature stops on its own, and the app shows which one. See
[game-aware timing](runtime-pause-backups.md#when-the-game-cannot-be-read).

## Code inside the running game

The game bridge is loaded with Java's standard attach mechanism. It is split in
layers so that most of it can be updated while the game keeps running:

| Layer | Can it be replaced without restarting the game? |
| --- | --- |
| **Bootstrap**: the listener that accepts commands | No. A new, incompatible bootstrap needs a game restart. |
| **Payload**: saving, state stream, extension control | Yes, at an idle moment. |
| **Extension runtime** and **modules** | Yes, each on its own. |

The bridge accepts a fixed set of commands from PZ Tools only. It does not run
arbitrary scripts. See [game bridge](game-bridge.md) and
[component updates](module-reload.md).

## Where to read next

| If you want to know… | Read |
| --- | --- |
| What a setting does | [Configuration](configuration.md), [advanced runtime settings](runtime-configuration.md) |
| Why a backup did or did not run | [Game-aware timing](runtime-pause-backups.md), [death backups](runtime-character-death.md) |
| How backups are stored | [Repository format](repository-format.md), then [packs](pack-format.md) |
| How the game is saved and what can go wrong | [Game bridge](game-bridge.md) |
| How extensions work, or how to add one | [Game extensions](game-extensions.md) |
| How to build and test | [Development and validation](development.md) |

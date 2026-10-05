# Game memory

[Documentation index](../README.md)

The game's Java heap defaults to 3 GB. A game with many mods fills it; with ZGC, the game's collector, threads then
stall until memory is freed and the collector runs back to back on CPU the game needs. The **Game memory** setting
raises the heap by editing the launcher's own file. The player steps are in
[Give the game more memory](../guides/more-game-memory.md). The code is
[`GameMemory`](../../src/PzTools.App.Core/GameMemory.cs).

## What changes in the game's file

`ProjectZomboid64.exe` reads its Java options from the `vmArgs` list in `ProjectZomboid64.json` in the game folder.
Choosing a size changes two entries there and no other character of the file:

- `-Xmx` becomes the chosen size, written as `-Xmx<n>m`.
- `-Xms` is set to the same size. When the file has no `-Xms`, one is inserted right after `-Xmx`, on its own line with
  the same indentation.

Setting `-Xms` equal to `-Xmx` makes the game hold its heap from the start instead of growing and shrinking it with
Windows. That is safe only because the offered sizes stop at half of the PC's memory.

`ReadHeap` accepts the file only when `vmArgs` is an array with exactly one `-Xmx`, at most one `-Xms`, and no heap
option anywhere else in the file (such as a per-Windows-version list that could override it). Otherwise the state is
`Unsupported` and the file is left alone. `Rewrite` checks that its result reads back as asked before anything is
written. Line endings and a UTF-8 byte order mark are kept as found.

**Game default** writes back the `-Xmx` and `-Xms` the file had before the first change (removing `-Xms` if there was
none). If the file no longer holds the chosen size (see [after a game update](#after-a-game-update)), it already has the
game's own and nothing is written; the choice is only dropped.

### Writing

1. The choice and the game's original heap go to `game-memory.json` in the app data folder (`chosen_mb`,
   `default_max_mb`, `default_initial_mb`, `config_path`). If that cannot be written, the game's file is not touched
   and the change fails as `unwritable`: an original heap kept nowhere could not be given back.
2. The first time a choice replaces the game's own heap, the file's text is copied once to
   `game-memory-original.json` beside it, as a manual way back. The app never reads it.
3. The new text goes to a temporary file beside `ProjectZomboid64.json` and is moved over it, so a game starting at
   that moment never reads half a file.
4. A running game holds the file open with read and write sharing but not delete, so the move fails. The app then
   writes in place: new bytes over old, then truncates, so the file is never empty. If that write fails, the old text is
   written back. If the game's file cannot be written at all, `game-memory.json` is restored.

See [files and folders](../reference/files-and-folders.md) for where the app data folder is.

## Sizes offered

`ChoicesFor` offers 4, 6, 8, 12, 16, 24 and 32 GB, up to half of the installed memory
(`GetPhysicallyInstalledSystemMemory`, rounded to whole gigabytes because Windows reports slightly less). One is marked
recommended: 8 GB from 32 GB of memory, 6 GB from 16 GB, none below 16 GB.

| PC memory | Offered | Recommended |
| --- | --- | --- |
| 8 GB | 4 GB | None |
| 16 GB | 4, 6, 8 GB | 6 GB |
| 32 GB | 4 to 16 GB | 8 GB |
| 64 GB or more | 4 to 32 GB | 8 GB |

A size chosen earlier can still be applied again after it stops being offered (memory removed from the PC).

## Finding the file

`Find` tries, in order:

1. The running game. For each game process (`GameProcessFinder`), the folder of its executable and up to two parents,
   so a game started as `jre64\bin\java.exe` is covered. The folder must hold both `ProjectZomboid64.json` and
   `ProjectZomboid64.exe`.
2. The path remembered in `game-memory.json`, if it still exists.
3. Steam: `SteamPath` under `HKCU\Software\Valve\Steam`, then Steam's own folder and every library in
   `steamapps\libraryfolders.vdf`; the first with `appmanifest_108600.acf` gives `steamapps\common\<installdir>`.

A path found is remembered. The app runs as administrator and `game-memory.json` is writable by any of the player's
programs, so a path is used only if it is on a local drive letter and its file name is `ProjectZomboid64.json`
(`IsLaunchFile`). A registry key or library list that cannot be read counts as not found. Nothing asks for elevation;
an unwritable game folder is reported under the setting.

## States

| `GameMemoryStatus` | Meaning | Setting shows |
| --- | --- | --- |
| `Unknown` | Not read yet, or the file was briefly locked on the first read | — |
| `NotFound` | No running game and no Steam install | **The game's folder was not found. Start the game once and it will be.** |
| `Unsupported` | The heap options are not as described above | **The game's settings file is not as expected, so it was left alone.** |
| `Default` | No choice made | **Game default (3 GB)** selected |
| `Applied` | Both `-Xmx` and `-Xms` equal the choice | The choice selected |
| `Reverted` | A choice exists and the file no longer has it | Nothing selected; the game's size as placeholder |

A read that fails with an I/O or access error (Steam writing the file, a scanner) keeps the previous state until the
next read. The file is read 3 seconds after the app starts, every 2 minutes after that (`App.WatchGameMemoryAsync`),
and each time Settings opens.

### The running game

The bridge reports the running game's `Runtime.maxMemory()` in megabytes. With the list open, the entry within 128 MB
of it is marked **· running**. When the file's size differs from it by 128 MB or more, the setting adds **Applies from
the game's next start.** A heap's maximum is fixed when the JVM starts, so nothing changes a running game.

### Started from a launch script

The game can be started by its Java runtime directly: the game's own `ProjectZomboid64.bat` does, and so do scripts
set in Steam's launch options. `GameProcessFinder` counts a `java` or `javaw` process as the game when its command line
names `zombie.gameStates.MainScreenState` as a whole class name. Such a game read nothing from the launcher's file; its
script passes its own `-Xmx` (`-Xmx3072m` in the game's `.bat`). `GameProcessFinder.IsStartedWithoutLauncher` (the
process name is `java` or `javaw`) makes the setting say the game is running from a launch script and that the size
applies only when the game is started normally.

### Steam launch options

This is the game launcher's behaviour, not PZ Tools code. Java options in Steam's launch options before `--`
(`-Xmx8192m --`) come after the file's, so they win over the setting. A second `--` there stops the game from
starting. The app does not read or edit Steam's launch options; the guide tells the player to remove `-Xmx` from
them.

## After a game update

A game update or Steam's file check rewrites `ProjectZomboid64.json` with the game's own options, and the state
becomes `Reverted`. Then:

- A sidebar card shows **Game memory back to 3 GB** with **Apply 8 GB again** (the file's size and the choice). Its
  button applies the choice; ✕ hides it until the choice or the file's size changes. It leaves by itself when the state
  is no longer `Reverted`.
- The setting shows nothing selected, the game's own size as placeholder, and **A game update undid the 8 GB setting.
  Choose it again to apply it.** Picking any entry, the game default included, is a change.

## On the Performance page

`ProfileAnalysis.MemoryPressure` judges the whole recording short of memory when it has any allocation stall, or when
at least a quarter of its heap readings (8 or more readings) stand at 90% of the maximum or above. The page then shows
**Stopped N times for lack of memory** or **Memory nearly full** above the memory graphs, with **Memory setting**
opening Settings at this setting. From 5% it adds what the collector cost (**frames 17% slower while GC ran**).

When the game's file now gives more than the recording's maximum heap plus 256 MB (the collector reports a little under
what was set), the line becomes muted history: **Memory nearly full when recorded · now set to 8 GB**, with an
information icon and no button. See [the Performance page](../reference/performance-page.md).

## Alternatives rejected

| Way | Why not |
| --- | --- |
| `ProjectZomboid64.site.json` beside the file | The launcher reads it instead of the shipped file, not on top of it. It would have to copy every option, and after an update that changes other options the game would start with the old ones. |
| Steam launch options | They win over the file, but they live in Steam's settings, which the app does not edit, and a second `--` breaks the start. |
| A Java options variable, for scripts | `JAVA_TOOL_OPTIONS` comes before a script's own `-Xmx`, which then wins. `_JAVA_OPTIONS` would come after, but the game's `.bat` clears it. Either reaches every Java program on the PC. |
| Rewriting the script | A script is the player's or a mod's, in any form; the game's `.bat` is restored by every update, as the launcher file is. |

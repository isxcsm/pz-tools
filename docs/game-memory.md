# Game memory

[Documentation index](README.md) · [User guide](../README.md) · [Glossary](glossary.md)

*Settings > Game > Game memory* sets how much memory the game's Java may use. The game
ships with 3 GB. A game with many mods fills that, and then spends its time freeing memory:
with the collector it uses (ZGC, on Windows 10 1803 and later), threads that need memory
wait for it (*allocation stalls*), and collections run back to back, taking processor time
from the game. Giving it more is the usual cure, and the change most players get wrong by
hand.

## What the setting does

The game's launcher (`ProjectZomboid64.exe`) reads its Java options from
`ProjectZomboid64.json` in the game folder. Choosing a size rewrites two options in that
file's `vmArgs` list, and nothing else:

- `-Xmx` (the most the heap may grow to) becomes the chosen size;
- `-Xms` (the heap held from the start) is set to the same size, on the line after it.

Holding it from the start means the game never waits to get memory from Windows, or gives
it back and asks again, while it plays. To keep that safe, the sizes offered stop at half of
the PC's memory, so Windows and other programs always keep the rest:

| PC memory | Sizes offered | Marked as recommended |
| --- | --- | --- |
| 8 GB | 4 GB | none |
| 16 GB | 4, 6, 8 GB | 6 GB |
| 32 GB | 4 to 16 GB | 8 GB |
| 64 GB or more | 4 to 32 GB | 8 GB |

With ZGC a larger heap does not make the game's pauses longer; an unused part only stays
reserved. *Game default* gives the file back its own options as they were before the first
change.

The change applies from the game's next start; a running game keeps what it started with.
While the game runs, the list, when opened, marks the size it was started with, read from
the game itself (*8 GB (recommended) · running*); closed, it shows the choice alone. When
the choice differs from what the running game started with, the setting says it applies
from the game's next start.
The file is written beside itself and moved over, so a game starting meanwhile never reads
half of it. A running game holds the file open and lets others read and write it, but not
replace it; then it is written in place, which that game no longer reads: the new text over
the old and the end cut only after, so the file is never left empty, and put back to the
old text if writing fails partway. The file as the game shipped it is kept once, as `game-memory-original.json` in
the app's data folder (see [files and folders](deployment-layout.md)). The choice and the
game's own heap are kept in `game-memory.json` before the game's file is changed; when that
cannot be written, the game's file is left alone and the setting says it cannot be changed,
as a heap kept nowhere could not be given back.

The file is left alone when it is not as expected: no `vmArgs` list, no `-Xmx` in it, an
option twice, or a heap option anywhere else in the file (such as the per-Windows-version
lists), which could override the one changed. A file held for a moment (Steam writing it, a
scanner) changes nothing shown; it is read again at the next look.

## Finding the game

The running game's folder; else the file found before, while it is there; else the Steam
library that holds Project Zomboid (app 108600), read from Steam's own list of libraries. A
game folder that cannot be written to is reported under the setting; nothing asks for
administrator rights.

## Started from a launch script

The game can also be started by its Java runtime directly, without the launcher: the
game's own `ProjectZomboid64.bat` does, and so do scripts players set in Steam's launch
options. The app finds and connects to such a game as to any other, but the launcher's
file plays no part in it: the script gives the memory on its own command line
(`-Xmx3072m` in the game's bat). While such a game runs, the setting says so, and the
choice applies to the next start through the launcher. A Java heap's maximum is fixed when
the game starts, so nothing the app does to a running game changes it.

## After a game update

A game update or Steam's file check writes the launcher file back with the game's own
options. The choice is kept by the app, which reads the file soon after it starts and every
two minutes. When the file no longer holds the chosen size, a card in the sidebar says
*Game memory back to 3 GB* with *Apply 8 GB again*, and the setting shows the game's own
size, unselected, with a note: choosing either the game's own (letting the choice go) or a
size is a change. The card leaves when the choice is in the file again, when the choice is
let go, or through ✕. A size no longer offered (memory taken out of the PC) can still be
applied again.

Two other ways were tried and not used:

| Way | Why not |
| --- | --- |
| `ProjectZomboid64.site.json` beside it | The launcher reads it *instead of* the shipped file, not on top of it: it would have to copy every option, and after an update that changes other options the game would start with the old ones |
| Steam launch options (`-Xmx8192m --`) | The launcher does take Java options before a `--` on its command line, after the file's, so they win. But they live in Steam's settings, which the app does not edit; and a second `--` there stops the game from starting |
| A Java options variable, for scripts | `JAVA_TOOL_OPTIONS` comes before a script's own `-Xmx`, which then wins; `_JAVA_OPTIONS` would come after, but the game's bat clears it; and either would reach every Java program on the PC |
| Rewriting the script | A script is the player's own, or a mod's, in any form; the game's bat is put back by every update, as the launcher file is |

## On the Performance page

A recording in which the game ran short of memory says so on the line above the memory
graphs, with **Memory setting →** leading to the setting:

- *Stopped N times for lack of memory*: the recording has allocation stalls, threads that
  waited for memory to be freed. Both recording modes record them.
- *Memory nearly full*: no stalls, but the heap stood at 90% of its maximum or more for a
  quarter of its readings or more, so collections ran almost without a break.

It is judged on the whole recording, as the setting is not about any one moment. What a
recording shows stays true of it after the setting changes: once the game's file gives it
more than the recording had, the line says what was and what is set now (*Memory nearly
full when recorded · now set to 8 GB*), in muted text with an information icon and no
link, as there is nothing left to do. New recordings are judged on their own heap.

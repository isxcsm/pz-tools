# Performance page

[Documentation index](../README.md)

The **Performance** page records the running game and shows where each frame's time went: which part of the game,
which mod, which function. For a step-by-step hunt for a laggy mod, see
[Find a laggy mod](../guides/find-a-laggy-mod.md). How recording works inside is in
[the profiler design](../design/profiler.md).

Nothing is measured unless a recording is running or **Keep the last minutes** is on. All shares on the page are
estimates from samples taken at regular intervals, so two figures close to each other say little.

## Making a recording

The buttons right of the title make recordings. When the page itself (not counting the navigation pane) is narrower
than 760 pixels they move under the title. Below 900 pixels **Save last 2 min** and **Compare with** show their icons
alone, with their names as tips.

### Start recording and Stop recording

**Start recording** asks the game to record until you press **Stop recording**. It needs exactly one running game;
the page checks every two seconds, and resting the pointer on the disabled button says what is missing (**Start the
game to record.** or **More than one game is running. Leave only one.**).

| State | Button | Line under the toolbar |
| --- | --- | --- |
| Idle | **Start recording** (**Start recording · Detailed** when Detailed is chosen) | Nothing |
| Starting | **Stop recording**, disabled | **Connecting to the game…** |
| Recording | **Stop recording** (**Stop recording · Detailed** for a Detailed recording) | **Recording 01:23 · stops automatically after 30 minutes** |
| Processing | **Stop recording**, disabled | **Processing the recording…** |

While it records, a second line may say that the game gives no mod information (**Mod (Lua) information cannot be
read in this game version, so only Java code is recorded.**) or no frame boundaries (**Frame boundaries cannot be
read, so this recording has no frame graph.**).

A recording also ends by itself when the game exits or when its time limit is reached. The finished recording is
listed and opened at once.

If it fails, the reason appears on the operation card or as a notification:

| Message | Meaning |
| --- | --- |
| **The game is not running.** | No game was found when you pressed the button. |
| **More than one game is running. Leave only one.** | The page cannot tell which game to record. |
| **Other work is running. Try again in a moment.** | Another recording or a conflicting operation is under way. |
| **Could not connect to the game. Try restarting the game.** | The app could not reach the game. |
| **Restart the game once to record.** | The game still runs a bridge from an older app version. |
| **Could not connect because a game launch option blocks it. Check the game's launch options.** | The game was started with attaching turned off. |
| **Could not make the recording file. Check the logs.** | The recording ran but could not be converted. |
| **Could not record. Check the logs.** | Any other failure. A cancelled recording and one blocked by Windows Security have their own messages. |

### Standard and Detailed

The arrow on **Start recording** chooses the mode of the next recording. A recording under way keeps its mode. The
choice lasts while the app runs.

| Mode | Readings | Cost to the game | Time limit |
| --- | --- | --- | --- |
| **Standard** | Every 0.01 seconds | Almost none | 30 minutes |
| **Detailed** | About every 0.002 seconds, and also waits and pauses (lock waits, parked threads, slow file reads and writes) | The game runs about 20% slower; the file is about ten times larger | 10 minutes |

Standard is enough for most questions, loading included. Detailed is worth it for a single short stutter, where
Standard has only one or two readings per frame. The time limits can be changed in the
[advanced settings](advanced-settings.md) (`[profiler]` `general_limit_minutes` and `detailed_limit_minutes`).

### Save last 2 min

With **Settings → Performance → Keep the last minutes** on, the game always holds its last few minutes (1 to 10,
2 at first, in Standard or Detailed, both set there). They take at most 256 MB on disk
(`[profiler] rolling_max_megabytes` in the [advanced settings](advanced-settings.md#app)), so a long Detailed window
can hold less than its length. **Save last 2 min** turns them into a recording right after a
stutter. The number on the button is the length set in Settings. The game goes on keeping the next minutes, and a
recording started with **Start recording** runs beside it.

| State | Button |
| --- | --- |
| **Keep the last minutes** off | **Turn on last minutes** with an arrow; it opens Settings at that switch |
| On, game keeping them | **Save last 2 min** (**Save last 2 min · Detailed** while Detailed is kept) |
| On, nothing kept yet | Disabled; the tip says **Starts keeping the last minute once the game is running.**, **Starting to keep the last minute…**, or why the game refused |
| Saving | **Saving last 2 min…** |

The button's tip names the mode being kept and the hotkey, if one is set. If the game turns out not to be keeping
them (for example after a restart), the save fails with **No last minutes to save. Recording again from now.**

### Hotkeys

The game has the keyboard when it stutters, so these actions can have keys, set under **Settings → Hotkeys**:

| Action | Default |
| --- | --- |
| **Save last minutes** | Ctrl+Shift+F9 (works only while **Keep the last minutes** is on) |
| **Start/stop performance recording** | None |
| **Switch recording mode (Standard/Detailed)** | None |
| **Keep last minutes on/off** | None |

Each key answers with a Windows sound and a short note over your character's head. A recording saved from a key is
listed when you next look at the page.

## The recording shown

The line under the title holds the recording shown and what can be done with it.

### The recordings list

The list shows every recording in `%LOCALAPPDATA%\PzTools\profiles\`, newest first, named by what it is and when it
was made:

| Example | What it is |
| --- | --- |
| **Last 2 min · Today 3:43 PM** | Saved with **Save last 2 min** |
| **Recording 1 min 20 s · Today 3:43 PM** | A Standard recording (Standard is not named) |
| **Recording 1 min 20 s · Detailed · Yesterday 9:10 PM** | A Detailed recording |
| **mod A added · Recording 3 min · Today 3:43 PM** | A recording you renamed |

Older recordings show their date. A recording not read yet is listed by its time alone for a moment. The list's tip
gives the file name and size. With no recordings, the page says how to make one.

### Actions

| Control | What it does |
| --- | --- |
| Pencil (**Rename**) | Turns the list into a box with the name. Enter or clicking elsewhere keeps it, Esc cancels. An empty name gives the recording its automatic name back. The name is the file's name, so whoever gets the file sees it. Characters a file name cannot hold become `_`, names are cut at 80 characters, and a name already taken gets a number, such as **mine (2)**. |
| Bin (**Delete**) | Deletes the recording after asking **Delete this recording? This cannot be undone.** |
| **Compare with** | See [Compare with](#compare-with). |
| **…** (**More**) | Opens the menu below. |

The **More** menu:

| Item | What it does |
| --- | --- |
| **Open recording…** | Copies a `.pzprof` file from elsewhere into the recordings folder, keeping its file time, and opens it. A file that is not a readable recording is refused with **Cannot open the recording. It is damaged or from a newer version.** |
| **Save as…** | Copies the selected recording to a place you choose. |
| **Save selection** | Saves the range selected on the graph as a new recording, named after this one and the range, such as **mod A added (12.30–20.50 s)**, and opens it. Available only while a range is selected. The **…** button shows a ring while it saves. The new recording shows the same figures the range did, and can be compared with or sent on its own. |
| **Open folder** | Opens the recordings folder in Explorer, with the selected file highlighted. |

## The frame graph

### The line above the graph

It describes the range the results below are for:

| Item | Example | Notes |
| --- | --- | --- |
| Range | **Total 80.37 s** | The whole recording. |
| Selection chip | **Selection 8.20 s (12.30–20.50 s)** ✕ | A selected range: its length, then where it lies. Pressing the chip, or Esc anywhere on the page, clears the selection. |
| **Average** | **23.6 FPS (42.4 ms)** | Frame rate, then frame time. |
| **Worst 1%** | **4.0 FPS (251.6 ms)** | The slowest 1% of frames. |
| **Frame** | **42.4 ms** | Shown instead of the two above when the range is one frame. |

Resting the pointer on the line adds the frame count, the slowest frame, the sample and garbage-collection counts,
how many samples of threads only waiting were left out, and the recording mode. While the pointer is over the graph
the line shows the time and the frame under it instead (with the highlighted owner's time in that frame, and a
**GC pause** of 2 ms or more). While you drag a selection it shows the range being drawn.

Beside the line:

| Control | What it does |
| --- | --- |
| Thread list (**Game thread** / **All threads**) | Which thread's samples the whole analysis counts. **All threads** adds rendering, loading and background threads. A recording without a known game thread can only show all threads. |
| **Zoom to selection** | Zooms to the selected range with a little room on each side. |
| **Show all** | Zooms out to the whole recording. |
| **?** | Lists the graph's mouse controls. |

### What the graph shows

Each bar is a thin slice of time, as tall as the slowest frame in it, so one spike stays visible at any zoom.

| Mark | Meaning |
| --- | --- |
| Blue bar | A frame faster than 30 FPS (33.3 ms or less). |
| Orange bar | A frame slower than 30 FPS: a stutter on any computer. |
| Dashed lines **60 FPS** and **30 FPS** | Fixed frame times (16.7 and 33.3 ms), left out where they would sit on the floor or on each other. |
| **▲** at the top | A bar taller than the scale; its time is shown under the pointer. The scale stops at about twice the usual bar height, so one long loading frame does not flatten the rest. |
| Light orange background | The garbage collector was running. Frames here that are longer than their neighbours point to memory running short. |
| Red dashed line with a triangle on the floor | A garbage collection that stopped the game for 2 ms or more. |
| Dark part inside faded bars | The highlighted owner's time in each frame (see [Highlighting an owner](#highlighting-an-owner)). |
| Coloured part inside faded bars | The part of the **This range's time** bar under the pointer. |

The graph stays in place while the results scroll. Drag the handle under it to make it taller or shorter.

### Mouse and keyboard

| Action | Effect |
| --- | --- |
| Wheel | Zooms around the pointer. |
| Shift+wheel, or a horizontal wheel | Moves along the recording. |
| Right-button or middle-button drag, or the scroll bar under the graph | Moves along the recording. |
| Drag | Selects a range. |
| Click | Selects the frame under the pointer. |
| Double-click | Shows everything and keeps the selection there was before the click. |
| Esc | Clears the selection. The zoom stays. |

The same controls work on the memory panel.

## The memory line and panel

The line under the graph appears when the recording has memory readings or garbage collections. It holds the
**Memory** button and the range's figures. While the pointer is over a graph, the figures follow it: the collections
in that frame and memory at that moment.

| Figure | Example | Meaning |
| --- | --- | --- |
| Orange square and **GC** | **GC 3 times · working 4.12% · GC pause 120.0 ms · Waited for memory 12 times, longest 420.0 ms** | Garbage collections in the range. **working** is how much of the range the collector was running (shown from 1%). **GC pause** appears when the pauses add up to 2 ms or more. **Waited for memory** counts the times a thread stopped until memory was freed. |
| **Heap peak** (green) | **Heap peak 2.41 GB** | The highest Java heap use in the range. |
| **VRAM peak** | **VRAM peak 1.20 GB** | The highest video memory the game held. Absent where Windows does not report it. |

Clicking the **GC** figure hides or shows the orange background and the pause marks on the frame graph for as long
as the app runs. The figure is faint while they are hidden.

### Warnings on the memory line

| Text | When |
| --- | --- |
| **Stopped N times for lack of memory** | Threads had to wait for memory at least once in the recording. |
| **Memory nearly full** | The heap stood at 90% or more of its maximum in a quarter or more of the readings, with at least 8 readings. |
| **· frames 17% slower while GC ran** | Added to either of the above when frames with the collector running were at least 5% longer than frames without it (at least 20 frames of each). |
| **Memory setting** | Link next to the warning. It opens **Settings → Game → Game memory**. See [Give the game more memory](../guides/more-game-memory.md). |
| **… when recorded · now set to 6 GB** | The game has since been given more memory than it had in this recording. The warning is muted and the link is gone. |
| **Other programs used 55% of the CPU on average** | Other programs used 35% or more of all processors while it recorded. A busy PC slows the game whatever its mods do. |

Resting the pointer on the memory warning gives the maximum the game had.

### The memory panel

The **Memory** button opens a short graph under the frame graph, on the same time axis. Until you open or close it
yourself, it opens by itself for a recording that ran short of memory and stays closed for the others. After that
it stays as you left it while the app runs.

| Row | Shown when | What it shows |
| --- | --- | --- |
| **Heap in use · GC pauses** | The recording has heap readings | Java heap in use (green line) and each collection as a grey bar, as wide and tall as its pause. Named **Heap in use** alone when there are no collections or they are hidden. |
| **GC pauses** | Collections but no heap readings, and collections not hidden | The collections alone. |
| **<mod> allocated** | A mod or the game's scripts is highlighted and the recording has allocations | The memory that owner's scripts allocated, one bar per moment. Garbage that piles up just before collections points at that mod. |
| **VRAM** | The recording has video memory readings | Memory the game held on the graphics card. |

The heap and VRAM scales run from their lowest to their highest reading in view, the allocation row from 0 to its
largest bar, and the GC pauses to the longest pause. The scale is written at the left. Resting the pointer on
a row's name says how to read it.

## This range's time

The thin bar above the tabs splits the range's time on the game thread into parts that add up to 100%:

| Part | Counts |
| --- | --- |
| **Scripts** | Lua scripts of mods and the game, including the Java functions they called. |
| **Game code** | The game's own Java code. |
| **Memory stop** | The game thread stopped for garbage collection or waited for memory. Shown only from 0.5% of the range. |
| **Waiting** | The game thread resting, mostly the time left before the next frame. |

While a mod is highlighted in **Scripts (Lua)**, its share stands apart at the start of the bar with its name, and
the rest of the scripts read **Other scripts** in a lighter colour.

Resting the pointer on a part's name gives its share, its time in the range and what it counts (for **Memory stop**,
also how much of the range the collector was working). Pointing at a part on the bar or its name draws that part of
each frame on the graph in the part's colour.

The bar is hidden for **All threads**, whose times overlap, and for a range with fewer than 20 samples. A range that
small also shows **Too few samples for accurate percentages. Select a wider range or record in Detailed mode.**

## The tabs

| Tab | Shown | Ranks |
| --- | --- | --- |
| **Scripts (Lua)** | Always | Mods and the game's scripts by time. |
| **Game code (Java)** | Always | Parts of the game's Java code by time, plus threads and long waits. |
| **Memory allocation** | When the recording has script allocations | Mods and the game's scripts by memory allocated. |

Each tab has an owner list on the left and the chosen owner's table on the right (below it in a narrow window). The
chosen owner stays chosen when the range changes, if it is still there.

### The owner list

| Tab | Name column | Number column | Note under the list |
| --- | --- | --- | --- |
| **Scripts (Lua)** | **Mod** | **Range time**: how much of the range the owner's scripts were running, Java functions they called included. All scripts together stand beside the heading. | **Includes the time of Java functions called from Lua.** |
| **Game code (Java)** | **Item** | **Run share**: the owner's part of the game code's running time. Java functions called from Lua count as the game here. | **Java functions called from Lua count as the game here. See the Scripts tab for each mod.** |
| **Memory allocation** | **Mod** | **Allocated**: bytes the game thread allocated while the owner's scripts ran. All scripts together stand beside the heading; its tip adds the whole game thread's figure. | None |

So the two time tabs count calls from scripts into the game differently. A mod that calls heavy game functions
looks heavier in **Scripts (Lua)** than in **Game code (Java)**.

Script owners:

| Owner | What it is |
| --- | --- |
| A mod's folder name | Scripts under that mod's `mods/<name>/` folder. |
| **Base game scripts (vanilla)** | The game's own scripts under `media/`. |
| **Scripts of unknown origin** | Scripts whose path does not say. |

Game code owners:

| Owner | What it is |
| --- | --- |
| **Base game (vanilla)** | The game's own code. |
| **Lua engine (runs mod and game scripts)** | The script interpreter. |
| **Java built-in functions** | Java's own libraries. |
| **PZ Tools** | PZ Tools' code inside the game, usually around a tenth of a percent. |
| **Bundled libraries (graphics, sound and others)** | Everything else, Java mods included. |
| **Share by thread** | Every thread's share of all threads' samples. Shown when the range has more than one thread. |
| **Long waits and pauses** | The ten longest waits and pauses, with their count (**4×**). Detailed mode records lock waits, parked threads, slow file reads and writes and JVM operations; both modes record garbage-collection pauses and memory waits. |

Each row has a bar sized against the largest owner. Comparing adds the change (see [Compare with](#compare-with)).

### Highlighting an owner

Clicking an owner in any tab draws its share of each frame over the faded frame graph, on a scale fitted to it, and
puts a small graph mark beside its number. Clicking it again stops. While one is drawn, pointing at another owner
shows that one until the pointer leaves. A newly opened recording starts with nothing highlighted. Highlighting a
script owner also adds its allocations to the memory panel. **Share by thread** and **Long waits and pauses** cannot
be highlighted.

### The line above the table

| Control | What it does |
| --- | --- |
| Owner name | The owner the table shows. |
| Search (or Ctrl+F) | Opens a box in the name's place. It keeps the rows whose name or file contains the text, in any letter case; in a call tree it keeps the paths to a match, opened down to it. It stays across owners and ranges while it holds text. Esc clears and closes it; leaving it empty closes it. Not available for **Long waits and pauses**. |
| **Call tree** | In the two script tabs: a call tree when on, a plain list of functions when off. On at first; the choice lasts while the app runs. |
| **Copy for AI** | See [Copy for AI](#copy-for-ai). |
| **Samples 9/70** | The owner's samples out of the tab's. For **Share by thread**, the count alone. |

In a narrow line the samples and the **Copy for AI** label make room first.

### Script tables (Scripts and Memory allocation)

| Column | Meaning |
| --- | --- |
| **Function** | The Lua function. A file's top-level code is named after the file. |
| **File** | The script file and the line the function ran itself the most, such as `Client.lua:125` (in **Memory allocation**, where it allocated most). Pressing it opens the file menu below. |
| **Self** | Time (or bytes) in the function itself, as a part of the owner, the owner being 100%. |
| **Total** | The same including what it called. |
| **Samples** | In the tree, samples that passed through the row; in the list, samples that ended in the function. |
| **Change** | Only while comparing. |

The numbers are parts of the owner, so a large part of a light owner can look heavy. Resting the pointer on a time
gives its part of the whole range and the time it stands for (**2.1% of the whole range, about 1.14 s**); on bytes,
their part of the owner's allocations. Resting the pointer on a heading says what the column means.

Behind each **Total** a blue gauge shows the row against the table's largest total. Behind each **Self** a grey gauge
shows the row's own work as a part of its own total: full for a function that did the work itself, empty for one
whose time went into what it called.

**In the call tree** the outermost function (an event handler, or the game's script that called into the mod) is on
top, and each function's calls are indented under it, the heaviest first. Click the arrow or the row to open or
close it. The tree starts closed, and what you open stays open for other ranges of the same recording. Under an
opened function, after what it called, a closed row **Lines it ran itself · 25** opens into the lines where it did its
own work. Resting the pointer on a function's file says which line of its caller called it. In **Memory allocation**
paths that allocated nothing are left out. Only the 24 innermost functions of a call path are recorded, so a deeper path starts at the 24th function counted
from the inside.

**In the list** each function counts the samples that ended in it, so a helper called from many places adds up into
one row. A function's row opens into its lines, most first. A line marked **(call)** is one it only called from; its
time belongs to the called function.

Past the first 20 rows of a tree level, or 30 rows of the list, the rest are gathered into one closed row, **N
more**, carrying their sum. **Line unknown** is a frame the game gave no line for.

The file menu, opened by pressing a file:

| Item | What it does |
| --- | --- |
| Path and copy button | The full path of the script on this PC (a Workshop mod in Steam's libraries, a mod in your own `mods` folder, or the game's own scripts), or **This file is not on this PC. The recording may come from another PC, or the mod was removed or moved.** The copy button copies the path shown, or the path the recording keeps. |
| **Changed since the recording: its line numbers may differ** | The file was modified after the recording was made. |
| **Open** | Opens the file with its usual program. |
| **Open line N in VS Code** | Opens it at that line in VS Code. Shows **Open in VS Code (VS Code not found)**, disabled, when VS Code is not installed. |
| **Show in folder** | Opens Explorer with the file selected. |

Programs opened from here start through Explorer, without the app's administrator rights.

### Game code tables

| Column | Meaning |
| --- | --- |
| **Method** | Class and method; the full name is in the tip. |
| **Package** | The method's package. |
| **Self** | Time in the method itself, as a part of the item, the item being 100%. |
| **Total** | Including the item's own code it called. A method that only called into other items has no row. |
| **Samples** | Samples that ended in the method. |
| **Change** | Only while comparing. |

Resting the pointer on a number gives its part of all the running time. Past the first 30 methods the rest are
gathered into **N more**.

A method with time of its own opens onto who called it, nearest first, the heaviest first. **Finding callers…**
shows while they are worked out. A chain of callers that never branches is one row (`Cache.wrap ← Game.update`). Up
to the game's own code, callers with a tenth or more of the method's time open by themselves. Callers under 0.5% of
the range are gathered into one row. **(Lua running)** stands for a call from a script; which script is in the
**Scripts (Lua)** tab.

**Share by thread** has **Thread**, **Self**, **Total** and **Samples**. **Long waits and pauses** has **Time** (when
it started), **Length**, **Kind** and **Details** (a file name, a lock's class or the thread).

## Compare with

**Compare with** lists up to 30 other recordings, newest first. Pick one, say from before a mod was added, and the
range shown is compared with the whole of it. A long recording takes a few seconds to load; the button then shows a
ring and **Loading <name>…**, and its ✕ takes the choice back. A comparison already shown stays until the new one
is ready.

While comparing, the button reads **Compared with <name>** in the accent colour, and each figure carries its change:

| Where | Change shown |
| --- | --- |
| **Average** and **Worst 1%** above the graph | **▲** more frames per second (green) or **▼** fewer (red); before → after in the tip. |
| Scripts total beside **Range time** | Points of the range gained or lost. |
| Each owner in **Scripts (Lua)** | Points of the range gained (red) or lost (green). |
| Each owner in **Game code (Java)** | Points of **Run share** gained (red) or lost (green). |
| **Change** column in the tables | The row's total against the same function or method there, in points (**pp**). |

Shares are compared, not times, so recordings of different lengths compare. A function is matched by its name and
its file from `media/lua/` on, so a mod moved from the Workshop to a local copy, or updated, still matches. In the
tree a row is matched by its whole path, and a path the other recording never took counts as all gain. **Memory
allocation**, **Share by thread** and **Long waits and pauses** are not compared.

The comparison stays while you show other recordings and ranges. Press the ✕ beside the button, or choose **Stop
comparing** in its menu, to end it. To compare with part of a recording, save that part with **Save selection**
first.

## Copy for AI

**Copy for AI** puts a Markdown report on the clipboard, to paste into a chat with an AI model or send to a mod's
author. Reports are in English with plain numbers, whatever the app's language.

| Item | Contents |
| --- | --- |
| **Whole report** | The range, the same whatever the page has open. |
| **Detailed report: <name>** | The owner shown in the table, in full. Offered for a mod (in **Scripts (Lua)** or **Memory allocation**) and for a game code item; not for **Share by thread** or **Long waits and pauses**. |
| **Save as a file** | The same reports saved as a `.md` file, named after the recording (and the owner for a detailed report). |

The button shows a ring while the report is built.

Both reports start with a few lines on how to read the figures, then:

- the recording: its name, mode, length and start time, the range and thread analysed, sample counts and the
  number of processors
- frames: count, average, median, worst 1% and slowest
- where the analysed thread's time went, in the four parts of **This range's time** (left out for fewer than 20
  samples)
- memory and CPU: heap peak against its maximum, video memory peak, collections and the collector's name, how long
  the collector worked, memory waits, how much slower frames were while it worked, whether the game ran short of
  memory, and other programs' CPU use

The **Whole report** goes on with the twelve heaviest mods; up to eight functions each, with file and heaviest line,
of the five heaviest that take at least 0.5%; the Java areas; the fifteen heaviest Java methods and who called the
heaviest, up to the game's code; the eight mods that allocated the most memory; up to eight threads (with **All
threads** only); and the five longest waits and pauses.

A **Detailed report** on a mod goes on with its share and rank, 25 of its functions, the heaviest lines of its ten
heaviest functions, the call tree that reached them (outermost first, each with the line it was called from, branches
under a hundredth of the mod summed up) and what its functions allocated. On a game code item it lists 25 methods and
who called the heaviest.

While comparing, a report names the other recording and puts its figure and the change beside each comparable one.
Allocations are compared per minute. A caution is added when the two were recorded in different modes.

## What a recording contains

Each recording is one `.pzprof` file in `%LOCALAPPDATA%\PzTools\profiles\` (see
[Files and folders](files-and-folders.md)). If you pass a file on, it contains:

- Java method names and thread names
- Lua function names, and script paths from `mods/` or `media/` down, such as
  `mods/MyMod/media/lua/client/Client.lua`; a Workshop mod's path also has its Workshop item number
- the line numbers samples fell on
- frame times, Java heap, video memory, garbage collections and CPU use
- for waits and pauses, the file *names* of slow reads and writes and the class names of locks
- the recording's mode, start time and name (the file name)

It does not contain the folders above `mods/` or `media/` (which would include your Windows user name), save
contents, or chat.

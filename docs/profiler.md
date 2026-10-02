# Performance recording

[Documentation index](README.md) · [User guide](../README.md) · [Glossary](glossary.md)

The **Performance** page records what the running game is doing and shows where the time
went: which part of the game, which mod, which function. Nothing is measured unless a
recording is running.

## Recording

Start the game, press **Start recording**, reproduce the lag, press **Stop recording**.

Loading can be measured too. Start a recording at the main menu, then load a save (the
world loading and the mods' scripts run at that time), or change the mod list so the
game reloads the mods' scripts. Standard mode is enough. The frame graph shows the
loading as one long frame; the *Scripts* tab says which mod's scripts took the time,
and *Game code* what the game itself was loading. What happens before the main menu
cannot be recorded, as the game is not running yet; it is the same scripts as a reload
plus the game's own start, which neither players nor mod authors can change.
A recording also ends by itself when the game exits or when its time limit is reached
(30 minutes in Standard mode, 10 minutes in Detailed mode).

**Start recording** is available while exactly one game is running, or before the first
check has answered; the page checks every two seconds, and resting the pointer on the button says what is missing. Nothing
is logged for that. If the game closes just as a recording starts, the recording's card
says so and the log keeps it as information (`run.unavailable`), not as an error. A
recording that really fails is logged once, by the recording itself, and its card gives
the reason. When the game still runs a bridge bootstrap from before an update that this
build cannot use, the card says plainly that the game needs one restart to record, rather
than the general "could not connect"; an update that keeps the bootstrap compatible needs
no restart at all (see [compatibility](save-bridge.md#compatibility-and-lifecycle)).

| Mode | Java samples | Lua samples | Extra |
| --- | --- | --- | --- |
| Standard | every 10 ms | every 10 ms | garbage-collection pauses, Java heap use, video memory, memory allocated by scripts |
| Detailed | 1 ms requested, about 1.5–2 ms in practice | every 1 ms | the above, and lock waits, parked threads, slow file reads/writes, JVM stop-the-world operations |

Memory is recorded in both modes. The **Java heap** (used, committed and maximum) is read
by the game's own recorder four times a second. **Video memory** cannot be measured from
inside the game: the recording worker reads the game process's figures from Windows five
times a second (the per-process *GPU Process Memory* counters, the same numbers as Task
Manager's GPU memory columns: on the graphics card, and system memory the card borrows),
matched to the game by its process id, so other programs' use is left out. Once the
recording is written, the worker adds these readings to its end on the recording's time
scale. Where Windows has no such counters (before Windows 10 1709, or a driver that does
not report them), the recording simply has no video memory. Neither tells how much of
what is held each frame actually uses.

**Allocations** say who fills the heap. Each time the Lua sampler looks at the game, it
also reads how many bytes the game thread has allocated so far (the JVM's own per-thread
counter; nothing is hooked), and the bytes since its previous look go to the Lua function
it finds running, the same way the sample's time does. Once a second it also records the
game thread's whole allocation, in Lua or not. Like the shares of time this is an
estimate: a function that runs between two looks has its bytes counted for whichever
function the next look finds, so Detailed mode, which looks every millisecond, is closer.
It says how much garbage each mod makes, which is what makes collections frequent; it
does not say which mod *keeps* memory (a growing heap that never drops), which would need
a heap dump.

Both modes are sampling: the game's code is not rewritten or instrumented. Detailed mode
samples more often and records why a thread was *not* running; it costs the game some
frame rate (roughly 10% in a synthetic test) and writes about ten times as much.

While a recording runs the game's timer resolution is raised to 1 ms, as games and media
players commonly do; otherwise Windows would round every sampling period up to 15.6 ms.
It is restored when the recording ends.

Backups, saving and game extensions keep working during a recording. Recording control
uses the ordinary short request channel to the game; if a backup's save request is using
it, start or stop simply waits for it.

## What depends on the game version

| Part | Source | If the game changes |
| --- | --- | --- |
| Java stack samples, native-call samples, GC and pause events, heap use | The JVM's own flight recorder (`jdk.jfr`) | Unaffected: it depends on Java, not on game code |
| Video memory | Windows performance counters, read by the recording worker | Unaffected: it depends on Windows and the graphics driver |
| Allocations by script | The JVM's per-thread allocation counter, read by the Lua sampler for the thread that runs the frame hook | Needs both game-specific parts below; without either, or in a Java runtime without the `jdk.management` module, the recording has no allocations and the page no allocation tab |
| Frame boundaries | The existing game-loop hook (`GameWindow.logic`) | The recording still works; there is no frame graph, only the time axis |
| Lua function and mod attribution | Reads the Lua interpreter's call stack (`LuaManager.thread`, Kahlua call frames) from a sampler thread | The recording still works; the page says mod information is unavailable |

The Lua sampler reads interpreter objects from another thread without stopping the game.
A sample can be one call out of date; it cannot crash the game, and one sample is only one
vote among many. It reads through method handles checked once when it starts, waits on a
repeating high-resolution timer, and reuses the text of a stack it saw the sample before,
so its own thread does little besides reading and its garbage in the game's heap stays
small.

When something does not fit, the profiler is what stops, and only it:

- The game loop reaches the profiler through one small relay that needs nothing but Java's
  base module. While no recording runs it is one read per frame, and the recorder and the
  flight recorder behind it are not even loaded. Whatever the recorder throws during a
  recording ends that recording's frame marks (the game's log says so once); the state
  observer that times backups, which shares the per-frame call, carries on. A game whose
  Java runtime lacks the flight recorder refuses to start a recording and nothing else.
- The hook in `GameWindow.logic` is one call added at its start, through Java's standard
  retransformation: changes other Java agents made to the class stay, and if another
  agent retransforms it later, the call is put back on top of theirs. The class hierarchy
  this needs is read from the class files rather than by loading classes inside the
  transformation, which could disturb another agent's; loading is the last resort. A
  failure to put the call back is counted in the bridge's diagnostics.
- The per-thread allocation counter is a setting of the whole JVM. It is on by default;
  if another agent turned it off, a recording turns it on and turns it off again at its
  end.
- Other users of the flight recorder can record at the same time. While a PZ Tools
  recording runs, its sampling rate applies to theirs too, as the flight recorder works
  with the most detailed setting any recording asks for.

## Reading the result

The recording tools share the title line: record, mode, which recording, which thread,
and a **…** menu with *Open recording*, *Save as*, *Open folder* and *Delete*. In a narrow
window they move below the title. What the recording is doing appears under that line only
while a recording starts, runs or is being processed.

The frame graph stays in place; drag the handle under it to make it taller or shorter. The
line above the graph describes the range the results show: its start, end and length,
then the frame count (how many frames the range holds, not frames per second), the average
frame time, the same average as a frame rate (*FPS 7.4*), slowest and worst 1 %, names
muted and numbers not. It keeps to the frames, so it stays one line in every language. A
range of one frame shows that frame's time alone. Resting the pointer on the line adds the
sample count and recording mode; while the pointer is over the graph the line shows the
time and frame under it instead. The **?** beside it lists the graph's mouse controls.

Under the graph, a line carries the range's other figures, the memory ones in their lines'
colours: heap peak, video memory peak, and garbage collections (*GC 3 times, paused
120 ms*). A collection stops the game without leaving samples, so the tables cannot show
it; this is where it shows. Over either graph the figures follow the pointer: the
collections that overlapped the frame there, and memory at that moment. The copied text
starts with the range line followed by these figures.

The results are in tabs, *Scripts (Lua)* and *Game code (Java)*, and *Memory allocation*
for recordings that have allocations. Each tab is split in
two: owners on the left (mods, the game's scripts, parts of the game code, with a bar
relative to the largest and the share with two decimals), and the chosen owner's functions on the right as a table with a
heading over every column. The owner list has headings too, and the one over its numbers
says what they are when the pointer rests on it: in *Scripts* (*Range time*) the share
of the range a mod's scripts were running, game functions they called included, with the
figure for all scripts together beside the heading; in *Game code* (*Run share*) the share of the game
code's running time, where game functions called from Lua count as the base game. *Long
waits and pauses* shows a count with its unit instead of a share. Above the table, on the line of the tabs, stand the owner's
name and its samples out of the tab's, such as *Samples 9/70*. The **Copy text** button beside the
name puts what the page shows on the clipboard as text (the recording, the range,
the tab's owner list with its headings, and the chosen owner's table, columns lined up), ready to paste into a
message to a mod's author. The
chosen owner stays chosen when the range changes, if it is still there. The *Game code*
tab also lists *Share by thread* (with *All threads*) and *Long waits and pauses*. In a
narrow window the table moves below the owner list; in a wide one the owner list is as
wide as the tabs above it need.

A part of the game code's table reads like a script owner's list: method, package, *Self*
and *Total* as parts of the group (the group being 100%), the same gauges, two decimals,
and the methods past the first 30 gathered into one closed *N more* row with their sum.
It counts the samples that ended in the group's own code, so a method's *Total* is what it
and the group's code it called took, never more than the group; a method that only called
into other groups, such as the game loop, has no row. Resting the pointer on a number
gives its part of all the running time. A light group's parts can look large: PZ Tools'
own code, for one, is usually around a tenth of a percent of the game thread.

*Memory allocation* has the same owners as *Scripts*, ranked by the bytes the game thread
allocated while their functions ran (*Allocated*, with all scripts together beside the
heading; resting the pointer on the heading adds the whole game thread's figure, scripts
or not, which tells whether the scripts or the game's own code make more garbage). The
table gives each function's *Self* and *Total* in bytes, as the time tab gives them in
time. To find who makes the collections in a stretch of play, open the memory panel,
drag over the stretch where the grey bars crowd, and read this tab. Recordings made
before allocations were recorded have no such tab.

In both script tabs the table starts as a call tree; the **Call tree** switch beside the
owner's name turns it into a plain list of functions and back. The tree shows the samples
by the path that led to them: the outermost Lua function on top (an event
handler, or the game's script that called into the mod), and under each function what it
called, indented, with an arrow to open or close it (a click anywhere on the row does the
same). The tree starts closed; what is opened or closed stays so for other ranges of the
same recording. In *Memory allocation* the paths are ranked by bytes and those that
allocated nothing are left out. The choice of list or tree holds while the app runs, and
a copy carries the tree as indented text. A path deeper than the 24 innermost functions
the recorder keeps starts at the 24th. The list is still the way to see a helper that
many paths call: the tree splits its cost among them, the list adds it up.

Tree and list count the same samples, those that ended in the chosen owner's functions,
and their percentages are parts of the owner, the owner being 100%: the question there is
where inside it the time went, and parts of a long range shrank to 0.0%. They have two
decimals. The top rows of the tree add up to 100%, and so do the list's *Self* figures.
Past the first 20 rows of a level (30 in the list) the rest are gathered into one closed
row, *N more*, that carries their sum, so the rows on screen visibly add up; open it for
the rest. Behind each *Total* a gauge shows the same part at a glance: a faint track the
width of the column, so the number always sits in it, and a fill in exact proportion to
the table's largest total. Behind each *Self* a grey gauge measures something else: the
row's own work as a part of its own total, full for a function that did the work itself
and empty for one whose time went into what it called. Resting the pointer on a number gives its part
of the whole range and the time it stands for (*2.1% of the whole range, about 1.14 s*),
so a large part of a light owner is not mistaken for a heavy one; in *Memory allocation*
the bytes stay and the pointer gives their part of the owner. *Samples* in the tree are
those that passed through the row, in the list those that ended in the function. Each
heading says what its column means when the pointer rests on it.

- **Frame graph.** One bar per slice of time, as tall as the slowest frame in that slice,
  so a single spike stays visible at any zoom. Bars above 33.3 ms (below 30 frames per
  second) are highlighted. The scale stops at about twice the 95th percentile of the
  bars in view (never below 33.3 ms), so a loading frame of seconds does not flatten the
  ordinary ones; taller bars reach the top with a **▲**, their time on hover. The scale
  is rounded up in fine steps (…, 250, 300, 400, 500 ms), so the bars fill the graph. As
  it follows each recording, dashed lines at 60 FPS (16.7 ms) and 30 FPS (33.3 ms), over
  the bars and named at the right, give it a fixed meaning: a bar above the 30 FPS line
  is a stutter on any computer. A line too close to the floor or to the other is left
  out.
- **Highlight.** Clicking an owner in the *Scripts* or *Game code* list (a mod, the
  game's scripts, a part of the game code) fades every bar and draws, solid inside it,
  how much of the same frame that owner's code ran: a mod that costs a little every
  frame and one that spikes every few seconds look different at once. Clicking it again
  stops; clicking another moves the highlight there, and a small graph mark beside the
  owner's figure says which is drawn. While one is drawn, pointing at another owner
  shows that one until the pointer leaves, to compare without clicking. Over the graph,
  the line above it adds the owner's time in the frame under the pointer. It counts the
  samples taken in that frame (the game thread's, for game code), so it moves in steps of
  a sampling period: coarse for short frames in Standard mode, fine in Detailed mode. A
  new recording starts with nothing highlighted; *Memory allocation*, in bytes, has
  none. Wheel zooms
  around the pointer, right-button drag or the scroll bar moves, double-click shows
  everything.
- **Memory panel.** When the recording has memory readings or garbage collections, the
  **Memory** button on the line under the frame graph opens a second, short graph with a
  row for each it has: the Java heap in use (green) on top, the collections (grey) in the
  middle, under the heap whose drops they cause, and the game's video memory on the
  graphics card (text colour) at the bottom. The memory rows are lines fitted to their own
  lowest and highest reading in view, as their sizes differ too much for one scale and a
  fitted one shows small changes. Each collection is a bar as long as it paused the game
  (at least two pixels) and as tall as that pause against the longest one in view, so a
  frame spike above a tall bar is a frame the game spent collecting; the bars are drawn as
  one shape, as a game may collect several times a second. Each row's name stands at its
  top left in the row's colour (*Heap in use*, *GC pauses*, *VRAM*), and resting the
  pointer on the name says how to read the row; the ends of its scale stand at the left
  of the graph. The panel shares the frame graph's margins and
  time axis: zoom, scrolling, the selection and the pointer line move both, and a range
  can be dragged on either. It stays open or shut while the app runs. Closed, it takes no
  room.
- **Range.** Drag to select a range, or click to select one frame. With nothing selected
  the whole recording is analysed, in the background; choosing another range stops the
  analysis of the previous one.
- **Shares.** *Self* is time spent in the function itself, *Total* includes what it
  called; resting the pointer on either heading says so. Every row shows its sample count. A warning appears below 20 samples: a single
  16 ms frame holds one or two Standard samples, so one frame is only meaningful in
  Detailed mode or when it is a long one.
- **Grouping.** Lua functions are grouped by owner: each mod (from the `mods/<name>/`
  part of the script path), the game's own scripts (`media/lua/...`), and *unknown origin*
  when the path does not say. Java methods are grouped by package: base game (`zombie.`),
  Lua engine (`se.krka.kahlua.`), Java built-ins, PZ Tools, and bundled libraries for
  everything else. A Java mod is not guessed from its package name; it appears under
  bundled libraries.
- **Threads.** The default view is the game thread. *All threads* includes rendering,
  loading and background threads, each sample weighted by its own sampling period.
  A thread inside a native call is sampled whether it works there or only waits, so
  samples of known waits (for a connection or data, a selector, a completion port, a
  timer, a lock, the scheduler, and PZ Tools' own timed waits) are left out of every
  share; drawing, file access and other native work still count. Resting the pointer on
  the line above the graph says how many were left out. *Share by thread* shows its
  samples as a count of their own, as they are not a part of the chosen thread's.

Percentages are estimates. A sample stands for the usual gap between samples of its
kind, measured from the recording itself, because the recorder cannot always keep the
requested period.

## Files

Each recording is one file, `%LOCALAPPDATA%\PzTools\profiles\profile-<date>-<time>.pzprof`.
*Open recording* copies a `.pzprof` file from elsewhere into that folder, keeping its
time, and lists it with the others; a file that is not a readable recording is refused
and nothing is copied. *Save as* copies the selected recording to a place you choose.
Recordings are not written to the log or telemetry databases; those only receive the
start, finish and failure of a recording, which is what the operation card and the log
page show.

The file is gzip-compressed text: tables of method names and stacks, then samples that
refer to them by number. Identical stacks are stored once.

What a recording contains, if you pass a file on: it contains Java method names, thread names, mod
folder names, Lua script paths from `mods/` or `media/` downward, and file *names* of
slow reads and writes. It does not contain folders above those (which would include the
Windows user name), save contents, or chat. A script file's top-level code, which Lua
names after the file's full path, is kept under the file's name alone; recordings made
before that was done are shown the same way, though their file still holds the path. The raw flight recording that the game
writes first does contain full paths; it is converted and deleted as soon as the
recording ends, and leftovers of an interrupted run are deleted when the next recording
starts.

## Processes

`PzTools.Profiler.Cli record` is one process per recording. It asks the game to start
(`PROFILE_START`), waits for the stop file, the time limit or the game's exit, asks the
game to stop (`PROFILE_STOP`) and converts the flight recording with the bundled Java
runtime, outside the game. The app only starts this worker and reads the finished file.
If the app or the worker is closed mid-recording, the game stops recording at the time
limit and also stops sampling Lua and timing frames, so an abandoned recording costs
nothing afterwards. The next recording ends any leftover first.

## Limits

- Only a local game process started normally is supported; the recorder attaches the
  same way the save bridge does. See [game-save bridge](save-bridge.md).
- Time spent inside native code (rendering driver, physics, sound) is attributed to the
  Java method that called it, not to anything inside the native library.
- A thread that is asleep or waiting produces no samples. In Detailed mode long waits are
  listed under *Long waits and pauses* instead.

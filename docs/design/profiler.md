# Performance recording

[Documentation index](../README.md) · [User guide](../../README.md) · [Glossary](glossary.md)

The **Performance** page records what the running game is doing and shows where the time
went: which part of the game, which mod, which function. Nothing is measured unless a
recording is running or *Keep the last minutes* is on.

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
(30 minutes in Standard mode, 10 minutes in Detailed mode; see the advanced settings
under [Hotkeys](#hotkeys)).

**Start recording** is available while exactly one game is running, or before the first
check has answered; the page checks every two seconds, and resting the pointer on the button says what is missing. Nothing
is logged for that. If the game closes just as a recording starts, the recording's card
says so and the log keeps it as information (`run.unavailable`), not as an error. A
recording that really fails is logged once, by the recording itself, and its card gives
the reason. When the game still runs a bridge bootstrap from before an update that this
build cannot use, the card says plainly that the game needs one restart to record, rather
than the general "could not connect"; an update that keeps the bootstrap compatible needs
no restart at all (see [compatibility](game-bridge.md#compatibility-and-lifecycle)).

| Mode | Java samples | Lua samples | Extra |
| --- | --- | --- | --- |
| Standard | every 10 ms | every 10 ms | garbage-collection pauses and runs, Java heap use, video memory, memory allocated by scripts, CPU used each second (the game's and the machine's) |
| Detailed | 1 ms requested, about 1.5–2 ms in practice | every 1 ms | the above, and lock waits, parked threads, slow file reads/writes, JVM stop-the-world operations |

Memory is recorded in both modes. The **Java heap** (used, committed and maximum) is read
by the game's own recorder four times a second. **Video memory** cannot be measured from
inside the game: the app reads the game process's figures from Windows five times a
second while anything records, a recording asked for or the last minutes (the
per-process *GPU Process Memory* counters, the same numbers as Task Manager's GPU memory
columns: on the graphics card, and system memory the card borrows), matched to the game
by its process id, so other programs' use is left out. It keeps the last minutes, and all
of a recording under way. Every recording written, either kind, passes through one step
that adds the readings of its span to its end on the recording's time scale. Saves of the
last minutes made before version 0.2.4 have none: until then only the recording worker
read it, and only for recordings asked for. Where Windows has no such counters (before
Windows 10 1709, or a driver that does not report them), the recording simply has no video
memory. Neither tells how much of what is held each frame actually uses.

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

### The last minutes

A stutter is often over before a recording could be started. **Keep the last minutes**,
under *Settings > Performance*, has the game record all the time and hold only its last
few minutes: 1 to 10 of them (2 at first), in Standard or Detailed mode, both set there.
**Save last 2 min** (with the number set) stands beside **Start recording**, whose arrow
chooses the mode for recordings only.
Press it right after a stutter, and those minutes become a recording like any other,
listed and opened at once. While Detailed is kept, the button says so (*Save last 2 min ·
Detailed*), as that mode slows the game for as long as it is on.
The game goes on keeping the next ones. Changing the mode or the length restarts the
keeping that way; the button's tip says which mode is kept, or why there is nothing yet
(no game, the game's bridge needs a restart). While the setting is off there is nothing
to save, so the button reads *Turn on last minutes →* instead and opens Settings at that
switch, with the keyboard on it. A key set for it is named in the button's tip.

The game started later, or restarted, gets it within five seconds, whether or not the
page is open. **Start recording** runs beside it, so reaching for the record button after
a stutter loses nothing: the last minutes are still there to save, during the recording
and after it. The two may be in different modes. While either is in Detailed mode the
game is sampled at Detailed's pace; each file is taken back to its own mode as it is
converted, so a Standard one reads as if it had run alone. The setting is kept, so it
starts again with the app; it ends when switched off, and while the app is closed nothing
records the game: the recording lasts while the app run that asked for it holds its lease in
the game (see [leases](game-bridge.md#leases)), so an app that crashed or was ended from the
Task Manager does not leave it recording for more than two minutes.

The cost is that of a recording that never ends. Standard mode is light; Detailed mode
costs the game frame rate for as long as it is on (about 20%: frames came out a quarter longer in one test on one PC; the app says about 20%), so
use it while hunting a stutter, not all evening. A longer window costs the game nothing
more, only disk. The game's timer resolution stays at 1 ms while it is on. Older data is
discarded a piece at a time on disk, so a save holds somewhat more, which is cut to the
window as it is converted; at most 256 MB is held (`rolling_max_megabytes` below), which
a long Detailed window can reach, and then holds less. Saved minutes have no video
memory, which only a recording worker reads.

### Hotkeys

The game has the keyboard when it stutters, so the app's actions can have keys, set under
*Settings > Hotkeys* by pressing them: save the last minutes, start or stop a recording,
switch the next recording between Standard and Detailed (the same choice as on the page;
one under way keeps its mode, and the note says *Next recording: Detailed*), turn the
last minutes on or off, back up the save being played, turn automatic backups on or off
(the settings' own switch, as if flipped there: nothing turns them on again by itself),
and show the status. Only saving the last minutes has a key at
first, Ctrl+Shift+F9. While the app runs, Windows gives each set combination to it alone,
so a key another program uses is refused when it is chosen, and one taken later is
marked on its card. A letter or digit needs Ctrl or Alt with it; function keys may stand
alone. Saving the last minutes holds its key only while they are kept.

Nothing of the app shows over the game, so each key answers twice: with Windows' own
sounds (heard; done; or its error sound, the reason then waiting in the app), and with a
short note over the character's head, like the backup countdown's, in the app's
language: *Saved the last 2 min*, *Backup complete*, *Next backup · 04:30 remaining · Last backup
6 min ago · Keeping the last 2 min*. The notes come from a fixed list the game itself
holds, with a number at most: the app cannot put other text into the game. The status note says what the sidebar's line says at that moment, the remaining time in minutes and seconds as it shows there, or *Automatic backups after a game restart* while they wait for one. At the main
menu there is no one to show a note to, and the sounds alone answer. A saved recording is
listed and opened in the app without bringing it in front of the game.

The advanced settings file (`config\app\default.toml`) holds the rest: `[profiler]`
`general_limit_minutes` and `detailed_limit_minutes` (when a forgotten recording ends by
itself) and `rolling_max_megabytes`; `[hotkeys]` `sounds` and `game_notices`.

## What depends on the game version

| Part | Source | If the game changes |
| --- | --- | --- |
| Java stack samples, native-call samples, GC and pause events, heap use | The JVM's own flight recorder (`jdk.jfr`) | Unaffected: it depends on Java, not on game code |
| Video memory | Windows performance counters, read by the app | Unaffected: it depends on Windows and the graphics driver |
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

The tools stand on two lines, each saying only what differs from the usual. The title's
line holds making a recording, at its right: **Save last 2 min** and **Start recording**,
whose arrow chooses Standard or Detailed (the button names Detailed while it is chosen;
a key set for a button is in its tip). The next line is the recording shown: its name,
a pencil to rename it, a bin to delete it (after asking), *Compare with*, and a **…**
menu with *Open recording*, *Save as*, *Save selection* (while a range is selected) and
*Open folder*. In a narrow window the
recording tools move below the title and the buttons keep their icons alone, their names
as tips. What the recording is doing appears under these lines only while a recording
starts, runs or is being processed.

The line above the graph shows the range, the average and the worst 1%; the frame count
and the slowest frame are one hover away and in the copied text.
Beside them, which thread the results count, the game's or all of them: a choice for the
whole analysis, both tabs. The chosen owner's table is a card of its own, level with the
owner list's card; its line above sits level with the tabs: the owner's name, the search
button, the **Call tree** switch, **Copy for AI**, and last its samples out of the tab's. In
a narrow window the line and the card come under the owner list, and the samples and the
copy's label give way first.

The frame graph stays in place; drag the handle under it to make it taller or shorter. The
line above the graph describes the range the results show, every number with its name:
*Total 80.37 s* for the whole recording, or *Selection 8.20 s (12.30–20.50 s)* for a
selected part, its length first and where it lies after. A selection shows as a chip with
a ✕, like an active filter, which stays while the pointer reads frames off the graph beside it: pressing it, or Escape anywhere on the page, clears the
selection and the results describe the whole recording again (the zoom stays; *Show all*
and a double-click only zoom out and keep the selection). Then *Average 23.6 FPS (42.4 ms)*
and *Worst 1% 4.0 FPS (251.6 ms)*, both as a frame rate first, which is how players read
them, and the frame time the graph is scaled in after. Names are muted and numbers not. It
keeps to the frames, so it stays one line in every language. A range of one frame shows
that frame's time alone. Resting the pointer on the line adds the frame count (how many
frames the range holds, not frames per second), the slowest frame, the sample count and
recording mode; while the pointer is over the graph the line shows the
time and frame under it instead, and while dragging a selection, the range being drawn
(its length, where it lies, its frames, and under the graph its memory figures), so the
size of the drag reads as it grows. The **?** beside it lists the graph's mouse controls.

Under the graph, a line carries the range's other figures, the memory ones in their lines'
colours: heap peak, video memory peak, and garbage collections (*GC 3 times · working 4.12%*; a pause long enough to feel, 2 ms or more,
adds *GC pause 120 ms*). A collection stops the game without leaving samples, so the tables cannot show
it; this is where it shows. With ZGC, the game's default, those pauses are well under a
millisecond however short memory is: the collector works beside the game instead, on the
CPU the game would use. So the line also gives how much of the range the collector was at
work (*working 85.40%*, two decimals, from each collection's whole run, overlaps counted once; absent in
recordings made before 0.2.4) and how many times any thread stopped until memory was freed
for it (*Waited for memory 12 times, longest 0.42 s*). A collector at work nearly all the
time, or threads waiting for memory, say the game is short of memory, which its pauses
never would. Over either graph the figures follow the pointer: the
collections that overlapped the frame there, and memory at that moment. The copied text
starts with the range line followed by these figures.

Above the tabs, a thin bar splits the range's time on the game thread four ways, with
their shares beside it: *Scripts* (mods' and the game's scripts running, the game
functions they called included), *Game code* (the game's own code running), *Memory stop*
(the game stopped for memory: the collector's pauses where they fell, and the game thread
waiting for memory to be freed, overlaps counted once; a recording from before the pauses
were kept has the collections' totals instead) and *Waiting* (the thread waiting: for the next frame
usually, or, in a stutter, stuck on a file or another thread). The four add up to the
range. *Memory stop* is shown only from 0.5% of the range: with ZGC, the game's default,
it stays near nothing even when memory runs short, as the collector slows the game while
it works rather than stopping it (in a test at 3 GB against 16 GB, frames about 40% longer,
with no stop at all), and always on the bar it only read as noise. What running short
costs shows instead on the frame graph and the memory line (below). It answers at a glance whether a stutter was the scripts, the game or the memory,
which adding up the two tabs cannot: they count the same time two ways (below). The bar
follows the frame graph: while a mod is drawn over the graph (clicked in *Scripts*, or
pointed at while another is drawn), it stands apart within the scripts' part, solid
beside the lighter *Other scripts*, with its name and its figure from the list: how
much of this stretch was that mod. With none drawn, the bar is the whole range's. It is shown for the game thread with enough samples, and goes into the
copied text. Resting the pointer on a part's legend says what it counts
and its time in the range (for *Memory stop*, also how much of the range the collector was at
work beside the game, which ZGC's pauses never show); on the legend or the bar, it draws that part of each frame
on the graph in the part's colour, on the terms the bar uses, in place of a highlighted
mod while the pointer stays: which frames of a stutter were scripts, game code, memory or
waiting.

The results are in tabs, *Scripts (Lua)* and *Game code (Java)*, and *Memory allocation*
for recordings that have allocations. Each tab is split in
two: owners on the left (mods, the game's scripts, parts of the game code, with a bar
relative to the largest and the share with two decimals), and the chosen owner's functions on the right as a table with a
heading over every column. The owner list has headings too, and the one over its numbers
says what they are when the pointer rests on it: in *Scripts* (*Range time*) the share
of the range a mod's scripts were running, game functions they called included, with the
figure for all scripts together beside the heading; in *Game code* (*Run share*) the share of the game
code's running time, where game functions called from Lua count as the base game. The
same two facts stand under each tab's list, on the page and not only one hover away: read
the other way, a mod that called heavy game functions seemed lighter than one that only
counted, as players found. *Long
waits and pauses* shows a count with its unit instead of a share. Above the table, on the line of the tabs, stand the owner's
name and its samples out of the tab's, such as *Samples 9/70*. **Copy for AI** beside the name copies a Markdown report for a
chat with an AI model, the way most players ask what a recording means, or for a mod's author. Its menu names
what each holds, so nothing has to be chosen first (an owner is always shown in the table, and the graph's
highlight is often off). *Whole report* is the range, the same whatever the page has open: the recording and the range,
the frames, where the thread's time went, memory and CPU, the twelve heaviest mods and the functions of the
five heaviest with each one's file and heaviest line, the Java areas and heaviest methods with who called them
up to the game's code, Lua allocations, threads (all threads only) and the longest pauses; a few lines on how
to read the figures come first. *Detailed report: <name>* is the owner shown in the table, by its name, alone in
full, after the same few lines on the recording, frames and memory: a mod's functions (25), the
heaviest lines of its heaviest ten, the call tree that reached them (outermost first, each with the line of
its caller, branches under a hundredth of the mod summed up) and what its functions allocated; an area's
methods and who called the heaviest. *Save as a file* below them offers the same two as a Markdown file (named for
the recording, and the owner for its report), for a report too long to paste or to attach. For the threads and the pauses only the whole report is offered. Compared with another recording, a report says what with and puts the baseline's
figure and the change beside each comparable one (frames, the time's parts, mods, functions, Java areas and
methods, in percentage points of each range; allocations per minute; the baseline's memory in a line), with
the mods that moved the most and a caution when the two were recorded in different modes. Reports are in
English with invariant numbers, a format rather than a page: a model reads them as well in whatever language
it is then asked, and two reports read alike. The
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
a mod's own report carries its tree as an indented list. A path deeper than the 24 innermost functions
the recorder keeps starts at the 24th. The list is still the way to see a helper that
many paths call: the tree splits its cost among them, the list adds it up.

The *File* column names the line the function ran itself the most, as `Client.lua:125`
(in *Memory allocation*, where it allocated most): what to change, not only where. The
file reads as a link. Pressed, it finds the script on this PC from the path the recording
keeps (a Workshop mod under Steam's libraries, a mod in the player's own *mods* folder,
the game's own scripts under its install, each only inside its own folder and only a
`.lua` file) and shows the full path, wrapped, with a copy button beside it, then *Open*,
*Open line N in VS Code* (where VS Code is installed, through its own `vscode://` link) and *Show in folder*,
all through Explorer, so neither the editor nor VS Code starts with the app's administrator rights. The file name
is in the table's own colour; the pointer's hover shows it is a button. A script not on this PC (a recording made on
another, a mod removed since) says so and leaves only the copy of the recorded path; one
changed since the recording warns that its lines may have moved. In the
list, a function's row opens into all its lines, most samples first; a line it only
called from is marked *(call)*, as its time is the called function's. In the tree, a node
opens into what it called, the heaviest first, and after them one closed row, *Lines it
ran itself · 25*, opening into the lines where it did its own work, the most first; the
lines it called from are its children's rows already, and resting the pointer on a
child's file says which line of its caller called it. A line's *Total* counts the samples
that found the function there, whatever it had called from that line, once per sample
even if a recursion passed the line again; its *Self* those where it was running the
line itself. So in the list a function's lines' *Samples*, those that ended there, add up
to the function's, and in the tree a node's lines' samples add up to the node's. *Line
unknown* is a frame the game gave no line for.

The **search** button (or Ctrl+F) opens a box where the button is, the owner's name giving
way to it; it narrows the
table to the rows whose name or file holds the text, in any case; in the tree it keeps the
paths that lead to a match, opened down to it. It applies to the game code's methods and
the threads too, and holds while other owners and ranges are shown. The box stays open as
long as it holds text, so a narrowed table always shows why; Escape clears and closes it,
and leaving it empty closes it.

**Comparing two recordings.** *Compare with* on the title line lists the other
recordings; pick one, say from before a mod was added or updated, and the shown range is
compared with the whole of it. A long recording takes a few seconds to read; meanwhile the
button turns a small ring and says it is loading, and its ✕ takes the choice back. A
comparison already shown stays until the new one is ready, and stays if the choice is
taken back. There
is no bar of its own: the button then names the
recording compared with, in the accent colour, with a ✕ beside it to stop, and each figure
carries its change where it stands. On the line above the graph the average and worst 1%
frame rates are followed by ▲ (more frames per second, green) or ▼ (fewer, red), their
before → after one hover away; the scripts' part beside the list's heading by how many
points it moved. The
owner list in *Scripts* and *Game code* gains a small figure beside each part, and the
table a *Change* column: how many percentage points of the range's time the owner or the
function gained (red) or lost (green) against the same one there. Parts are compared, not
times, so recordings of different lengths compare; a function is the same one by its name
and its file from *media/lua/* on, so a mod moved from the workshop to a local copy, or
updated, still matches. In the tree a row is matched by its whole path; a path the other
recording never took counts as all gain. *Memory allocation* is not compared, as its bytes
depend on how long each recording ran. The comparison stays while other recordings and
ranges are shown; press the ✕ beside the button, or choose *Stop comparing*, to end it.
To compare with a part of a recording only, save that part first with *Save selection*.

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
  the bars and named on a pill in the scale's margin (a scale value it would cover gives way), give it a fixed meaning: a bar above the 30 FPS line
  is a stutter on any computer. A line too close to the floor or to the other is left
  out.
- **Highlight.** Clicking an owner in the *Scripts* or *Game code* list (a mod, the
  game's scripts, a part of the game code) fades every bar and draws, solid inside it,
  how much of the same frame that owner's code ran: a mod that costs a little every
  frame and one that spikes every few seconds look different at once. While it is drawn
  the scale fits the owner's parts, found the same way as the frames' (spikes cut and
  marked with ▲), since a mod is usually a few milliseconds of a frame and would lie
  along the floor on the frames' scale; the faint frames behind reach the top where
  they are longer. Clicking it again
  stops; clicking another moves the highlight there, and a small graph mark beside the
  owner's figure says which is drawn. While one is drawn, pointing at another owner
  shows that one until the pointer leaves, to compare without clicking. Over the graph,
  the line above it adds the owner's time in the frame under the pointer. It counts the
  samples taken in that frame (the game thread's, for game code), so it moves in steps of
  a sampling period: coarse for short frames in Standard mode, fine in Detailed mode. A
  new recording starts with nothing highlighted.

  The memory panel's heap, collections and video memory are the whole game's and cannot
  be split by mod. What can is the memory a mod's scripts allocate: when a mod (or the
  game's scripts) is highlighted and the recording has allocations, the panel gains a
  row of it under the collections, one bar per moment against the most in one of them,
  so garbage that piles up just before collections points at that mod. *Memory
  allocation* highlights the same way: there the row is the point, and the frame graph
  shows the same mod's time. Parts of the game code have no such row, as allocations
  are recorded for scripts only. Wheel zooms
  around the pointer, right-button drag or the scroll bar moves, double-click shows
  everything.
- **Memory panel.** When the recording has memory readings or garbage collections, the
  **Memory** button on the line under the frame graph opens a second, short graph with a
  row for each it has: the Java heap in use (green) with the collections (grey) under its
  line, as they are its drops, then the highlighted mod's allocations when there is one,
  and the game's video memory on the graphics card (text colour) at the bottom. The
  collections' figure puts their marks and the collector's background away and back when
  clicked, for as long as the app runs, and stands faint while they are away; the heap's and
  video memory's figures only read: the panel opens and shuts as a whole. A collection that
  stopped the game for 2 ms or more is also marked on the frame graph itself, panel open
  or not: a dashed line up the graph and a small triangle on its floor in the alert
  colour, and the frame under the pointer names the pause. The many short ones stay the
  panel's; with none marked, the stutters are not the collector's. The memory rows are lines fitted to their own
  lowest and highest reading in view, as their sizes differ too much for one scale and a
  fitted one shows small changes. Each collection is a bar as long as it paused the game
  (at least two pixels) and as tall as that pause against the longest one in view, so a
  frame spike above a tall bar is a frame the game spent collecting; the bars are drawn as
  one shape, as a game may collect several times a second. Under the heap they take the
  row's lower part, and the scale at the left is the heap's. Each row's name stands at its
  top left in the row's colour (*Heap in use · GC pauses*, *VRAM*), and resting the
  pointer on the name says how to read the row; the ends of its scale stand at the left
  of the graph. The panel shares the frame graph's margins and
  time axis: zoom, scrolling, the selection and the pointer line move both, and a range
  can be dragged on either. Until the player opens or shuts it, it opens by itself for a
  recording that ran short of memory (the line says so) and stays shut for the others;
  after that it stays as chosen while the app runs. Closed, it takes no room. The button
  is in the text's own colour: the page has colours enough; its hover and chevron show it is one.
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
- **Who called a Java method.** A Java method with time of its own opens onto its callers,
  bottom up, the heaviest first: a JDK method such as `HashMap.getNode` read in the game's
  terms. Its stacks run some 27 frames deep, the outer ones always the same, so a call tree
  from the top would have to be opened a long way before anything differed. A chain of
  callers that never branches is one row (`Cache.wrap ← Game.update`), ending at the first
  of the game's own methods (`zombie.`); up to there, callers with a tenth or more of the
  method's time open by themselves, and the game method's own callers are a click away.
  Callers under 0.5% of the range are gathered in one line. They are worked out in the
  background when the row first opens (*Finding callers…* meanwhile: they walk every sample
  of the range), then kept for the range and thread shown. Each caller's figure is a share
  of the group, as the method's is; its tip says what it is of the method's own time. A
  method called from Lua shows Lua as its caller: which Lua
  function asked is not in the Java stack. The interpreter's frames between such a call and
  the game code that ran the script (the Lua engine's own, and the game's `LuaCaller` glue)
  are one step, *(Lua running)*: `HashMap.getNode ← LinkedHashMap.get ← (Lua running) ←
  Event.trigger`.
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
The list names it by what it is: *Last 2 min · Today 3:43 PM*, *Recording 1 min 20 s ·
Detailed · Yesterday 9:10 PM* (Standard, the usual mode, goes unsaid; older ones show
their date). What a recording is lies inside it, its length at its very end, so each is
read once in the background and kept in `%LOCALAPPDATA%\PzTools\profiles-index.json`, by
file name, size and time; until then it is listed by its time. The pencil right beside the
list renames the selected recording in place: type over the name, Enter or clicking
elsewhere keeps it, Esc does not, and an empty name gives it an automatic name again, from
when the file was written. The name
is the file's, so whoever is sent the file sees it too, ahead of the rest: *mod A added ·
Recording 3 min · Today 3:43 PM*. Characters a file name cannot hold become `_`, and a
name already taken gets a number: *mine (2)* for a name of yours, *profile-…-2* for an
automatic one, which stays known as automatic.
*Open recording* copies a `.pzprof` file from elsewhere into that folder, keeping its
time, and lists it with the others; a file that is not a readable recording is refused
and nothing is copied. *Save as* copies the selected recording to a place you choose.
*Save selection* saves the range selected on the graph as a recording of its own beside the
others, named after this one and the range: *mod A added (12.30–20.50 s)*, and shows it
at once (unless another recording was opened meanwhile; the **…** button turns a ring while it
saves). Its analysis shows the very figures the range showed: its records are the source's, those
outside the range left out by the rules the analysis counts a range by (a collection or
pause that reaches into it stays, as do the allocation readings either side of it), and it
says which range it is and what a sample stood for in the whole, which a few seconds would
not measure again. Stacks and functions only the rest referred to are left out too, so a
short range makes a small file. It is then a recording to compare with, so a clean stretch
can be the baseline, or the first half of a recording compared with its second; and a file
to pass on. A version from before this reads such a file too, measuring its span and
periods from what it holds, so its figures may differ slightly for a very short range.
What is judged on a whole recording (whether the game ran short of memory) is judged on
the range alone, as it is now a recording of its own. A source with a damaged table is
refused rather than written as a file that would not open, and a save cut short leaves a
`.tmp` file that the next save clears once it is an hour old.
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
If the app closes or crashes mid-recording, the game ends the recording two minutes later,
when the app run's lease lapses (see [leases](game-bridge.md#leases)); if only the worker is
closed, at the time limit. Either way it also stops sampling Lua and timing frames, so an
abandoned recording costs nothing afterwards. The next recording ends any leftover first.

The last minutes are kept by the game between short commands, each one process:
`roll-start` (`PROFILE_ROLL_START`, a mode, how many seconds to hold and, optionally, the
most megabytes to hold), `roll-save`
(`PROFILE_ROLL_SAVE`: the game writes what it holds to a flight recording, which is
converted cut to its window, as a recording is) and `roll-stop` (`PROFILE_ROLL_STOP`,
which ends only the rolling recording, never one someone started; `PROFILE_STOP` likewise
ends only the one asked for). They wait only for each other, not for a recording's worker,
as the two recordings run side by side in the game: the flight recorder takes each event
once for both, the frame marks, Lua sampler and timer resolution are shared, and the
converter thins a file's samples back to its own mode's period and leaves out the waits
only Detailed mode records. Starting and stopping
show no card; a save shows as a recording does. A game whose bridge refuses `roll-start`
(one from before it, or one that cannot attach) is not asked again until it restarts or
the settings change; the button's tip gives the reason.

A hotkey's note is one more short command, sent by the app itself:
`NOTICE <language> <item> ...`, each item a key of the game's own list of notes
(`src/PzTools.GameBridge.Agent/notices.tsv`, compiled into the bridge), optionally with
`:number`. The game refuses any other key, a number where the note has none, or none
where it has one, and answers at once; the note is shown on the game thread through the
same per-frame relay the recording uses.

A recording in which the game ran short of memory (allocation stalls, or a heap standing
nearly full) says so above the memory graphs, with a link to the game's memory setting; see
[game memory](game-memory.md#on-the-performance-page). The line adds what it cost, as the
recording measured it: how much longer frames were while the collector was at work than
while it was not (*frames 17% slower while GC ran*), from 5% and with at least 20 frames of
each. On the frame graph, a light orange background marks the collector's runs, behind the
bars, so its frames read against those beside it. Its key is the orange square in front of
the collections' figure, first on the memory line beside the *Memory* button; pressing the
figure puts the background away with the pause marks.

A recording during which other programs kept the machine busy (on average 35% or more of
all its processors, beside what the game used) says so on the same line (*Other programs
used 55% of the CPU on average*). A busy machine slows the game whatever its mods: in a
test, a data job running beside the game more than doubled its frames. Recordings made
before CPU use was kept say nothing.

## Limits

- Only a local game process started normally is supported; the recorder attaches the
  same way the game bridge does. A game started with attaching turned off cannot be
  recorded, and the app says so. See
  [when attaching fails](game-bridge.md#when-attaching-fails).
- Time spent inside native code (rendering driver, physics, sound) is attributed to the
  Java method that called it, not to anything inside the native library.
- A thread that is asleep or waiting produces no samples. In Detailed mode long waits are
  listed under *Long waits and pauses* instead.

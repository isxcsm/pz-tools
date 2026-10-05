# Performance recording

[Documentation index](../README.md)

The game samples itself while a recording runs; a worker converts the result outside the game; the app reads the
file and analyses any range of it on demand. Nothing is sampled, hooked or held while no recording runs and
**Keep the last minutes** is off. The screen is described in [the Performance page](../reference/performance-page.md)
and its use in [Find a laggy mod](../guides/find-a-laggy-mod.md).

## Components

| Part | Runs in | Job |
| --- | --- | --- |
| `ProfileControl` ([bridge runtime](../../src/PzTools.GameBridge.Agent/java/pztools/bridge/runtime/)) | Game (bridge payload) | `PROFILE_*` commands, the app's leases, the per-frame relay slot |
| `ProfileRecorder`, `ProfileFrames` | Game | JFR recordings, the Lua sampler, frame events, timer resolution; `ProfileFrames` is the per-frame relay and needs only `java.base` |
| `ProfileExport` | Bundled JRE (`runtime\bin\java.exe -Xmx512m`) | Converts a `.jfr` file to `.pzprof` |
| [`PzTools.Profiler.Cli`](../../src/PzTools.Profiler.Cli/Program.cs) | Worker process | `record`, `roll-start`, `roll-save`, `roll-stop` |
| [`ProfileRecordingService`](../../src/PzTools.App.Core/ProfileRecordingService.cs), [`VideoMemoryLog`](../../src/PzTools.App.Core/VideoMemoryLog.cs) | App | Starts workers, keeps the last minutes armed, reads video memory, names and lists files |
| [`src/PzTools.Profiling`](../../src/PzTools.Profiling/) | App | Reading (`ProfileRecording`), analysis (`ProfileAnalysis`), reports (`ProfileReport`), saved ranges (`ProfileTrim`), video memory (`ProfileVideoMemory`, `GpuProcessMemory`) |
| [`ProfilerPage`](../../src/PzTools.App/ProfilerPage.xaml.cs) | App UI thread | The page |

## Sampling

### Java: the flight recorder

The JVM's own flight recorder (`jdk.jfr`) takes the Java samples. It depends on Java, not on game code, so a game
update cannot break it. `ProfileRecorder.configured` enables these events:

| Event | Standard | Detailed |
| --- | --- | --- |
| `jdk.ExecutionSample` (running Java) | 10 ms requested; about 10.5 ms in practice | 1 ms requested; about 1.5 ms in practice |
| `jdk.NativeMethodSample` (inside a native call) | 20 ms | 10 ms |
| `jdk.GarbageCollection`, `jdk.GCPhasePause`, `jdk.ZAllocationStall` | Yes | Yes |
| `jdk.GCHeapMemoryUsage` | Every 250 ms | Every 250 ms |
| `jdk.CPULoad` (game and machine), `jdk.CPUInformation` | Every second, every chunk | Same |
| `jdk.ActiveSetting` (the periods in force) | Yes | Yes |
| `jdk.JavaMonitorEnter` ≥ 1 ms, `jdk.ThreadPark` ≥ 2 ms, `jdk.FileRead`/`FileWrite` ≥ 1 ms, `jdk.ExecuteVMOperation` ≥ 1 ms | No | Yes |

"In practice" is the median gap between one thread's consecutive samples in recordings of the game (Build 42 on its
Java 25, Windows, `timeBeginPeriod(1)` in force): 1.50–1.56 ms for a 1 ms request (one gap in ten over 1.8–2.6 ms),
10.5–11 ms for 10 ms. JFR does not keep a short period exactly, so `EffectivePeriod` (below) weighs each sample by the
gap actually measured in the file.

Detailed costs the game about 20% frame time: about seven times as many Java samples and ten times as many Lua samples
(the Lua sampler wakes every millisecond), and the wait events, each of which records a stack. Its finished file is
about five times as large (4.6–4.8 times for two-minute recordings of the same play), which is why its default limit is
shorter (below).

JFR's native code cannot write to a temporary folder whose path has non-ASCII characters (a Korean user name gave
empty recordings). `plainRepository` then moves the repository to `%ProgramData%\PzTools\jfr\u-<user hash>`.

### Lua: the sampler thread

`LuaSampler` runs on its own thread (`PzTools-lua-sampler`) and reads the Kahlua call stack of `LuaManager.thread`,
then `UIManager.defaultthread`, without stopping the game. A read can be one call out of date; it cannot crash the
game. Access goes through method handles checked once at start; a missing or retyped field leaves the recording
without Lua (`lua` = `unavailable`).

Each `pztools.LuaSample` event holds up to 24 innermost frames (and at most 4096 characters) as
`name|file|line`. Labels are cached per prototype
and an unchanged stack reuses the previous string, so the sampler makes little garbage in the game's heap. Once a
second a `pztools.LuaSampler` event gives the ticks taken and how many found Lua.

The sampler waits on a repeating high-resolution waitable timer (`PreciseWait`), not `Thread.sleep`, which Windows
rounds up to the 15.6 ms tick. It keeps its period closely: in recordings of the game the ticks taken over time (the
`LH` reports) come to 1.04–1.12 ms for Detailed's 1 ms and 10.1–10.3 ms for Standard's 10 ms. While any recording
runs, `TimerResolution` also calls `timeBeginPeriod(1)` so JFR's own sampler stays near its period (above) instead of
the 15.6 ms tick; it is undone when the last recording ends.

### Frames and allocations

Frames come from the game-loop hook in `GameWindow.logic` (see [the game bridge](game-bridge.md)). The per-frame
callback (the state observer's, or the profiler's own relay when nothing observes) calls `ProfileFrames.tick` every
frame. While no recording runs and no note waits, that costs two field reads, and the recorder and JFR classes are not
even loaded. During a recording, each tick commits a `pztools.Frame` event for the previous frame.

Allocations come from the JVM's per-thread counter (`ThreadMXBean.getThreadAllocatedBytes`) for the game thread, read
by the Lua sampler at each tick. The bytes since the previous tick go to the Lua function found running, as the
sample's time does, so they are an estimate in the same way. The once-a-second event also carries the game thread's
whole allocation. If another agent turned the counter off, the sampler turns it on and back off at its end. A runtime
without `jdk.management` gives a recording without allocations.

### What depends on the game version

| Part | Source | If the game changes |
| --- | --- | --- |
| Java and native samples, GC, heap, CPU | JFR | Unaffected |
| Video memory | Windows counters, read by the app | Unaffected |
| Frame boundaries | `GameWindow.logic` hook | Recording works without a frame graph (`hasFrames` false) |
| Lua functions and mods | `LuaManager.thread`, Kahlua call frames | Recording works without Lua |
| Allocations by script | Per-thread counter, read by the Lua sampler | Needs the Lua sampler, the frame hook (which names the game thread) and `jdk.management` |

### Failure isolation

- Whatever the frame mark throws detaches that recording's mark and logs once to the game's log (`[PzTools profiler]
  Frame marks stopped`). The state observer that times backups shares the per-frame call and carries on.
- A runtime without JFR refuses to start a recording and nothing else.
- Other JFR users can record at the same time. JFR samples at the finest period any running recording asks for, so
  theirs get PZ Tools' rate while a PZ Tools recording runs.
- A payload replacement (`runtimeReloadRequested`) closes every recording and releases the relay before the old class
  loader goes.

## The recording asked for

`PzTools.Profiler.Cli record` is one process per recording:

1. Sends `PROFILE_START <path> general|detailed <seconds> [owner]`. JFR gets a duration of `--max-seconds`, a 512 MB
   size cap and `dumpOnExit`. A leftover recording (`already-recording`) is stopped and the start retried.
2. Prints `PROFILE recording <lua> <frames>` for the app, then waits for the stop file, the time limit or the game's
   exit. `endedBy` records which: `stop`, `limit` or `game-exit`.
3. Sends `PROFILE_STOP` (unless the game exited), then converts the `.jfr` file and deletes it unless `--keep-raw` is
   given. That switch is for diagnosis only; the app never passes it, because the raw file holds full paths.

The app passes `--max-seconds` from `general_limit_minutes` or `detailed_limit_minutes` in the `[profiler]` section
of its [advanced settings](../reference/advanced-settings.md#app). Without it the worker uses 600 seconds. The game
accepts 5 to 1800 seconds.

Recording control shares the bridge's short request channel with saving. A `busy` answer is retried every 500 ms: for
20 seconds when starting, 180 seconds when stopping, because a stop that gives up would leave the game recording until
its limit. Raw `*.pzprof.jfr` files over an hour old are deleted when the next recording starts.

If the app crashes or is killed, its [lease](game-bridge.md#leases) lapses after two minutes and the game's monitor
thread stops the recording. A recording that reached its JFR duration with nobody stopping it releases the shared
sampler, frame marks and timer (`wrapUpIfEnded`). No game, more than one game, or `restart-required` is logged as
`run.unavailable`, not as a failure.

## The last minutes

**Keep the last minutes** keeps a second, rolling JFR recording in the game between short worker commands:

| Command | Bridge request | Effect |
| --- | --- | --- |
| `roll-start --mode --seconds [--max-megabytes] [--owner]` | `PROFILE_ROLL_START` | Replaces any rolling recording; `maxAge` = window (10–600 s), `maxSize` = 64–2048 MB, 256 by default (`rolling_max_megabytes`) |
| `roll-save --output --seconds` | `PROFILE_ROLL_SAVE` | JFR dumps what it holds; the worker converts it, cut to the window |
| `roll-stop` | `PROFILE_ROLL_STOP` | Ends the rolling recording only, never the one asked for |

JFR drops old data a whole chunk at a time, so a dump holds more than the window. The worker notes when it asked for
the save and passes `keepFromEpochMillis` = that time minus the window; the converter skips earlier events (still
reading `jdk.ActiveSetting` from them) without a first pass to find the end. At the size cap a long Detailed window
holds less than asked.

`ProfileRecordingService` keeps it armed: every 5 seconds it checks for exactly one game and starts the rolling
recording if the game is not keeping it in the wanted mode and length, so a game started or restarted later gets it
whether or not the page is open. A start the bridge cannot do (old bridge, refused attach) is not retried for the same
game and settings; other failures are retried after 10 seconds, doubling up to 5 minutes. A lease gap longer than 120 seconds means
the game has dropped it, and it is started again.

### Two recordings at once

Both recordings can run together. JFR writes each event once to every recording that enabled it, so each file holds
the other's events for the time they overlapped. The frame marks, Lua sampler and timer resolution are shared, and the
Lua sampler runs at the finer of the two periods. The converter takes each file back to its own mode from the `mode`
argument:

- Java and native samples: `SamplingRounds` groups samples less than 300 µs apart into one JFR round, and while rounds
  come faster than the file's period keeps only the first round in each period-long slice.
- Lua samples: each event carries its tick number and period; a coarser file keeps one tick in `target / period`, and
  the bytes of dropped ticks carry over to the next kept one.
- A Standard file drops the Detailed-only wait events.

## Video memory

The game cannot measure its video memory, so `VideoMemoryLog` reads the game process's `GPU Process Memory` counters
(the Task Manager figures) every 200 ms while anything records. It keeps the rolling window plus 5 seconds and
everything since a recording asked for began. Every finished file, either kind, goes through
`ProfileRecordingService.Finish`, which appends the readings of its span as `V` records (`ProfileVideoMemory.Append`).
Without the counters (before Windows 10 1709, or a driver without them) the file has none.

## Hotkeys

Hotkeys work while the game has the keyboard because [`GlobalHotKeys`](../../src/PzTools.App/GlobalHotKeys.cs)
registers them with `RegisterHotKey`; Windows then gives each combination to the app alone, and refuses one another
program holds. The keys are in [settings](../reference/settings.md#hotkeys); the sound and note switches are in
[advanced settings](../reference/advanced-settings.md#app).

A key answers with `MessageBeep` sounds and, optionally, a note over the player's head: the bridge command
`NOTICE <language> <item>...`, up to four items of `key` or `key:number`.
[`GameNotices`](../../src/PzTools.GameBridge.Agent/java/pztools/bridge/runtime/GameNotices.java) builds the text only from
the catalog compiled from [`notices.tsv`](../../src/PzTools.GameBridge.Agent/notices.tsv) and refuses unknown keys and
mismatched numbers, so the app cannot put free text into the game. The note shows on the game thread through the
per-frame relay; at the main menu the answer is `no-player`.

## The recording file

`.pzprof` is gzip-compressed UTF-8 text, one tab-separated record per line, first line `PZPROF	1`. Identical stacks
are stored once and referred to by number. Records are in no time order (JFR does not store events in order), thread
names and most `I` lines come last, and the reader does not depend on order. Times are microseconds from the first
event the converter read.

| Record | Fields | Meaning |
| --- | --- | --- |
| `I` | key value | Information (below) |
| `T` | thread name | A thread |
| `M` | id label | Java method, `package.Class.method` |
| `K` | id m m m … | Java stack, innermost first, at most 64 frames |
| `S` | time thread stack J\|N | Sample: running Java, or inside a native call |
| `F` | time duration | One game frame |
| `LM` | id name file | Lua function; a file's top-level code is named by file name only |
| `LK` | id f:line … | Lua stack, innermost first |
| `L` | time stack | Lua sample |
| `LA` | time bytes | Game thread's allocation for the `L` at the same time |
| `LH` | time taken inLua periodMicros | Lua sampler totals since the previous `LH` |
| `GA` | time bytes | Game thread's allocation since the previous `GA` |
| `G` | time pause name cause | Garbage collection, its pauses summed |
| `GR` | time duration | The same collection's whole run |
| `P` | time duration kind thread detail | Pause or wait: `GCPhasePause`, `ZAllocationStall`, and in Detailed the wait events; detail is the GC phase, a monitor or park class, a file *name*, or a VM operation |
| `H` | time used committed max | Java heap |
| `CL` | time jvmUser jvmSystem machineTotal | CPU shares of all processors over the last second |
| `HW` | threads | Hardware threads |
| `V` | time dedicated shared | Video memory, appended by the app |

`I` keys: `mode`, `lua`, `hasFrames`, `endedBy` (`stop`, `limit`, `game-exit`, `rolling`, `range`), `toolVersion` (from
the worker); `gameThread`, `collectorRuns`, `javaPeriodMicros`, `nativePeriodMicros`, `durationMicros`,
`startEpochMillis`, `samples`, `frames`, `luaSamples` (from the converter, at the end). `I collectorRuns 1` says the
converter writes `GR`, so a file without `GR` had no collection rather than an older converter. With a known mode the
periods are that mode's, not the settings in the file, which may be the other recording's.

Compatibility rules: the reader skips unknown record kinds, and new data goes in new record kinds (`LA`, `GA`, `GR`,
`CL`) rather than new fields, so an older reader still reads a newer file. A different first line is refused.

### What a file contains

Java method and thread names, mod folder names, Lua paths from `mods/` or `media/` down (`ProfileExport.luaPath`, with
`workshop/<item>/` for Workshop mods), and file names of slow reads and writes. Not the folders above them, which carry
the Windows user name, nor save contents or chat. Older files may still hold a full path in a top-level chunk's name;
the reader shows the file name only.

### Reading

`ProfileRecording.Read` loads the whole file, rebases time 0 to the earliest sample, frame or Lua sample, sorts every
list and clips heap and video readings to that span. It refuses references to missing table entries and files over 40
million records. `ReadSummary` reads only the `I` lines; the list caches them in `profiles-index.json` beside the
`profiles` folder, keyed by file name, size and time.

A sample weighs its effective period, because JFR does not keep the requested one. `EffectivePeriod` is the median gap
between a thread's consecutive samples (gaps over four periods ignored, at least 50 gaps), clamped to one to four times
the request. The Lua period is the time between `LH` reports over the ticks taken, since `L` records exist only for
ticks that found Lua.

### Saved ranges

`ProfileTrim.Save` (**Save selection**) writes a range as a recording of its own, by the rules the analysis counts a
range by: point records with `from ≤ time < to`, spans (`G`, `GR`, `P`) that reach into it, and the `GA` readings
either side. It reads the source twice (once to find the table entries the range uses, once to write them renumbered).
`rangeFromMicros`/`rangeToMicros` fix the span, and `*PeriodEffectiveMicros`, `collectorPauses` and `collectorRuns`
carry the source's measurements, so the new file shows the figures the range showed. A source with a missing table
entry is refused. A `.pzprof.tmp` left by an interrupted save is deleted by a later save once an hour old.

## Analysis

[`ProfileAnalysis`](../../src/PzTools.Profiling/ProfileAnalysis.cs) answers questions about a range of a loaded
recording.

### Shares

`Analyze` counts each stack's samples first, then walks each stack once. Native
samples whose innermost real method is a known wait (`WaitingMethods`: socket and selector waits, completion ports,
`sleep`, `park`, `Object.wait`, PZ Tools' own timed waits) are left out of everything, and counted in
`WaitingSamples`.

- Java shares are of the chosen thread's running time: the summed weight of its non-waiting samples. Method groups
  (`GroupOf`: `zombie.` game, `se.krka.kahlua.` Lua engine, `java.`/`javax.`/`jdk.`/`sun.`/`com.sun.` Java,
  `pztools.` tools, anything else libraries) add up to 100%. A group's rows count only samples that ended in that
  group's code, so a row's total never exceeds the group.
- Lua shares are of the range's wall-clock time: samples times the Lua period over the range length, capped at 1.
  Owners come from `OwnerOf`: the folder after `mods/`, `(game)` for `media/…`, `(unknown)` otherwise.
- A method or function that appears twice on one stack counts once for that stack.
- Callers (`CallersOf`) use the same whole as the method shares, so the root's share equals the method's own share.
  Interpreter frames (`se.krka.kahlua.`, `zombie.Lua.LuaCaller.`) collapse into one `(lua)` step. A caller whose only caller carries all its
  samples joins it in one row, up to six methods; a library chain stops at the first game method it reaches.
- `RunningShare` is the thread's running weight over the range; null for all threads, whose times overlap.
- Across recordings a Lua function is matched by `ScriptKey` (its name and its file from `media/lua/` on), so a mod
  moved between Workshop and a local copy, or updated, still matches; `MatchCallTrees` matches tree nodes level by
  level. Shares are compared, not times, so recordings of different lengths compare.

`TimeBreakdown` splits one thread's range into scripts, game code, memory stop and waiting. Memory stop is the
collector's pauses plus the thread's own allocation stalls, overlaps counted once (`MemoryStopIn`); scripts are the Lua
share; game code is running minus scripts; waiting is the rest. Where the two samplers disagree, scripts win.

### Memory figures

| Function | Rule |
| --- | --- |
| `CollectorBusyIn` | Part of the range covered by merged `GR` spans |
| `StallsIn` | `ZAllocationStall` count and longest |
| `MemoryPressure` | Short when there is any stall, or at least a quarter of heap readings (8 or more) stand at ≥ 90% of the maximum; judged on the whole recording |
| `FramesWithCollector` | Average frame with the collector working ≥ 50% of it against frames with none; a ratio only with 20 of each |
| `OtherProgramsCpu` | Mean of machine CPU minus the game's |

### Caches

The frame graph calls the per-bucket functions for every bar on every pan, zoom and pointer move, so per-recording
lookups are built once and held in `ConditionalWeakTable`s keyed by the recording:

| Cache | Holds |
| --- | --- |
| `WaitingStacks` | Whether each stack is a wait |
| `MemoryPauses` | Collector pauses and stalls in time order, with the longest (the search window) |
| `CollectorSpans` | Merged collector runs |
| `FunctionOwners`, `MethodGroups` | Owner of each Lua function, group of each method |
| `FunctionIndexes` (in `ProfileReport`) | Lua function index by name and file |

## Reports

[`ProfileReport.Build`](../../src/PzTools.Profiling/ProfileReport.cs) writes a range as Markdown for **Copy for AI**,
always in English with invariant-culture numbers: it is a format, models read it equally well in any language, and two
reports read alike. After a how-to-read header come the recording, frames, time breakdown and memory. Then either the
whole range (12 mods, functions of the top 5 at 0.5% or more, Java areas, 15 methods with callers of the top 5,
allocations, threads, pauses) or, with a `ProfileReportFocus`, one mod or Java area in full (25 rows, heaviest lines, call tree down
to 1% of the owner). With a baseline each comparable figure carries the baseline's value and the change in percentage
points.

## UI threading

Loading, analysing, callers, reports, saving a range, import and export run in `Task.Run`; the UI thread only shows
results. A new range cancels the running analysis (checked every 4096 samples) and a version counter drops stale
results. The whole recording's analysis is kept per thread, so clearing a selection is instant. Callers are worked out
when a row first opens and kept for the range and thread shown. The frame graph's per-bucket functions run on the UI
thread and stay cheap through the caches above and binary search.

## Limits

- Only a local game the bridge can attach to; see [when attaching fails](game-bridge.md#when-attaching-fails).
- Time inside native code counts for the Java method that called it.
- A sleeping or waiting thread leaves no samples; Detailed lists long waits as `P` records instead.
- A Lua function that runs entirely between two ticks is not seen; its bytes go to whatever the next tick finds.
- A Lua stack deeper than 24 frames keeps only the innermost 24.

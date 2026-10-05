# Find a laggy mod

Lots of mods and the game stutters, but you can't tell which one? Don't pull them out one by
one. Record the stutter and look at what took the time.

## 1. Record the stutter

### If it happens now and then

Turn on **Settings → Performance → Keep the last minutes**. The game then always keeps its last
2 minutes. You won't feel it.

When it stutters, press **Ctrl+Shift+F9** in the game. A few seconds late is fine. You can
also press **Save last 2 min** on the **Performance** page.

A notice above your character says it's saving, and a few seconds later the recording is on
the **Performance** page.

[Screenshot: In game, the saving notice above the character]

### If you can make it happen

Press **Start recording** on the **Performance** page and play until it stutters. Driving, a
big crowd of zombies or a large base usually does it. Then press **Stop recording**. Half a
minute is plenty.

Leave the mode on **Standard**. **Detailed** shows more, but the game runs about 20% slower
while it records.

## 2. Select the stutter

Each bar in the graph is as tall as the slowest frame in it, so the tall ones are the stutter. Drag across them, and
everything below describes just that stretch. Press **✕** on the **Selection** chip, or Esc,
to go back to the whole recording.

[Screenshot: Performance page, a stretch of tall bars selected, the Selection chip above the graph]

## 3. What kind of time was it?

The **This range's time** bar splits the stretch into parts.

| Biggest part | What it means | Next |
| --- | --- | --- |
| **Scripts** | Lua scripts, from mods or the game itself | Go to step 4 |
| **Game code** | The game's own work, like zombies or drawing the world | Removing mods may not help much |
| **Memory stop** | The game stopped because memory ran out | Go to step 5 |
| **Waiting** | Mostly time left over before the next frame, which is normal | |

Point at a part and the graph shows where it was. Orange behind the bars means the game was
freeing memory.

[Screenshot: The This range's time bar with its legend, one part pointed at and shown on the graph]

## 4. Find the mod

The **Scripts (Lua)** tab lists **Base game scripts (vanilla)** and every mod, with how much
of the stretch each one took. Start with the ones at the top.

Select a mod to see which of its functions took the time. With **Call tree** on, as it is at
first, you also see what called them. Select a function's file to open it.

[Screenshot: Scripts (Lua) tab, a mod selected, its functions in the table with Call tree on]

Vanilla at the top is common, because mods call the game's own scripts all the time. Select
**Base game scripts (vanilla)** with **Call tree** on. The top rows show what started the
work. If one of them is in a mod's file (point at the file to see its path), that mod is your
culprit. Point at its **Total** to see how much of the stretch it cost.

The **Memory allocation** tab ranks mods by how much memory they create. A mod near the top
there makes the game run out of memory sooner.

## 5. Out of memory?

If the line under the graph says **Stopped N times for lack of memory** or **Memory nearly
full**, the problem is memory, not a mod. Press **Memory setting** next to it, or go to
**Settings → Game → Game memory**, and pick a bigger size. It takes effect the next
time you start the game. See [Give the game more memory](more-game-memory.md).

## 6. Make sure

Remove the mod you suspect, record the same thing again, and pick the earlier recording in
**Compare with**. Each mod then shows how much its share went up or down.

Loading screens or idle time can muddy the comparison. Select a clean stretch, save it with
**More → Save selection**, and compare against that instead.

## 7. Ask for help

**Copy for AI → Whole report** copies the stretch as a report you can paste into an AI chat.
**Detailed report** covers just the mod you have open, with its functions and call tree, and
is the one to send to the mod's author. **Save as a file** saves either one as a Markdown file.

You can also send the recording itself with **More → Save as…**. It has mod and script names
in it, but not the folders on your PC.

## Notes

- Nothing is measured unless you're recording or **Keep the last minutes** is on.
- The shares are estimates from regular readings, so don't read much into two mods with close
  numbers.
- You can change the in-game keys in **Settings → Hotkeys**.

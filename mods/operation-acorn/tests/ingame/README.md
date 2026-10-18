# In-game checks

Lua files that run in a running game from the debug console, for the final combined check. Each prints lines tagged
per file (`[p1value]`, `[p1shop]` ...) to `Zomboid\console.txt`; a check line ends in `ok` or `BAD`.

The game reads them through a junction: `C:\Users\<you>\Zomboid\Lua\oa` points at this folder. Make it once:

```powershell
New-Item -ItemType Junction -Path "$env:USERPROFILE\Zomboid\Lua\oa" -Target <this folder>
```

These need the developer sub-mod `OperationAcornDev` (id `OperationAcornDev`, folder `OperationAcornDev/` in this repo; it
requires OperationAcorn, is never published and is enabled only in test saves). With the game started with `-debug`, its
command channel (`OperationAcornDev/42/media/lua/client/OperationAcorn/Dev/Remote.lua`) runs them
without the console: `python ../tools/pzdev.py check p3_window.lua` prints the check's lines. `pzdev.py run "<lua>"` runs
any Lua, and the helpers of `OperationAcorn.Dev` (`OperationAcornDev/42/media/lua/client/OperationAcorn/Dev/Dev.lua`; the in-game dev
panel, F8 or the "OA Dev" button, drives the same functions) set up a scene: research ranks,
points, credits, trust, the hour, the speed, the weather, still zombies at offsets, facing, world sounds, alarms on the nearest house or car, closing the
windows and the console. `pzdev.py shot out.png` takes a picture of the game window. The channel unticks Break On
Error at each load (a Lua error then never stops the game in the debugger); ticked again by hand, an error stops the
game and the channel with it: `pzdev.py resume`. `pzdev.py restart` (or `launch`) closes and starts the game and returns
once in the save; `pzdev.py quit` only closes it (to change options.ini, the save's mods, the API's install); `pzdev.py watch` prints the game's events (menu, loading, game, error, exit) as they come, from the
log alone, for a background watcher; `pzdev.py wait game` waits for one.

Without the channel, define the loader in the Lua console after each save load (it reads `Zomboid\Lua\oa\<file>`):

```lua
function RUN(f) local r,t=getFileReader("oa/"..f,false),{} local l=r:readLine() while l do t[#t+1]=l l=r:readLine() end r:close() loadstring(table.concat(t,"\n"))() end
```

Then `RUN("p1_all.lua")` runs the economy checks one after another (an error in one is printed and the next runs).

## P1 economy (`p1_*.lua`)

Setup: a single-player world with the mod and PZ Extension API installed, one character with a record (the first hello makes it).
Some checks change the save's market or the record (they say so in their header): use a throwaway save.

| File | What it checks | Setup |
| --- | --- | --- |
| `p1_lib.lua` | helpers the others share | none |
| `p1_value.lua` | `OA.Value.info` on real items (food states, drainables, bags, drinks, furniture, cash), `accepts`, appraisal | none; it gives itself items |
| `p1_requests.lua` | the loot-table scan against NUMBERS 12, timing, the week's list | none |
| `p1_market.lua` | the index, a flight's supply drop, events, a month of days (changes the market) | throwaway save |
| `p1_shop.lua` | prices, tiers, limits, and every item type the catalog names against the game's scripts | none |
| `p1_pickup.lua` | the pickup hook: floor items tagged with their cell and entered in the codex (changes the record) | none |
| `p1_buildings.lua` | the building watch: counts and searched containers where the character stands, API against vanilla | stand in a house; open containers and run it again |
| `p1_events.lua` | the daily and ten-minute handlers, kills, the shred yield on real items | kill a zombie, then run it |

## P7 and P9: numbers, mission pieces, saves, tabs

| File | What it checks | Setup |
| --- | --- | --- |
| `p7_values.lua` | each numeric node from nothing to its ranks, as the game answers (most carried, inventory limit and load, a crate's capacity, worn discomfort, strain, poison, endurance, fatigue, a young tree's slowdown, the heavy load moodle), the API's combined values for the rest, the board's caps and costs, a reset | PZ Extension API on, a free square 2 east; empties the inventory and the upgrades (throwaway save) |
| `p9_items.lua` | a regular mission's piece carried, in a bag, on the floor, in a crate, in a car's trunk, gone; burnt (laid out again, the deadline kept); taking another mission once a week | a car loaded near for the trunk; changes the stage and the mission (throwaway save) |
| `p9_state.lua` | `P9_PART` 1: an adaptation, the S8F call and a title started, then `pzdev reload`; 2: all still there after the load; 3: after fast-forwarding past the adaptation, its point and the call kept once | throwaway save; fast-forward with the game's buttons (Lua's setGameSpeed does not change the speed) and no zombies near |
| `p9_tabs.lua` | the terminal within reach opened on `P9_TAB` (powered for the look, `P9_POWER_BACK()`), for a picture of each tab at a window size and language | a terminal within 3 squares |

## P6 gear and kits (`p6_gear.lua`)

| File | What it checks | Setup |
| --- | --- | --- |
| `p6_gear.lua` | the gear items against the vanilla ones they are modelled on, the shop stocking them, bag kits (with and without the API), vehicle storage and engine kits on the nearest vehicle (per-instance targets: two bags of one kind, the vehicle id), the voucher | stand within 6 squares of a car; throwaway save; `P6_CLEAN()` after |

## P4 zombie samples and missions (`p4_zombies.lua`)

| File | What it checks | Setup |
| --- | --- | --- |
| `p4_zombies.lua` | the sample items and their icons, the vanilla outfits the groups wear (no OA outfit), the shop and the first box, the API's zombie mark and hold hooks; then steps by hand: a zombie mission next to the character (`P4Z_MISSION("clear")` or `"target"`), the group brought and held (`P4Z_STATUS()`), kills counted (`P4Z_KILL(n)`), a corpse harvested once (`P4Z_HARVEST(precise)`), the group gone and brought again (`P4Z_AWAY()`, `P4Z_BACK()`), the world's marks of the mission (`P4Z_MARKS()`) | a record at stage 1 or above, open ground; throwaway save (it replaces the running mission) |

## P4 story stage 1 (`p4_stage1*.lua`, PLAN 2단계)

| File | What it checks | Setup |
| --- | --- | --- |
| `p4_stage1.lua` | the first call waiting for the terminal, the evidence mission at a temporary police post picked in the band (a building, used for the world), its stage planned and the envelope left to it; puts the character 30 squares from the site | a record, standing where the terminal is; throwaway save |
| `p4_stage1_after.lua` | the stage in the world: the notice by the entrance, the desk with the walkie-talkie (a radio?) and four chairs, boarded windows, the locked inner room, the officer's body with the key, the police car (door, battery), the envelope in the inner room, the officer lying fake dead; then `P4S_PICKUP()` and, a few seconds later, `P4S_WOKE()` (he gets up, the pickup monologue is kept) | after `p4_stage1.lua`, a few seconds for the chunks |

## The E2E director (`e2e_beats.lua`, E2E-DEBUG.md)

| File | What it checks | Setup |
| --- | --- | --- |
| `e2e_beats.lua` | each beat of `OperationAcorn.Dev.E2E` set in order, with the character moved: 01 the game's helicopter flying for the character and the first supply as it goes, 01L and 01N the supply at once with their plan's mode; the story beats' calls behind and to come, level, mission offered, the character by the base terminal, the box standing and filled with the beat's items only, the serum; the join beats' tier; X nothing; no title from a setting but the first supply's. `E2E_BEATS = { "02", ... }` runs some | a record with a base terminal; changes the save (`pzdev snapshot`/`restore`, or the backup); about 2 minutes |

## The story driven by hand (`story_lib.lua`, `st_*.lua`)

| File | What it does | Setup |
| --- | --- | --- |
| `story_lib.lua` | logs what reaches the player as `[st]` lines (titles, notices, monologues, calls started, the record's comms kept, questions asked) and makes the player's moves as the buttons do: `ST.use()` the terminal near, `ST.tab(id)`, `ST.missions()`, `ST.launch(option)`, `ST.call()`, `ST.seal()`, `ST.unseal()`, `ST.takeAll()`, `ST.placeTerminal()`, `ST.skip()`, `ST.yes()`/`ST.no()`, `ST.close()`, `ST.state()`; runs `st_hitch.lua` and `st_timing.lua` | RUN after each load |
| `st_hitch.lua` | a frame over `ST_HITCH` ms (400) printed as `[hitch]` with the hour and the place | (by story_lib) |
| `st_timing.lua` | the story's world work (Stage, Scene, StageGame, SceneGame, missions) timed: a call over `ST_SLOW` ms (10) printed as `[timing]` | (by story_lib) |
| `st_walk.lua`, `st_grab.lua`, `st_take.lua`, `st_door.lua`, `st_doors.lua` | walk to `ST_TO`; pick up what lies at `ST_AT` (`ST_TYPE`); take what is of `ST_TYPE` in the containers at `ST_AT` (a fridge's freezer too); list the doors near `ST_AT` and open the nearest locked one (`ST_OPEN`); every door of the active mission's building with its two rooms, lock and key ids | |
| `st_crate.lua`, `st_layout.lua` | the supply crates near and what is in them; the running mission's building as the stage reads it (rooms, doors, roles) | |

## R3 performance, before and after (`perf_r3.lua`, E2E.md 10.1)

| File | What it does | Setup |
| --- | --- | --- |
| `perf_r3.lua` | the hot paths and the one-offs of the world-query work, timed the same way on c0 (a4692230, before) and c1 (dev, after): the placing cursor and `Objects.clearSquare`/`isClear`, `Machines.tick`, BU's minute lookups, `Links.walk`, `FloorLines.wanted`, `Spawned.places`, the Senses alarm job and its two scans, `Dense.look`, `Towns.enter`, the API's map reads, `findClear`, `settleGround`, `pickSite`, the meteor site fit, the stage; each `[perf] <path> calls= total_ms= mean_us= p95_us= max_us=` (`n/a` where a build has not the path), the frames' p50/p95/p99/max and frames over 50 ms, the routes' lengths and hashes. It puts down and takes away its own machines, BU boxes and lines, alarms and the alarm node. `pzdev run "PERF_NAME='open' RUN('perf_r3.lua')"` marks a place (`open`, `town`), `pzdev check perf_r3.lua --follow 900` runs it; `python ../tools/perf_compare.py c0.txt c1.txt` sets two runs side by side; `../tools/perf-switch.ps1` switches the game's mods and API between the builds | single player, the Dev sub-mods on; the same save and the same two marked places for both builds; restore the save after (the stage and the meteor site build in the world); about 3 minutes |

## P10 round 3 (`p10_*.lua`, E2E.md chapter 10)

For the combined round-3 session: `pzdev check p10_all.lua` runs every area below one after another (about 6 minutes; each
prints `[p10x] <what> ok|BAD <values>` and `[p10x] end: N BAD`, the whole `[p10all] done: N BAD in M areas`), or run a file
alone with `pzdev check p10_<area>.lua` (it ends with `done: N BAD`). Setup: the throwaway save with the Dev mod and PZ Extension
API, the character on open ground with no zombies near. The checks that need the game to run on (a teleport, a minute, a title's
life) go on from the frames, so the file returns at once and its lines come as it goes. Everything is done on scratch records
(`p10_<name>_<n>`, taken away at the end) except where a file says it uses the real record (the eggs' minute event, the dense
look held back, the radio): those put it back. The character, the time of day, the speed, the god mode and the invisibility
are put back where a file changes them.

| File | What it checks | Notes |
| --- | --- | --- |
| `p10_lib.lua` | helpers (areas, steps from the frames, scratch records, capture of `OA.Sync.title/notice/sound`, title tap) | none |
| `p10_survey.lua` | the survey branch for each tree: the notice once, the call waiting, the zone after the call is played (site inside, off the middle, a dim survey circle on the map), the fragment taking it away, the handover variant (`C_<tree>_k`), a retired record keeping the zone; each drop site stood at: placed, loaded, floor, outside, no building, no water within 3, the API's land conditions, the fragment near, and whether it moved | the character goes to the three sites and back (~1 min) |
| `p10_restock.lua` | stock `floor(tier/3)+1` at tiers 1, 3, 6, 12; the weapon kits locked below 6; prices 20,000 / 40,000 / 80,000, the cart total, sold out (reason, card key and text); the window rolled by putting its start back (10 days, 35 days), nothing carried, prices back; a town 0.9, two 0.81; the real towns index (count, sizes) and two towns searched through, a new record taking the share by coming in | the clock is not touched |
| `p10_dense.lua` | the world list made once; the figures of the places and a grid of `min` x `chunks` for tuning `Dense.MIN` and `Dense.CHUNKS`; the maps' circles by tier and colour; a place cleared with zombies made round the character (baseline, half, 10%), the title, the kit restock +1, the second record inheriting | the character goes to the first uncleared place and back; some of the place's own zombies are removed |
| `p10_kits.lua` | damage, critical and repair kits fitted through `Gear.fitItem` to a bat, a pistol and a rifle: min/max/critical/condition, the notice, the tooltip lines, a part attached and detached (a part given 0.5 damage too); writes `oadev/p10_kits.txt` | the weapons stay for the reload |
| `p10_state.lua` | the record `p10_keep` and the world's `P10X` marks holding a restock window, dense marks, a survey zone and eggs; writes `oadev/p10_state.txt` | stays for the reload |
| `p10_grades.lua` | grade, designation (with the count past the top), address and the stamps for tiers 8, 10, 11, 12, 13, 14, 16, 17, 18 after the handover; before it | `P10_SHOW_GRADES = true` shows the stamps to you |
| `p10_eggs.lua` | the five eggs through `Eggs.settle` and the real formulas; the 07:30 radio on a scratch record, then on the real one through the game's minute event, and at the fastest speeds | the time is set to 07:29 / 07:24 and put back |
| `p10_titles.lua` | one title of each style through `OA.Titles.show`: real times at show and when the API reports it gone, the frames, the longest one, against the design table; a title cut by one with `now`; a pause in the middle of a stamp | ~3 minutes; the moments inside a title's life cannot be read from Lua, and the sounds are heard, not measured |
| `p10_all.lua` | the areas above in order, with `p10_state.lua` between the kits and the grades | |
| `p10_kits_after.lua`, `p10_state_after.lua`, `p10_after.lua` | after a save and `pzdev reload`: the kit weapons and the state record against the files written before, then taken away (`p10_after.lua` runs both) | run once after `p10_all.lua` |

Not scripted: how a hit or a shot damages (kits), the pictures (map circles, shop cards, title ink and timing against the lab),
the sounds of a title, a town searched through in the game, the dense place cleared by real kills, the survey call in the
terminal.

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

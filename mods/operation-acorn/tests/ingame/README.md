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
without the console: `python tools/pzdev.py check p3_window.lua` prints the check's lines. `pzdev.py run "<lua>"` runs
any Lua, and the helpers of `OperationAcorn.Dev` (`OperationAcornDev/42/media/lua/client/OperationAcorn/Dev/Dev.lua`; the in-game dev
panel, F8 or the "OA Dev" button, drives the same functions) set up a scene: research ranks,
points, credits, trust, the hour, the speed, the weather, still zombies at offsets, facing, world sounds, alarms on the nearest house or car, closing the
windows and the console. `pzdev.py shot out.png` takes a picture of the game window. With Break On Error on, a Lua
error stops the game in the debugger (the channel too): `pzdev.py resume`.

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

## P6 gear and kits (`p6_gear.lua`)

| File | What it checks | Setup |
| --- | --- | --- |
| `p6_gear.lua` | the gear items against the vanilla ones they are modelled on, the shop stocking them, bag kits (with and without the API), vehicle storage and engine kits on the nearest vehicle (per-instance targets: two bags of one kind, the vehicle id), the voucher | stand within 6 squares of a car; throwaway save; `P6_CLEAN()` after |

## P4 zombie samples and missions (`p4_zombies.lua`)

| File | What it checks | Setup |
| --- | --- | --- |
| `p4_zombies.lua` | the sample items and their icons, the two outfits, the shop and the first box, the API's zombie hooks; then steps by hand: a zombie mission next to the character (`P4Z_MISSION("clear")` or `"target"`), the group brought and held (`P4Z_STATUS()`), kills counted (`P4Z_KILL(n)`), a corpse harvested once (`P4Z_HARVEST(precise)`), the group gone and brought again (`P4Z_AWAY()`, `P4Z_BACK()`) | a record at stage 1 or above, open ground; throwaway save (it replaces the running mission) |

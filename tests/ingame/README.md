# In-game checks

Lua files run in a running game from the debug console. They print lines tagged per file (`[bu13]`, `[burack]` ...)
to `Zomboid\console.txt`.

The game reads them through a junction: `C:\Users\<you>\Zomboid\Lua\bu` points at this folder. Make it once:

```powershell
New-Item -ItemType Junction -Path "$env:USERPROFILE\Zomboid\Lua\bu" -Target <this folder>
```

After each save load, define the loader in the Lua console (it reads `Zomboid\Lua\bu\<file>`; the files call it for
each other by bare name):

```lua
function RUN(f) local r,t=getFileReader("bu/"..f,false),{} local l=r:readLine() while l do t[#t+1]=l l=r:readLine() end r:close() loadstring(table.concat(t,"\n"))() end
```

Then `RUN("bu_all.lua")` runs the logic checks of the solar and battery batches and of the plan's batches 1 to 4
(`bu_test12` to `bu_test22`; `bu_test21` is the water pump, sprinkler and filter, `bu_test22` the generators' noise).
`bu_test20` needs water producers: `bu_water20.lua` puts two part-filled rain barrels near the player and connects
them to the test panel, once. `BU22_KEEP=true` before `bu_test22` leaves its generators and the range shown for a
look; `BU22_CLEAN()` takes them away.

- `bu_combo.lua`, `bu_combo2.lua`, `bu_combo3.lua`: the combined check of the plan's batches 3 and 4 by hand. `bu_combo`
  gives the items and tools, puts a well, two seeded crops and a fuelled generator wired to the test panel down; the
  units are then installed and wired from their context menus. `bu_combo2` prints what they do and opens the water
  tab; `bu_combo3` starts the generator, puts a well east of the pump, turns RiskPlumbingUnpurified on and wears the
  filter down for its Replace option. `BUCOMBO3_CLEAN()` and `BUCOMBO_CLEAN()` take their things away.
- `bu_features.lua`: the sandbox's features page: each toggle turned off and on in `SandboxVars` at runtime, the passes
  run, and what is off checked inert and hidden (networks gone from the API, no load, no fill or draw, no tabs, rows or
  installs, recipes hidden), both utilities off together, then the plan's supply lines' switch in its three states and
  a producer's line under the mouse. Puts a pump, a sprinkler and a filter down and takes them away; each line "ok" or
  "BAD". Needs the test panel (`bu_setup.lua`) and tanks (`bu_water20.lua`) for the water and plan checks.
- `bu_loot.lua`: solar panels as loot (`BU.Loot`): the chance by room and container, the fill hook through the game's
  `OnFillContainer` event, nothing added with `SolarPanelLoot` at 0, Solar panels or Power off, or without room, then a
  tool store's storeroom crate filled `BULOOT_N` times (default 4000) and the panels counted against the chance. Needs
  no scene; each line "ok" or "BAD".
- `bu_spray.lua`: a spraying sprinkler near the player, its frames read over a second and a half (the spray going
  round); `BUSPRAY_CLEAN()` takes it away. A new sprite sheet needs the game restarted, not only the save reloaded.
- `bu_looks.lua`: the looks of the units and the box (sprites and overlays by state, an old save's box taking the
  console, the tripped lamp's blink frames), each line "ok" or "BAD"; `BULOOKS_CLEAN()` takes its units away. Needs the
  test panel (`bu_setup.lua`) and the game restarted after the sheet changed.
- `bu_switch.lua`: the box's main switch (off and on by its action; a change of units, the breaker reset
  and the server's minutes leaving it off with nothing running and no outage counted; the same producer carrying
  again once it is on; a trip together with it), the generators' rows and the bank hand-over's count for a faked state,
  then a generator scene it puts down and takes away (the low fuel told once across off and on, "Switch to solar", a
  generator switched on by hand while off carrying after it, the source falling short while off giving way to the
  generator on standby). Each line "ok" or "BAD"; a step a game minute, about fourteen, ending with "done". Needs the
  test panel (`bu_setup.lua`) and a free square outside near the player; not in `bu_all.lua`, as it waits.
- `bu_floors.lua`: floors in a tall building: how many floors a tier's zone reaches, a zone saved whole kept to them as
  the world starts, far rooms refused; last "water only from above" changed in play and back, taken once each. Each line "ok" or "BAD", ending with "done". Stand by the tower panel
  first (`RUN("bu_tptower.lua")`). Needs the tower panel: a tier 4 box on the ground floor of a building of 15 floors
  or more, its id in `ModData.getOrCreate("BUTOWER").panel`.
- `bu_room.lua`: the scene of `bu_attached.lua`, built: a 3x3 room onto the east wall of a map building near the
  player (wooden walls, a door frame and door, a floor, a roof of floor tiles above), a fridge and a sink in it, a
  fridge in the yard, the test panel in that building; the player is put inside. The room stays. The game's regions
  see a door only with its frame, and a roof only once the square below is told again; it does both.
- `bu_attached.lua`: a room built onto the test panel's building (`bu_room.lua` builds it; by hand, the script's header
  says how) and the game's `AllowExteriorGenerator`: what the game and the API give for the room (no room def, no API
  building, an enclosed roofed region), the room found and counted as the building's, its devices inside, in the box's
  lists and networks and switched off and on at the box; the device outside still outside; then the option on, off
  (outside devices unsupplied and held, the connect menu's reason, the room's devices still supplied), on again and
  unset. Each line "ok" or "BAD", ending with "done". Needs the test panel (`bu_setup.lua`); stand inside the room.
- `bu_nearest.lua`: the water policy drawn for real at the tower panel: a barrel on the ground floor and one a floor
  up; a draw takes the own floor's first though the one above is fuller, one at 97 percent first (before it spills),
  then on up once the own floor's is empty. Needs an app whose API has `"nearest"` (else the mod falls back to
  `"fullest"` and the first check says so). Stand by the tower panel first. Each line "ok" or "BAD", ending with
  "done".
- `api_power.lua`: the PZ Extension API's power networks by a handle of their own ("APITest"), not through the mod:
  generators it puts down, one network over them. In phases from the console: `APIT.far()` by the test panel puts
  generator F down; `APIT.site()` by the tower puts A, B and C down and, a step a game minute, switches by hand (out
  of service), a failover, a running-out, a source and `setEnabled`; `APIT.away()` goes to F and waits for C to run
  out where it is not loaded; save and load again there, then `APIT.again()` waits for F to run out; `APIT.back()` at
  the tower checks the out-of-service marks after the load. `APIT.clear()` at both places takes it all away. Each
  line "ok" or "BAD", each phase ending with "phase done"; about half an hour in all with the load.
- `bu_tp.lua`, `bu_tptower.lua`: move the player beside the test panel or the tower panel. `bu_features.lua` puts its
  units by the player: stand by the test panel first, or the plan spans the distance and its hover checks fail.
- `bu_test*.lua`: the checks of each batch. The older ones (`bu_test` to `bu_test11`) set up their own scenes in a
  test save that is gone; they are in the history (removed 2026-10-08).
- `bu_lib.lua`: helpers the checks share (`BUT`: a tagged `say`, number formats, the panel near the player, the
  first square around a place that a test takes, free outside squares, the mod's Lua folder). A check that uses them
  runs `RUN("bu_lib.lua")` first.
- `bu_setup.lua`, `bu_visual.lua`, `bu_noon.lua`: the test panel and its solar and battery scene.
- `bu_rack.lua`: helpers that put batteries in a rack's container and take them out.
- `bu_revive.lua`: a worn battery and the tools in the inventory with Electricity 4, and its context menu opened;
  `BUREVIVE_DONE=true` then running it again puts the level back.
- `bu_reload.lua`: loads changed mod files (`BU_RELOAD`, paths under `media/lua`) again in the running game, from the
  active mod's folder or `BU_LUA_DIR`.
- The rest look at one thing: `bu_diag` (the save's store), `bu_net` (the test panel's power network) and `bu_rackdiag`
  (each rack's container and records).

Files read with `getFileReader` lose non-ASCII letters: take Korean strings from `getText`.

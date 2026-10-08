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
- `bu_switch.lua`: the box's main switch (off and on by its action; quiet hours, a change of units, the breaker reset
  and the server's minutes leaving it off with nothing running and no outage counted; the same producer carrying
  again once it is on; a trip together with it), the generators' rows and the controller's count for a faked state,
  then a generator scene it puts down and takes away (the low fuel told once across off and on, "Switch to solar", a
  generator switched on by hand while off carrying after it, the source falling short while off giving way to the
  generator on standby). Each line "ok" or "BAD"; a step a game minute, about fourteen, ending with "done". Needs the
  test panel (`bu_setup.lua`) and a free square outside near the player; not in `bu_all.lua`, as it waits.
- `bu_floors.lua`: floors in a tall building: how many floors a tier's zone reaches, a zone saved whole kept to them as
  the world starts, far rooms refused; a sub-panel on the 13th floor linked with a line three tiles longer a floor,
  and a generator and a solar panel wired through it (offered first, one wire, the main panel's, its line as long as
  both); its water by height, and two booster pumps (the ground floor's and one wired through the sub-panel) lifting
  it, chained; then the link and the sub-panel taken away with the lines through them; last "water only from above"
  changed in play and back, taken once each. Each line "ok" or "BAD", ending with "done". Stand by the tower panel
  first (`RUN("bu_tptower.lua")`). Needs the tower panel: a tier 4 box on the ground floor of a building of 15 floors
  or more, its id in `ModData.getOrCreate("BUTOWER").panel`.
- `bu_nearest.lua`: the water policy drawn for real at the tower panel: a barrel on the ground floor and one a floor
  up; a draw takes the own floor's first though the one above is fuller, one at 97 percent first (before it spills),
  then on up once the own floor's is empty. Needs an app whose API has `"nearest"` (else the mod falls back to
  `"fullest"` and the first check says so). Stand by the tower panel first. Each line "ok" or "BAD", ending with
  "done".
- `bu_tp.lua`, `bu_tptower.lua`: move the player beside the test panel or the tower panel. `bu_features.lua` puts its
  units by the player: stand by the test panel first, or the plan spans the distance and its hover checks fail.
- `bu_test*.lua`: the checks of each batch. The older ones (`bu_test` to `bu_test11`) set up their own scenes in a
  test save that is gone; they are in the history (removed 2026-10-08).
- `bu_lib.lua`: helpers the checks share (`BUT`: a tagged `say`, number formats, the main panel near the player, the
  first square around a place that a test takes, free outside squares, the mod's Lua folder). A check that uses them
  runs `RUN("bu_lib.lua")` first.
- `bu_setup.lua`, `bu_visual.lua`, `bu_noon.lua`: the test panel and its solar and battery scene.
- `bu_rack.lua`: helpers that put batteries in a rack's container and take them out.
- `bu_revive.lua`: a worn battery and the tools in the inventory with Electricity 4, and its context menu opened;
  `BUREVIVE_DONE=true` then running it again puts the level back.
- `bu_reload.lua`: loads changed mod files (`BU_RELOAD`, paths under `media/lua`) again in the running game, from the
  active mod's folder or `BU_LUA_DIR`.
- The rest look at one thing: `bu_diag` (the save's store), `bu_net` (the test panel's power network), `bu_rackdiag`
  (each rack's container and records), `bu_flowdiag` (the open plan's flow paths).

Files read with `getFileReader` lose non-ASCII letters: take Korean strings from `getText`.

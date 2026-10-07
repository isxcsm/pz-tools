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

Then `RUN("bu_all.lua")` runs the logic checks of the solar and battery batches and of the plan's batches 1 to 3
(`bu_test12` to `bu_test20`). `bu_test20` needs water producers: `bu_water20.lua` puts two part-filled rain barrels
near the player and connects them to the test panel, once.

- `bu_test*.lua`: the checks of each batch. The older ones (`bu_test` to `bu_test11`) set up their own scenes in the
  test save and are kept as a record.
- `bu_setup.lua`, `bu_visual.lua`, `bu_noon.lua`: the test panel and its solar and battery scene.
- `bu_rack.lua`: helpers that put batteries in a rack's container and take them out.
- `bu_revive.lua`: a worn battery and the tools in the inventory with Electricity 4, and its context menu opened;
  `BUREVIVE_DONE=true` then running it again puts the level back.
- The rest look at one thing (`bu_net`, `bu_rackdiag`, `bu_where`, `bu_flowdiag`) or check one game fact (`bu_plumb`,
  `bu_rainbarrel`, `bu_handover`, `bu_relay`: the relay's click as a generator takes over; `bu_walllamp`: a lamp on an
  outer wall listed as the building's).

Files read with `getFileReader` lose non-ASCII letters: take Korean strings from `getText`.

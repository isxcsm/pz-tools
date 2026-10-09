# Extension API for Lua mods (in progress)

[Documentation index](../README.md)

> **In progress.** Built: the `PZToolsAPI` table, `version`, `client`, the
> [buildings](#buildings-facts) area, power [networks](#networks-mechanism) under `"sequential"` and
> water networks under `"fullest"` and `"nearest"`, with children, and food aged across supply changes
> ([built so far](#built-so-far)), and the [formulas](#formulas-mechanism) area (the body points, the load tree, the
> speed points, the survival points, the [hidden zombies](#the-hidden-zombies) and the [machines](#machines)), the
> [helicopter](#the-helicopter), the [zombies near a point](#zombies-near-a-point), the [sounds zombies make](#zombie-sounds), the [moodles](#moodles-mechanism) mods
> define and the [text](#text-mechanism) they show. Planned: `"parallel"`. The first areas serve a separate power
> and water mod, the formulas the
> talent mod. The game facts below were read from the
> bytecode and Lua of Build 42 (7 October 2026); the ones under [measured](#measured-in-the-game)
> were tried in the game with a throwaway probe.

PZ Tools changes the game through Java hooks ([game extensions](game-extensions.md)). Lua mods
cannot reach most of what those hooks reach, and what they can reach is often too slow to run often.
The extension API gives Lua mods that reach: it reports what the game knows, and it runs mechanisms
that are too slow or too far-reaching for Lua, such as utility networks. It holds no game content.
Panels, which objects join a network, distances, recipes, screens and balance belong to the mods
that use it.

The first users are two mods kept outside this repository:

- a power and water mod: panels that power and water whole buildings;
- the talent mod, later: spatial queries, carried weight and formula adjustments.

Both depend on the API. Neither has a variant that runs without it; without the API, a mod changes
nothing and says why.

## Principles

| Principle | Meaning |
| --- | --- |
| No content | The API speaks the game's terms and neutral ones: squares, buildings, objects, networks, producers, consumers, power, water. It never names a mod's concept and enforces no gameplay rule (how many of anything, how far, what joins what). |
| Facts and mechanisms | A call reads a game fact, or configures a mechanism that the API runs. The mechanism's policies are parameters chosen by the mod. |
| Declarative | A mod states what a network contains. It never registers a Lua callback that the game calls per square or per frame; hot questions are answered in Java. |
| Independent of chunks | A network works whether or not its squares are loaded. Its state is computed from time, not simulated frame by frame. |
| Narrow | No general reflection, file or process access. Any Lua mod can call the API, so nothing in it may reach outside the game. |
| PZ Tools owns the hooks | One owner per vanilla method, so two areas that touch the same class do not conflict. Mods see areas, not hooks. |
| Owned definitions | Each network belongs to the mod that created it (a name it passes once). A mod can only change or remove its own. |
| Vanilla unless declared | An answer differs from vanilla's only for what a mod declared: a network it built, a multiplier or rule it set. Anything no mod declared behaves as in vanilla. A declared change may give more or less than vanilla (more power, less carried weight, a device cut off). |
| Part of the install | The API is infrastructure, not a feature with its own switch: turning it off would cut every dependent mod's power at once. It exists only in a game the [startup loader](startup-loader.md) started, and it is always on there. A game the app attached to has no API. |
| Never fails closed | Other extensions are revoked when they fault. The API is not: a hook that cannot answer gives vanilla's answer for that call, and the API keeps running. A fault is reported, never turned into a power cut. |
| Single player supported | Single player is what is supported and tested. Multiplayer is not blocked, only untested: the API runs there as it does in single player, and only what would be wrong on a client (changing what producers hold) is refused. |

## Reaching the API from Lua

In a game the startup loader started, the resident runtime sets one global table, `PZToolsAPI`, in
the game's Lua environment (`LuaManager.env`) as the game's Lua starts, before any world loads. It is
not one of the extensions the player switches on and off, and it stays until the game exits. Its
functions are Kahlua `JavaFunction`s, so no class has to be exposed to Lua.

| Field | Meaning |
| --- | --- |
| `PZToolsAPI.version` | Integer, raised on any incompatible change. A mod refuses a version it was not written for. Now 1. |
| `PZToolsAPI.hooks()` | A table of the API's hooks in this game, by game class and method (`IsoGridSquare.haveElectricity`): `"applied"`, `"not-loaded"` (its class has not loaded yet; most load with the first world), or why it did not go in. Where a hook is missing, that question gets the game's own answer. |
| `PZToolsAPI.client(name)` | A handle for one mod; everything it defines belongs to it. `handle:clear()` removes it all. The name is 1 to 64 letters, digits, `_`, `.` or `-`; the same name gives the same handle. |
| `buildings`, `networks`, `formulas`, `moodles`, `text`, `zombies`, `helicopter` | The areas below. Later areas are added as fields; an area a mod does not use is ignored. `moodles`, `text`, `zombies` and `helicopter` are left out, with a line in the game's log, in a game that lacks what they read (`moodles` and `text` also in a game started by an install from before them). |

Functions are called with a dot (`PZToolsAPI.buildings.at(x, y, z)`); a handle's functions with a
colon (`handle:clear()`). A wrong argument is a Lua error that names the function and the argument.

How the table gets there:

- The bootstrap adds one call to the end of `LuaManager.init()`, which makes each new Lua
  environment, before the game loads any Lua
  ([`ApiHooks`](../../src/PzTools.GameBridge.Agent/java/pztools/bridge/ApiHooks.java)). The call sets
  the table into the new environment, so mods find it as they load.
- The API's code is its own jar (`extensions\pztools-extension-api.jar`), which the payload loads
  beside the game's start ([`ApiHost`](../../src/PzTools.GameBridge.Agent/java/pztools/bridge/runtime/ApiHost.java)).
  If the game's first Lua environment comes first, the call waits for the payload, at most 10
  seconds, once per game.
- The bootstrap keeps the loaded API with its jar's digest, so a payload update leaves it running.
  Only a changed API jar loads a new API (the payload looks about once a second).
- An API that replaces another, or that came after the game's Lua started, sets the table on the
  next frame. It updates the table in place, so the tables a mod holds stay valid, and the mods'
  handles are kept. A function a mod copied out of the table (`local define =
  PZToolsAPI.networks.define`) belongs to the API replaced: calling it is a Lua error that says
  the API was updated, and the mod reads it from `PZToolsAPI` again. An API that fails to set the
  table leaves the game as in vanilla, and the functions mods copied give the same error.
- A game started by an install from before the API has no API until it is started again.

A mod checks `PZToolsAPI` on `OnGameStart`. Without it (PZ Tools not installed, or this game not
started by the loader), the mod changes nothing and says why. It keeps its definitions in the save
(`ModData`) and defines its networks again each time a world loads, on `OnGameStart`: a world's
generators make up for the hours it was away as they first update, and the API sees that only for
networks defined by then. Until a mod defines its networks, the game behaves as in vanilla.

When the app updates the API's code in a running game, the new code takes over the definitions of the
old one, and what the old code knew of them: the producer in use and each producer as last seen (with
whether it is out of service), the supply, the load of consumers that are not loaded, and the supply's history for food. Mods do not
define anything again, and a producer running on a square that is not loaded goes on carrying its
network. The old code keeps the definitions in the API table's metatable, written once a frame when
they changed, and hands them over with the rest as the new code takes over. A change that cannot take
them over waits for the game's restart, as other bootstrap changes do.

Uninstalling the startup loader removes the API from the next game start. The app says so before it
uninstalls, naming the mods it has seen use the API.

Objects are named by position and sprite name (`x, y, z, sprite`). An object that moves is a
different object.

## Buildings (facts)

A building is what the game's map data (`IsoMetaGrid`) says it is: the rooms of one `BuildingDef`,
for loaded and unloaded squares alike. A square belongs to it when one of its rooms covers the square
(`IsoMetaGrid.getRoomAt`); walls and yards outside its rooms do not.
([`Buildings`](../../src/PzTools.GameBridge.Agent/java/pztools/api/Buildings.java))

| Call | Returns |
| --- | --- |
| `buildings.at(x, y, z)` | The building the square belongs to, or `nil`: `key`; `playerBuilt`; `minLevel` and `maxLevel` (a basement included); `minX`, `minY`, `maxX`, `maxY` (inclusive); and the square's `room` (the game's room name) and `roomId`. |
| `buildings.rooms(key)` | A list of its rooms: `id`, `name`, `level` and `rects` (a list of `x`, `y`, `w`, `h`). |
| `buildings.objects(key, filter)` | A list of its objects that use power, water or either, and whether every square of the building was loaded. |
| `buildings.near(key, tiles, filter)` | The same for squares that belong to no building, within `tiles` (0 to 32) of it on its own levels, a diagonal step counting as one. |

`filter` is `nil` (either), `"power"` or `"water"`. Each object is `x`, `y`, `z`, `sprite`, `type`
(the game's class, such as `IsoLightSwitch`), its `room` and `roomId` (not for `near`), and:

- `power`: present when the game could power the object from a generator
  (`IsoObject.couldBePoweredByGenerator()`), with the consumption the game gives for it now
  (`getGeneratorPowerConsumption()`);
- `water`: `true` when its sprite takes piped water (`waterPiped`).

A light switch belongs to the room it lights (`IsoLightSwitch.roomId`). One on a south or east wall
stands on the square beyond the wall, outside its room: `objects` reads one square around the
building for those, and `near` leaves out every switch that lights a room. So with anything else
that hangs on a wall (its sprite is `attachedN`, `attachedS`, `attachedE` or `attachedW`) and stands
on a square of no room: it belongs to the room across that wall, as a lamp on a building's outer
wall does. A network supplies such an object with that room, as power and water to its square
would. Objects exist only on loaded squares; the second result says whether some were missing.

A key is the position `"x,y,z"` of the corner of the building's lowest level that is furthest north,
then west: a square of that building, so no two buildings share it. A key that no longer names a
building (`rooms` gives `nil`, `objects` and `near` give `nil, false`) means the building was
removed or rebuilt. A player-built building changes key when the game rebuilds it after its walls
change, so a mod finds its building again from a square it remembers, and a network names its
buildings by such a square.

## Networks (mechanism)

A network carries one utility, power or water, from producers to consumers.

| Part | Meaning |
| --- | --- |
| Producers | Power: generators. Water: fluid containers (rain collectors, barrels, tanks). Each belongs to at most one network. |
| Consumers | Whole buildings (named by one of their squares), with objects excluded from them; and single objects anywhere. An object in a building that no network contains is not a consumer unless added on its own. |
| Children | Networks that have supply while this network has, from its producers (power: whose load its producer carries; water: whose fixtures draw from its containers). A power child has no producers of its own; a water child may have its own, and draws from them and its parents'. Networks form a tree of one mod's networks of one utility; a cycle is refused. |
| Policy | How producers share the load. Power: `"sequential"` (the first producer that can run carries everything; the next starts when it stops) or `"parallel"` (all running producers share it). Water: `"fullest"` (each draw comes from the container with the highest fill ratio) or `"nearest"` (from the network's own producers first, then its parent's, and so on up, the fullest within each; a container at least 95% full gives first wherever it is). |

A call that changes a network takes the mod's handle (from `PZToolsAPI.client`) first; changing
another mod's network is a Lua error. Network ids are 1 to 64 letters, digits, `_`, `.` or `-`, one
id per network across all mods. Squares are `x, y, z`; objects are a square and a sprite name.

| Call | Effect |
| --- | --- |
| `networks.define(handle, id, utility, policy)` | Creates the network, or empties the mod's own network of that id. Now `"power"` with `"sequential"`, and `"water"` with `"fullest"` or `"nearest"`. Defined again with another utility, it detaches its children. |
| `networks.remove(handle, id)` | Removes it, giving its producers back to vanilla; `true` when there was one. |
| `networks.setProducers(handle, id, list)` | Producers in order: squares (tables with `x`, `y`, `z`), and for power also sources the mod runs (tables with `source`, a name of 1 to 64 letters, digits, `_`, `.` or `-`). A square is a producer of one network at most. A power child takes none; a water child may. A new source is not available and switched off. A producer taken out of the list while it carries the load stops, and the next that can run takes over. |
| `networks.setSource(handle, id, name, available, switchOn, hour)` | Sets a source of the network as its mod runs it: whether it can carry the load (`available`); `switchOn` `true` switches it on (it takes over, as a generator a player switches on), `false` off (the network stops if it was in use), `nil` leaves it; a source that is not available is switched off, and if it was in use the next producer takes over from `hour` (when it ran out; now when `nil`). The API does not know what the source is: the mod keeps its charge and says when it is empty. |
| `networks.addBuilding(handle, id, x, y, z)` | A building as a consumer, named by one of its squares; `true` when the square is in a building now. |
| `networks.removeBuilding(handle, id, x, y, z)` | Removes that square, and any other that names the same building; `true` when one was removed. |
| `networks.addRoom(handle, id, x, y, z)` | A single room as a consumer, named by one of its squares, for a building the network does not take whole: only that room's squares have power and only its objects are consumers. `true` when the square is in a room now. |
| `networks.removeRoom(handle, id, x, y, z)` | Removes that square, and any other that names the same room; `true` when one was removed. |
| `networks.setExtraLoad(handle, id, load)` | Power only: adds a load (0 to 1000) to the network's consumers', as for a source that charges from it. |
| `networks.exclude(...)` / `networks.include(...)` / `networks.reset(...)`, each `(handle, id, x, y, z, sprite)` | Excludes an object of a member building, adds a single object, or undoes either. |
| `networks.setParent(handle, id, parentId)` | Makes the network a child of another of the mod's networks; `nil` detaches it. Removing a parent detaches its children. |
| `networks.setEnabled(handle, id, on)` | Switches the network on (`true`) or off (`false`). Switched off, it has no supply, nor have its children. A power network at the top of its parents runs no producer while it is off: the API switches its running generators off, on standby, and leaves its sources off; a generator a player switches on meanwhile goes back off at once and becomes the one to start first, and so does a source its mod switches on meanwhile. Switched on again (`"supply"` at that hour), the producer in use before starts if it can run, or else the next that can take over (see [power](#power)); with none, it has no supply. A generator's turn to start first is marked on it and outlasts a world loaded again; a source's is not, and after a load the first producer, in order, that can run starts, a source only if its mod has said by then that it is available. One whose square is not loaded: if it still runs there, it carries the network on; if it is off and none other can start, the network waits for its square to load and starts it then. A generator out of service (switched off by hand) never starts. A child switched off leaves its parent's producers running. A mod sets the switch as it defines the network, before the next frame. A network is defined switched on. |
| `networks.setLoadFactor(handle, id, factor)` | Power only: multiplies the load of the network, its children's included, on its way to its producer (a number from 0 to 100; 1, the default, for none). A child's factor counts inside its parent's. The API does not know why: a mod uses it for losses or savings of its own. |
| `networks.setPurify(handle, id, on)` | Water only: whether the water its fixtures give is purified, as vanilla purifies plumbed water (`true`, the default), or keeps the taint of the producer it comes from (`false`; see [fluids](#water)). Its own setting, also for a child. `false` is a Lua error in a game without both of the hooks it needs (`IsoObject.createSampleAndPurifyWater` and `isTaintedWater`, as the class is now): a game started by an install from before them gets them as it starts again; `PZToolsAPI.hooks()` says why one is missing. |
| `networks.state(id)` | `nil`, or `owner`, `utility`, `policy`, `supplied`, `enabled`; `parent` for a child; `producer` (the producer in use, its square or a table with its `source`; absent without one running); `load` (its children's that are switched on included, times its load factor; what it draws while it has supply, also while it is switched off), `ownLoad` (its own consumers' and its extra load, without the factor), `extraLoad` and `loadFactor`; `complete` (whether every consumer was loaded when the load was last worked out); `fuelPerHour` (the litres of fuel a generator burns an hour carrying the load now: its base consumption and the load, times the sandbox's fuel rate; also while a source carries it or nothing runs; for a child, that of the network at the top of its parents); `hoursLeft` (how long the fuel of the producer in use and of those on standby that can take over lasts at the load now, as last seen; absent without supply and while a source carries it); and `producers`, in order, each its square and, once seen loaded, `running`, `fuel` and `condition`, and `outOfService` (`true` while it is off and out of service: the API saw it switched off by hand and never switches it on; absent otherwise), or a source's `source`, `running` and `available`. A generator with `running` false and no `outOfService` is on standby: the API switches it on when the one in use stops, if it can run, as its fuel and condition tell (see [power](#power)). An API from before the field gives none, and has none out of service, so a mod reads the field without a version check; but that API also stops the network when the one in use is switched off by hand, and leaves generators running while the network is switched off. For water, instead of the power fields: `purify`; `amount` and `capacity` (what the producers it draws from hold, as last seen and with what draws and fills owe them: its own and, for a child, its parents') and `producers`, its own alone, each its square, `pending` (the litres draws and fills owe it, signed: below 0 for draws) and, once seen loaded, `amount` (with `pending` counted) and `capacity`. |
| `networks.consumers(id)` | The objects it supplies on loaded squares, as `buildings.objects` gives them, and whether every square was loaded. |
| `networks.draw(handle, id, amount)` | Water only: takes up to `amount` litres (0 to 1,000,000) from the producers the network draws from, in its policy's order (see [draw and fill](#draw-and-fill)). Returns the litres taken and a table of what they were, by the game's fluid name (`{ Water = 12.5, TaintedWater = 2.5 }`). |
| `networks.fill(handle, id, amount, fluid)` | Water only: adds up to `amount` litres of `fluid`, a name from the game's fluid registry (`"Water"`, `"TaintedWater"`), to the producers the network draws from, the emptiest first, as far as they have room. Returns the litres added. |

One event, `OnPZToolsNetworkChange(id, what, hour)`, raised through `LuaEventManager` after the
change, never per frame. `what` is `"supply"` (it started or stopped), `"producer"` (another producer
carries it) or `"load"` (power only); `hour` is the world age in hours when it happened, which is in the past when
a producer ran out while its square was not loaded. A mod reads the rest with `networks.state(id)`.

### Built so far

- Power networks under `"sequential"`: buildings and single objects as consumers, and exclusions.
- Supply under `"sequential"`: one producer runs at a time and carries the load. The one the player
  switched on last carries it, and the API switches the others off, on standby. A generator switched
  off by hand is out of service: the API never switches it on until a player switches it on again.
  When the one in use is switched off, runs out of fuel or breaks, the API switches on the first other
  producer, in order, that can take over (an available source, or a generator on standby that can
  run), at once or from the hour the first ran out (see Time below); with none, the network stops
  (see Standby below).
- Load: worked out when a definition changes; when the game says something that uses power was
  switched, placed or taken in or beside a member building, or at an object added on its own
  (`IsoGenerator.updateGenerator`); and every 5 seconds while some consumers are not loaded.
  Consumers on squares that are not loaded count as they were last seen loaded.
- Range: a producer powers no square around it. Its consumption is its base consumption, plus the
  network's load while it carries it, and the game burns fuel from that hour by hour while its square
  is loaded.
- Exclusion: an excluded object gets the game's own answer, as if no network powered its square, so a
  generator in range or the grid still powers it. An object that covers several squares is excluded
  when any of its parts is.
- Lights: a room's light gets power from a switch of that room that the network supplies, wherever
  the switch stands (one on a south or east wall stands outside the building), and not from an
  excluded switch. A switch's own light sources follow the switch.
- Food in a fridge or freezer keeps cold by the container's answer, not its square's: not in an
  excluded fridge, and in a fridge added on its own.
- When a network's supply starts or stops, its consumers are told (`IsoObject.checkHaveElectricity`),
  as vanilla tells the objects in a generator's range.
- The definitions belong to the world they were made in: when the game's cell goes (the player left
  the world: the game stores the cell, which a hook tells the API of), the API removes them, and the mods define them
  again in the next world.
- Events: `OnPZToolsNetworkChange` for supply, the producer in use and the load.
- Children: a child has supply while its parent has (its supply events carry the parent's hour), and
  the parent's producer burns both loads.
- Water networks under `"fullest"`: a fixture the game can pipe water to (`waterPiped`), in a member
  building or added on its own and not excluded, takes its water from the network while one of its
  producers holds some: from the fullest of them by share of its capacity, at each question. A child's
  fixtures draw from its own producers and its parents', the fullest of them all; a parent's never
  draw from its child's. Under `"nearest"` they draw from the network's own producers first and from
  each parent's only once the nearer ones hold nothing, the fullest within each; a container at least
  95% full gives first wherever in the chain it is, so that rain is used before it would spill. A mod
  whose parents' water is the only water some other fixtures reach (those of the parents' own
  networks) keeps it for them this way. The policy of the fixture's own network applies. A producer's square has
  no consumers. The producers are read once a second; a `"supply"` event says when the network got or
  lost water.
- Food: the hours food in a network's fridge or freezer ages over are split where the network's
  supply started and stopped (see Food below).
- Switch: `setEnabled` switches a network off and on, for power and water. A power network switched
  off stops its generators (on standby, burning nothing); switched on, the one in use before starts
  again, or the next on standby that can run.
- Load factor: `setLoadFactor` multiplies a power network's load on its way to the producer.
- Rooms: `addRoom` takes single rooms of a building instead of all of it.
- Sources: producers its mod runs (`setSource`), in the same order as generators under `"sequential"`;
  `setExtraLoad` adds a load to a network.
- Draw and fill: `draw` and `fill` move water out of and into a water network's producers, also those
  whose squares are not loaded, which take the change as they load ([draw and fill](#draw-and-fill)).
- Purification: `setPurify(false)` lets a water network's fixtures give their producer's taint
  instead of vanilla's purified water.
- Formulas: the body, load and speed points ([formulas](#formulas-mechanism)), declared through a mod's handle and read by
  hooks in the game's character, stats, inventory and moodle methods.
- Not yet: `"parallel"`.

### Power

- **Supply.** A network is supplied while its producer in use runs. Under `"sequential"` only that
  one is switched on; the API switches on the next on standby when it is switched off, runs out or
  breaks. A child is supplied
  when its parent is. A network switched off (`setEnabled`) is not, nor are its children; the
  API switches its generators off, on standby, and the one in use before starts first when it is
  switched on again (if it cannot run, the next that can take over). A generator switched on by hand
  while the network is off is in service again: the API switches it straight back off, and it is the
  one that starts first; a source its mod switches on meanwhile is, too. A child switched off adds nothing to its parent's load, and its parent's
  producer keeps running.
- **Load.** The sum of vanilla consumption (`IsoObject.getGeneratorPowerConsumption()` and the
  constants on `IsoGenerator`) over its consumers and its children's, each network's times its load
  factor, computed when a consumer is added, removed, placed or picked up, never per frame. Load of consumers in squares that are not
  loaded is the last value computed while they were.
- **Range.** A producer in a network powers no square around it. It adds itself to no chunk
  (`IsoChunk.addGeneratorPos`), and its consumption is the network's load.
- **Time.** The game burns a running generator's fuel hour by hour from its `lastHour`, also for the
  hours its square was not loaded, and switches it off in the hour its fuel runs out; then it sets
  `lastHour` to now. So the API records each running producer as it starts its hourly update
  (`IsoGenerator.update()`): the hour it has burned up to, its fuel, and what it burns an hour. When it
  stops for want of fuel, it ran out at that hour plus its fuel over what it burns an hour, rounded
  up. The API switches the next producer on and sets its `lastHour` back to that hour, and the game
  burns the hours since on its next update, as for any generator. A producer in use whose square is
  not loaded counts as stopped once that hour has passed, and the next takes over then if its own
  square is loaded. Condition wear is the game's own.
- **Food.** Vanilla ages food in a container over the whole time since it last aged, as refrigerated
  if the square has power now, and splits that time only at the grid's shut-off. The API splits it
  also at the times its network's supply stopped and started, so a fridge that lost power while the
  player was away spoils from that moment, and one that kept power does not. The API keeps those
  times in memory, from when it first works a network out: supply it then finds running counts as
  running before, and a producer that ran out meanwhile stops it at the hour its fuel ran out. The
  hours a network or a parent above it was switched off count as without supply. A fridge
  with the game's own power now (the grid, a generator in range), an excluded one and frozen food age
  as in vanilla. Freezing and thawing follow the power now, as in vanilla. The times are not saved: a
  world loaded again starts them anew; a newer payload takes them over.
- **Standby.** Under `"sequential"` a generator that is off is on standby, unless it is out of
  service. Out of service: switched off by hand while it could run (the API knows the switches it
  makes; any other is by hand), also one switched on and off between two of its frames, which it sees
  through the generator's update. The API never switches it on: not when the one in use is switched
  off, runs out or breaks, nor when a source stops, nor when its network is switched on. Switched on
  by hand, it carries the load as the one switched on last, and is in service again. Every other
  generator that is off is on standby, as under the API before; so is one that stopped for want of
  fuel or condition, which becomes a candidate again once it can run (nothing starts it as it is
  refuelled or repaired: it takes over when the one in use next stops). When the one in use stops,
  the first producer, in order, that can take over does: an available source, or a generator on
  standby that can run; switched off by hand, at once (`"producer"`); only with none does the network
  stop (`"supply"`). Standby is a generator's; a source is as its mod sets it: switched off by its
  mod while available, it stops the network, as before; available, it can take over.
- **First sight.** A generator the API sees for the first time (a new producer, a world loaded, a
  newer payload taking over from one before the marks) is out of service if it carries the
  out-of-service mark, or if it is off, can run, and carries the running mark: it was switched off
  where the API did not see it, the game running without it. Off and unable to run, it stopped by
  itself, and is on standby. Off without either mark (never seen running in a network by this API),
  it is on standby.
- **Settled state.** The generators' own saved fields (switched on, fuel, condition, `lastHour`) are
  the state, with three marks the API keeps in the `modData` of a network's generators, each written
  as it changes, never per frame. `PZToolsRunning` (`true`) while the API sees it running; it goes
  when the API sees it stop or switches it off. `PZToolsOutOfService` (`true`) on one out of service;
  it goes when it is seen running. `PZToolsResume` on the one to start first when its network,
  switched off, is switched on again: its `lastHour` when it was marked, read only while the network
  is off. The game changes `lastHour` only while the generator runs, so a resume mark whose hour is
  not the generator's is from before it ran again, and counts for nothing. The world saves the marks
  with the generator, as it saves its switch, so a world loaded again knows them as their squares
  load; picked up, a generator leaves them behind (`ISTakeGenerator` copies fuel and condition, not
  `modData`), and one placed there instead is new. A generator that leaves the producers loses its
  marks at the next frame if its square is loaded, and so does one switched on in no network: the
  marks are for network generators. In a running game the API keeps them also in memory, for
  generators on squares that are not loaded too, and a newer payload takes them over; one from before
  the marks hands over none, and the next frame reads them from the generators as at first sight.
  After a world loads, the producer the game runs is the one in use; the API records it as its first
  update starts, before the game makes up for the hours away.
- **Multiplayer** (untested). The server, or a single-player game, owns the switches and the marks,
  as it owns draw and fill. A client switches no producer and writes no mark: it reads the
  out-of-service mark the server keeps, and takes the producer that runs as the one in use.

### Water

- **Supply.** A network has water while one of the producers it draws from holds some, as last seen
  loaded and with what draws and fills owe it, and it is switched on. A child draws from its own producers, if it has any, and from each
  parent's up to the one at the top; it has water while one of those holds some and it and each
  parent above it are switched on. A parent switched off cuts its children, whatever they hold.
  Without water, its fixtures are the game's again.
- **Draws.** A consumer fixture draws from the network: under `"fullest"` the producer with the
  highest fill ratio gives each draw (under `"nearest"` see above; the policy of the fixture's own
  network applies, whatever its parents' are). Levels converge as water is used, and space opens first in the containers that
  are fullest, so rain is lost only when all are full. No water is moved between containers. A
  producer is the fluid container on a producer square; one whose square is not loaded gives no draw.
- **Fluids.** Vanilla decides amount and draw from the container the draw comes from, as it does for
  a fixture plumbed to a barrel, and it purifies plumbed water: what a fixture passes on
  (`IsoObject.transferFluidTo`) comes through a sample of its source
  (`createSampleAndPurifyWater`) in which TaintedWater is Water; the fluid and name the fixture shows
  (`getPrimaryFluid`, `getFluidUiName`) are that sample's; and `isTaintedWater` says no while the
  source holds anything. So a network's fixtures give clean water from rain-filled producers, as in
  vanilla. A network with `setPurify(false)` keeps its producer's taint: the sample is a copy of the
  source as it is, and `isTaintedWater` says yes while that source holds TaintedWater. A multiplayer
  client defines no networks, so its interface may still show such water as clean.
- **Time.** Water is drawn only when a fixture is used, which happens with its square loaded. Rain
  collectors fill themselves (see below), so a water network needs no catch-up of its own.

#### Draw and fill

A mod moves water into and out of a network's producers with `draw` and `fill`, for consumers and
producers of its own that are not game fixtures. They reach the producers the network draws from (its
own, then its parents'), and nothing while the network or a parent above it is switched off.

- **Order.** A draw takes from the fullest by share of its capacity until it is level with the next,
  then from both, and so on, as many small draws by fixtures would; a fill levels the room left the
  same way, so the emptiest takes first. Under `"nearest"` a draw first takes what is above 95% of
  each container's capacity (levelled the same way), then from the network's own producers, levelled,
  then from its parent's, and so on; a fill is as under `"fullest"`. The policy of the network drawn
  from applies. Each container gives every fluid it holds in proportion,
  which is what the draw's table reports.
- **Loaded.** A container on a loaded square changes at once, through the game's own
  `FluidContainer.removeFluid` and `addFluid` (a container that does not take that fluid takes none).
  As the game does after a fluid change, the object is synced (`IsoObject.sync()`, which sends it to
  multiplayer clients) and `OnWaterAmountChange` is raised.
- **Not loaded.** A producer whose square is not loaded is drawn and filled as last seen, with what it
  is owed already, its fluids included; the change is owed to its square. A producer never seen loaded
  since the networks were defined takes neither. `state` counts what is owed in `amount` and reports
  it as `pending`.
- **Owed.** What is owed belongs to the world, by square, not to a network: defining a network again
  or changing its producers loses none. The world keeps it in the game's global ModData under
  `PZToolsPendingFluids` (`next`, the next sequence number, and `deltas`, a list of `x`, `y`, `z`,
  `sequence`, `litres` and, for a fill, `fluid`), which the game saves with the world. A square takes
  what it is owed on the first frame it is loaded, in order: draws from its fullest container first,
  fills into its emptiest, between empty and full. Until then no fixture draws from it. A square whose
  containers are gone drops what it is owed, and the game's log says so.
- **Added up.** A draw owed right after a draw to the same square adds to it, and so does a fill of one
  fluid after a fill of the same, so a mod that draws every few minutes from a producer far away owes
  one change, not one per draw. The square takes the sum as it would take the two one after the other:
  its containers level their shares from the fullest down (or their room from the emptiest), and a
  second draw levels on from where the first stopped, each container giving every fluid in proportion.
  A change of another kind starts a new one, and none adds to a change read from the ModData as the
  world loaded, which the square may have taken already (see below). Each change goes into the ModData
  table as it is owed, without writing the others again.
- **Once only.** A chunk is saved as it unloads, the global ModData only when the world is saved, so a
  world that stopped between the two still owes a square changes it took. Each change has a sequence
  number, and the containers on a square record the last one they took in their own modData
  (`PZToolsFluidsApplied`), which is saved with them; a square takes no change at or below it, and once
  seen loaded, `state` and the supply count none of them as owed while it is not loaded. A number is past
  every one given, read or seen taken in the game, and a newer payload goes on from the last; it is past
  the clock as well, so that a change owed in a game started again after such a world is numbered past
  the ones taken. A square never seen loaded since the world loaded counts every change read as owed, as
  only its containers know which it took.
- **Multiplayer.** Only the server, or a single-player game, changes what producers hold: on a
  multiplayer client `draw` and `fill` are a Lua error.
- The API does not simulate rain for producers that are not loaded. Whether the game fills a rain
  collector for the time its square was not loaded is not verified.

## Formulas (mechanism)

A formula is a value a mod declares for a named hook point: how much of a penalty to take away, a multiplier, an
amount to add. The hooks in the game's methods read the combined values from plain fields, so a question the game asks
many times a frame costs one volatile read, calls no Lua and allocates nothing. Without a declaration the game answers
as in vanilla; a declared value may give more or less than vanilla (halve a penalty, double a drain). The API knows
no mod's concept: a point is a place in a game method, named in the game's terms.

| Call | Effect |
| --- | --- |
| `formulas.set(handle, point, value)` | Declares the mod's value for the point (a `value` of `nil` takes it back). A point the API does not have, or a value of the wrong shape or outside its range, is a Lua error that names the point. |
| `formulas.get(point)` | The value all mods' declarations make together, in the point's shape, or `nil` when no mod declared it. |
| `formulas.declared(handle, point)` | The mod's own value, or `nil`. |
| `formulas.efficiency(item)` | The factor the current `carry.*` declarations put on the item's own weight (1 for none, 0.5 for +100%): what a mod's tooltip shows. `item` is an `InventoryItem`; anything else is a Lua error. |
| `formulas.weight(item)` | The item's weight as the load counts it with nothing equipped (a bag with what is in it), under the current declarations. |
| `formulas.points()` | `{ [point] = status }` for every point, worded as `PZToolsAPI.hooks()` is: `"applied"` when every hook the point needs went in, `"not-loaded"` while its class has not loaded, why one did not go in, `"partial: ..."` when some did and one did not, or `"unavailable: ..."` when the game lacks what a point reads. A mod shows the player what is not applied. |
| `formulas.tune(name, value)` | Changes one of the numbers the formulas work with while the game runs (a tuning: one value for the game, not declared by a mod, not saved; a game starts with the defaults), and answers its value; with no value it goes back to its default. Read as a formula works, so the next frame has it. For tuning in the game rather than by a build: the defaults are then made the tuned values. |
| `formulas.tunings()` | `{ [name] = { value, default, min, max, about } }` for every tuning. Now night sight's: `nightSight.floorFull` (0.9), `.darkExtra` (0.1), `.lift` (0.7), `.ease` (0.3 s), `.darkFrom` (0.3), `.darkFull` (0.5), `.darkLight` (0.03), `.darkIn` (0.75), `.darkOut` (0.55), `.darkRadius` (6), `.standing` (3); see [night sight](#night-sight). |

`handle:clear()` takes back everything the mod declared, in every area. A mod declares its formulas when a world
loads (`OnGameStart`), as it defines its networks: they belong to the world they were made in, and are gone when the player
leaves it. A newer API takes them over, as it takes over the networks; a function a mod copied out of the table says
the API was updated (see [reaching the API](#reaching-the-api-from-lua)). Several mods may declare one point; each point
combines their values by its own rule, below.

Only the local player's character is changed: a player of this machine (`IsoPlayer.players`, the one or up to four of
split screen). A zombie, a corpse, an animal and a remote player get the game's answers. A hook that cannot answer, or
whose point has no declaration, gives the game's answer, and the API goes on.

### Points

Values are plain numbers, booleans, tables and lists. "Multiply" means the values of several mods multiply; "reductions"
combine as `1 - (1 - a)(1 - b)`, the part of a penalty that is left multiplying; "add" sums them (the whole-number points
round the sum); a "chance" is a number from 0 to 1, the part of the events that happen, and chances multiply; a boolean
joins as "any": true when any mod declares true; in a table, each name combines on its own, and a list joins the lists of
the mods without repeating a name.
A name the game registers (an item type such as `base:moveable`, an item tag such as `base:keyring`) that the game does
not have is a Lua error at `set`.

| Point | Value | Combined | Meaning |
| --- | --- | --- | --- |
| `body.discomfortMultiplier` | 0 to 100 | multiply | Times the clothing discomfort the game works out (`getClothingDiscomfortModifier`, which `BodyDamage.UpdateDiscomfort` reads). |
| `body.stiffnessMultiplier` | 0 to 100 | multiply | Times the muscle strain a body part gets (`addStiffness`). What the muscles recover (a negative amount) is not scaled. |
| `body.fatigueMultiplier` | 0 to 100 | multiply | Times the fatigue an awake character gains (`getFatiqueMultiplier`, read by `updateStats_Awake`). |
| `body.enduranceDrainMultiplier` | 0 to 100 | multiply | Times every drop of the endurance stat (`Stats.add` of a negative amount, which `Stats.remove` is). What recovers it is not scaled. |
| `body.poisonMultiplier` | 0 to 100 | multiply | Times every rise of the poison stat (`Stats.add` of a positive amount). What lowers it is not scaled. |
| `carry.categoryEfficiency` | table: display category to -0.9 to 100 | add per name | A carrying efficiency for every item whose `getDisplayCategory()` is the name: `1` carries it as if it weighed half, `-0.5` as if twice. |
| `carry.itemEfficiency` | table: item type to -0.9 to 100 | add per name | The same by the item's type (`isItemType`), e.g. `base:moveable`. An item's efficiencies (its category's and its types') add; its own weight is divided by 1 plus the sum. |
| `carry.containerTagMultiplier` | table: item tag to 0 to 100 | multiply per name | Times the weight of what is inside a bag with the tag (`hasTag`): `0` makes its contents weightless. The bag's own weight is not changed. |
| `capacity.maxWeightAdd` | -1000 to 1000, whole | add | Added to the most the character carries (`IsoGameCharacter.getMaxWeight`, which the load moodle, the path speed and the fall damage compare the load with). |
| `capacity.effectiveMultiplier` | 0 to 100 | multiply | Times what a container holds for the local player (`ItemContainer.getEffectiveCapacity`, after the game's own trait multiplier), for the containers that multiplier reaches: not a character's inventory, a corpse, the floor, or a bag (a bag's capacity is its own kit, below). |
| `capacity.characterLimitAdd` | -1000 to 1000, whole | add | Added to the limit of the local player's own inventory (`getEffectiveCapacity` of the character's container, 50 in vanilla), which `hasRoomFor` checks. |
| `capacity.modDataKey` | name or list of names | join | A container whose holder (the object it stands in, the item it is in, the vehicle part it belongs to) has one of these keys in its `modData`, as a number, is held to none of the game's limits (100 for a container, 50 for an item's, 1000 for a vehicle's, and a bag's 50 less its weight): its capacity is its raw capacity plus the numbers. Any other container keeps the game's limits. |
| `overload.compress` | 0 to 1, a reduction | reductions | The part of the excess over the most carried that does not count when the game asks how heavily the character is loaded: the load becomes `max + (load - max)(1 - r)`. It reaches the load moodle (`Moodle.Update`), the path speed (`IsoPlayer.getPathSpeed`) and the fall damage (`handleLandingImpact`), not what `hasRoomFor` checks. A load within the most is as it is. |
| `move.runPenaltyReduction` | 0 to 1, a reduction | reductions | The part of the run penalty that equipment's total modifier (`fullSpeedMod`, stored by `calculateBaseSpeed`) takes away when it is below 1. A bonus is not reduced. |
| `move.combatPenaltyReduction` | 0 to 1, a reduction | reductions | The same for the combat speed modifier read by `calculateCombatSpeed`. |
| `move.walkMultiplier` | 0 to 100 | multiply | Times the movement the player's animation gives (`IsoPlayer.getDeferredMovement`, the distance walked, run or sprinted a frame), while the player is in the state of moving (`PlayerMovementState`: walking, running, sprinting, crouched) or strafing (`PlayerStrafeState`: moving while aiming). Climbing, vaulting, falling and the other states are not scaled. The blended `calculateWalkSpeed` is not used: it is capped. |
| `move.treeSlowMultiplier` | 0 to 100 | multiply | Times how much walking through trees slows the player. `IsoTree.getSlowFactor` (the factor the player's walk and run speeds are multiplied by on a tree's square) becomes `1 - (1 - factor) x value`, so `0` takes the slowdown away and `2` doubles it; a factor of 1 or more (a ranger's or a lumberjack's bonus) is not changed. The animation of walking through trees (`IsoPlayer.calculateInTreesSpeed`, the speed scale of the `inTrees` animation) is divided by the value, by at most 2 (`Formulas.MAX_TREE_ANIMATION`) however small it is, since the slowdown the animation carries is not in the game's code to be worked out: this needs a check in the game. |
| `move.treeScratchChance` | chance | multiply | The chance that walking through trees goes on to hurt: `IsoGameCharacter.damageWhileInTrees` runs only that part of the time (it also tears the clothes). |
| `body.coldMultiplier` | 0 to 100 | multiply | Times how fast a cold is caught (`Thermoregulator.getCatchAColdDelta`, of the local player's thermoregulator). |
| `body.corpseCountMultiplier` | 0 to 100 | multiply | Times the number of corpses the game counts around the local player (`CorpseCount.getCorpseCount(character)`), rounded to a whole number. The sickness the corpses make is worked out from this count (`GetBaseCorpseSickness` asks it), so a smaller count lowers that sickness too. |
| `body.corpseSicknessMultiplier` | 0 to 100 | multiply | Times the sickness the corpses around make (`BodyDamage.GetBaseCorpseSickness`, which the noxious smell moodle and the illness read), after the count above. |
| `body.holeChance` | chance | multiply | The chance that clothes tear when the game tears them (`IsoGameCharacter.addHole(part, boolean)`): otherwise no hole is made, and the call answers false. |
| `infection.woundChance` | chance | multiply | The chance that a wound rolls for an infection when the game has it (`BodyPart.generateZombieInfection`, called for scratches and cuts); otherwise it does not roll. |
| `infection.biteShield` | boolean | any | While declared true, the next zombie bite on the local player takes the infection it sets out of the part (`isInfected` and `isFakeInfected`, as they were before the bite; the wound infection and the bite itself stay), uses the shield up and raises `OnPZToolsBiteSurvived(bodyPartIndex)` on a later frame. It is armed once each time it becomes declared: to arm it again a mod declares it `nil` or `false` and then `true`; while any mod keeps declaring it, one use is all there is. Only the bite a zombie makes (`BodyDamage.AddRandomDamageFromZombie`) counts, not a bitten part a save loads. |
| `fall.landingRemap` | 0 to 1000, floors | add | Floors of a fall forgiven: a landing (`IsoGameCharacter.DoLand(speed)`) is worked out as if from that many floors lower (the speed becomes `sqrt(speed^2 - 2 g x floors)`, `g` being `FallingConstants.IsoFallAcceleration`), or not as a fall at all when it was not as high as that. A fall at the speed that kills (`FallingConstants.lethalFallThreshold`) or above is left as the game has it, so the shift never turns a lethal fall into a survivable one. Damage is linear in the height of the fall, so half a floor off a one-floor fall halves the damage. |
| `fall.impactMultiplier` | 0 to 100 | multiply | Times the damage a landing does (`handleLandingImpact`, which works it out from `FallDamage.getImpactIsoSpeed()` squared): the speed it reads is multiplied by the square root of the value. What kind of fall it is (light, hard, lethal) comes from the landing and does not change. |
| `loot.spawnMultiplier` | 0 to 100 | multiply | Times the chance an item is put into a container or on a corpse (`ItemPickerJava.getActualSpawnChance`), for containers filled from now on; one already filled stays. Not tied to a character. |
| `loot.ammoMultiplier` | 0 to 100 | multiply | Times the ammunition modifier of the loot (`ItemPickerJava.getLootModifierFromType("Ammo")`), which the chance above is worked out with. |
| `vision.darknessRestore` | 0 to 1, a reduction | reductions | The part of the dark the local player sees in that is taken away: `LightingJNI.getLumaInverted(character)` (0 light to 1 dark, which the vision cone and the shadows read) becomes `dark x (1 - value)`. The brightness of the screen is the native lighting's and does not change. |
| `vision.coneAdd` | -1000 to 1000, degrees | add | Degrees added to the width of the vision cone (`LightingJNI.calculateVisionCone`), where the game's traits add theirs: after its first limits (18 to 180) and before the worn items' multiplier and the last limits (18 to 360). Full-angle degrees; the cone is smoothed over time by the game as before. |
| `vision.nightSight` | 0 to 1 | the largest | Night sight for the local player: every square on the screen is drawn with at least some light (0.9 x the value of the full light, a sealed room too), and in the dark the screen's dark tones are lifted (the darker the more); what the eye saw without it keeps its colour, and what it adds is a cold grey, as the eye's rods see (what a lamp or a fire lights keeps its colour and is not lifted). On the screen alone: the squares' own light, which the zombies, the vision cone and reading ask, is the game's. The lift follows how dark it is for the player (`LightingJNI.getLumaInverted`: none in daylight or under a lamp, partly at a lamp's edge, whole in a night or a basement with no light), easing in and out over 0.3 seconds. A step in the screen shader (`screen.frag`, see [night sight](#night-sight)); the night vision goggles' path is left alone. |
| `machine.baseConsumption` | table of sprite name to 0 to 1000 | add | Power use for objects of those sprites, in the game's units (a vanilla appliance is 0.03 to 0.13 and a generator's own base is 0.02): see [machines](#machines). A mod's machines are consumers of a generator in range, and of a network, with no other code. |
| `machine.loadKey` | a name, or a list of names | join | The keys of an object's mod data (`object:getModData()`) that scale its declared consumption: each holding a number multiplies it, so that a machine at rest, at work or broken draws as its mod sets it. |
| `vision.hiddenZombieFix` | boolean | any | While any mod declares it true, the zombies the player sees and the game does not draw (the shadow vision's bug: a zombie in the cone with nothing between it and the player, on a square the game finds unseen) are drawn, as long as the game's own light test would let it be seen. Worked each frame from the game's list, not by a hook: see [the hidden zombies](#the-hidden-zombies). |

The load counts an item of the character's inventory as the game does (unequipped, equipped, or on the hotbar, with a worn
bag's weight reduction on what is inside it), and a formula only changes the weight the game reads: the efficiencies above,
item by item, and a bag by what is inside it. The same weight is what `hasRoomFor` adds when the local player's inventory
is asked whether an item fits, whether directly or through a worn bag; a bag's own room still takes the item's real
weight. Another character, a crate, a vehicle and the floor count weight as vanilla.

The survival points change the local player's answers only (the loot points are not tied to a character); another character,
a zombie and a player of another machine get the game's. Every one is read from a field when asked and calls no Lua.

The event `OnPZToolsBiteSurvived(bodyPartIndex)` is raised through `LuaEventManager` on the frame after a bite the shield
took the infection out of (the index counts as `BodyPartType.ToIndex`), as `OnPZToolsNetworkChange` is raised; the API adds
it to the game with the first Lua environment.

### Machines

A generator works out its load from the objects on the squares around it that the game lists for it. The game lists an
object when it enters the world and `IsoObject.couldBePoweredByGenerator()` is true, and asks each listed object
`IsoObject.getGeneratorPowerConsumption()` when the generator is placed, switched or told that something that uses power
changed (`IsoGenerator.updateGenerator(square)`). `machine.baseConsumption` makes an object of a declared sprite one that
could be powered (`true` when the game says so or the sprite is declared above 0) and gives its consumption as the declared
number times the object's own load: each key of `machine.loadKey` that the object's mod data holds a number under multiplies
it (a number below 0 counts as 0, above 100 as 100; a string or a NaN is left out; no key, or no mod data, is 1). A declared
sprite takes the game's own answer for it away, a declaration of 0 included; anything not declared gets the game's. Several
mods that declare one sprite add; their load keys join.

The sprite is the name objects are known by in `buildings.objects` (the object's sprite name, or its sprite's). Objects of
a class that has its own answer to the two questions (stoves, televisions and radios, washers and dryers, light switches,
car battery chargers) keep it; the generic `IsoObject`, which a mod's tiles are, and the classes that do not answer for
themselves are the ones declared. Nothing else hooks these two methods: the buildings area (`power` in `buildings.objects`)
and the networks (the load of a consumer) read them, so a declared machine counts there with no other code.

Objects that were in the world before the declaration are not on the game's lists. In the next frame that has a world and a
local player, the API goes through the loaded chunks around each local player (half the loaded area and a chunk more,
`IsoChunkMap.chunkGridWidth`), puts the objects of the newly declared sprites on the chunk's list
(`IsoChunk.addObjectPoweredByGenerator`, which does nothing for one that is on it) and tells the generators of their squares
(`IsoGenerator.updateGenerator`, once for each square). Objects that enter the world later list themselves. A declaration
that is taken back leaves the lists as they are: the game asks each listed object again, and no longer finds it a
consumer. A mod that changes the load of an object calls `IsoGenerator.updateGenerator(square)` after, as the game's own
Lua does when it moves an object; the API does not poll the machines.

### The hidden zombies

`vision.hiddenZombieFix` is the one point worked each frame instead of by a hook, because it is about every zombie at
once. The game decides which zombies are drawn in `IsoGameCharacter.updateSeenVisibility`, once for each local player
and each update: a zombie it does not find seen has the alpha it fades to set to 0 (`isVisibleToPlayer[player]` false).
Some squares inside the vision cone and the view distance are not found seen though nothing stands between them and the
player. While a mod declares the fix, the API goes through the cell's zombie list (`IsoCell.getZombieList()`) at the start
of each frame, on the game thread, and for each local player looks only at the zombies that

- the game does not draw (`isVisibleToPlayer[player]` false; one array read decides it for most),
- stand within `GameTime.getViewDist()` of the player, the game's own bound for seeing a zombie (it stands for the screen),
- stand on the player's floor or the floor just above or below it (a zombie two floors away is not looked at),
- stand inside the vision cone: the angle the lighting hands the shadows (`LightingJNI`'s smoothed `visionConeLerp`, read,
  not asked of `calculateVisionCone`, which moves it each time it is called), measured from `getLookVector`. Outside it the
  shadows hide the zombie, so the fix leaves it.

For such a zombie it draws a line from the player, and when nothing blocks the line it sets `setTargetAlpha(player, 1)` on
that frame and each frame after it, once the rest of the game's test of a zombie it finds in sight is passed (below; the game
sets it back to 0 when it updates; the alpha it fades to is all that is
changed. The frame job runs at the start of the game's `logic()`, and the game's update does `updateAlpha` before
`updateSeenVisibility`, so one setting per frame is enough).
On the player's floor the line runs from the exact positions across the squares and stops at an edge the game blocks vision
at (`IsoGridSquare.testVisionAdjacent`, as `LosUtil.lineClear` asks it); to the floor above or below it is
`LosUtil.lineClear` itself, which has the game's floors, stairs and openings. Only a `Blocked` result stops a line, as in the
game; a square the game has not loaded does not block.

The line replaces one part of the game's decision and nothing else. `IsoGameCharacter.TestIfSeen(int, IsoPlayer)` (the same
in the jar and in PZ Optimize's loose class, read from both) finds a zombie in sight by `IsoGridSquare.isCanSee` (with the
allowances `canSeeHeadSquare`, and `isCouldSee` with the detection range, for one that is not), and then decides by the light:
`DistToProper` against the view distance, the zombie's square's light `(r + g + b) / 3` (`ILighting.lightInfo()`, the native
lighting's, which the darkness point does not change) raised to the player's own square's when the zombie is within
`getDetectionRange()`, a light above 0.6 taken as 1, the fade `1 - distance / view` (taken as 1 when the light is full and
the fade is above 0.3), the dot of `getDotWithForwardDirection` with a floor of 0.5, the distance of 1 or less that doubles the
light and ends the fade, and at last `light x fade x 100 > 0.025`. A clear line inside the cone stands for `isCanSee`; for a
zombie that has it, the API asks the game's own methods (`DistToProper`, `getDetectionRange`, `getDotWithForwardDirection`,
`getCurrentSquare`, `lightInfo`) and repeats the arithmetic after them in the game's order, so that a zombie in the dark that
the game keeps unseen stays unseen, whichever square the game's grid missed. Nothing else of the test is a thing to answer
differently, so the allowances for a zombie not in sight are not reached (a zombie outside the cone is the game's own, as
before). A square whose light is missing, or a zombie with no square, is not shown. It is worked when the line is, at most
0.1 seconds old, so a light that changes shows or hides a zombie as soon as a line would.

A zombie that is shown is also offered to
`IsoPlayer.TestZombieSpotPlayer` every 0.1 to 0.5 seconds, so that it can notice the player as the zombies the game draws do.

What a line found is not kept for a square, a place or a door. A zombie's line is drawn when the zombie first becomes a
candidate, in the same frame, and again 0.06 to 0.1 seconds after the last (the spread differs from zombie to zombie, so
that the lines are spread over the frames): what is shown is never older than 0.1 seconds, and nothing has to be undone when
a door or an object changes. A zombie that is not a candidate for a few frames is forgotten.

It does not change the game's own working: the count of visible zombies, the music's and the panic moodle's reading,
`isVisibleToPlayer` and the lighting of the square (a zombie in a dark square is drawn dark) stay as the game has them. A
zombie the game's light test finds unseen (a square near black, farther than the detection range from a dark player) stays
unseen. Nothing is done while the player is asleep, dead, in a
vehicle (the cone then is the vehicle's) or sees everyone (a cheat that has it done). While no mod declares the fix nothing
runs, and the game is not touched.

A fault stops this part alone, once, with a line in the game's log: the point then reads `unavailable: stopped: ...`, the other
points go on and the game draws as it did. A game that lacks a member the fix reads makes the point read `unavailable: ...`
from the start.

### Hook sites

The hooks are found by the signature of the method and the shape of its call sites, never by position or hash: every
return of a method (or the one place a value is read) is hooked, and a method that is not shaped as expected loses its own
hook only. `PZToolsAPI.hooks()` names each by game class and method.

| Hook | Where | What it does |
| --- | --- | --- |
| `IsoGameCharacter.getClothingDiscomfortModifier` | each return | Times `body.discomfortMultiplier`, for the local player. |
| `IsoGameCharacter.addStiffness` | the start | Times `body.stiffnessMultiplier` on the amount, which is the method's own argument, when it is above 0. |
| `IsoGameCharacter.getFatiqueMultiplier` | each return | Times `body.fatigueMultiplier`. |
| `Stats.add` | the start | Times `body.enduranceDrainMultiplier` or `body.poisonMultiplier` on the amount (the argument) for the endurance or poison stat of a local player's `Stats`. `remove` calls `add`, so it is covered. |
| `IsoGameCharacter.getInventoryWeight` | the start | For a local player's character with a carry point declared, the method returns the kept weight (below) at once; for anything else, or when the API cannot answer, the game's own method runs. Found by its signature. |
| `ItemContainer.hasRoomFor(IsoGameCharacter, InventoryItem)` | each read of the item's weight | An item's weight read for a comparison with the carrier's inventory (the worn-bag branch, followed by an addition) or for the room question of this container passes through the carry points when the character whose body the weight would be on is a local player. A read followed by anything else makes the hook not go in. |
| `IsoGameCharacter.getMaxWeight` | each return | Adds `capacity.maxWeightAdd`. |
| `ItemContainer.getEffectiveCapacity` | each return | Times `capacity.effectiveMultiplier`, or adds `capacity.characterLimitAdd` to a character's inventory. |
| `ItemContainer.getCapacity` | each return | The raw capacity plus the keys' numbers for a container that declares one. |
| `InventoryContainer.getCapacity`, `getEffectiveCapacity` | each return | The container's own answer, without the bag clamp, for a bag that declares a key in its `modData`. |
| `ItemContainer.items` (every store of the field) | the store | The list stored is a `Tracked` list (an `ArrayList` that tells the API of each add, remove, set, clear, sort and bulk change after it is made), and its owner is the container. The container's own methods change the list through it, so none of them needs a hook of its own; neither do mods that call `getItems()` and change the list directly. |
| `ItemContainer.emptyIt`, `ItemContainer.setItems` | the start | The container's list is replaced or emptied without going through the list's methods: the kept account of the old list is dropped. |
| `WornItems.items` (every store of the field) | the store | The same for the list of what a character wears. |
| `InventoryItem`, `Food`, `HandWeapon`, `Moveable`, `InventoryContainer`, `ItemStatsPacket` (`writes:weight`) | after each store of a field the item's weight reads | The API is told that the item's weight may have changed (the fields: weight, ammunition, custom weight, extra items, type and name of a moveable, a food's hunger values and burnt flag, a weapon's clip, chambered round and magazine, a bag's container and reduction). The fields are found by name in the class bytes; one that does not exist is left out. |
| `InventoryItem.addExtraItem`, `HandWeapon.clearAllWeaponParts`, `clearWeaponPart`, `setWeaponPart`, `attachWeaponPart` | each return | The weight of the item, or of the part it carries, changed through a collection or an object the item holds rather than a field of its own. |
| `FluidContainer` (`writes:amount`) | after each store of the fluid cache fields | The amount of a fluid changed: the item that holds it (the component's `getGameEntity()`) is recomputed. |
| `Moodle.Update`, `IsoPlayer.getPathSpeed`, `IsoGameCharacter.handleLandingImpact` (labelled `:overload`) | each `ItemContainer.getCapacityWeight()` call (one, one and three) | The load passes through `overload.compress` for a local player's inventory. |
| `IsoGameCharacter.calculateBaseSpeed` | the store of `fullSpeedMod` | The value stored passes through `move.runPenaltyReduction`. |
| `IsoGameCharacter.calculateCombatSpeed` | the read of `combatSpeedModifier` | The value read passes through `move.combatPenaltyReduction`. |
| `IsoPlayer.getDeferredMovement(Vector2, boolean)` | each return | The vector returned (the method changes the argument and returns it) is scaled in place by `move.walkMultiplier` when the player is in the state of moving. The call is not made when the factor is 1. |
| `IsoTree.getSlowFactor` | each return | Passed through `move.treeSlowMultiplier`, for a local player. |
| `IsoObject.couldBePoweredByGenerator` | each return | True for an object of a sprite declared in `machine.baseConsumption` above 0, besides the game's answer. |
| `IsoObject.getGeneratorPowerConsumption` | each return | An object of a declared sprite gives its declared consumption times the load its mod data holds under `machine.loadKey`, in place of the game's. |
| `IsoPlayer.calculateInTreesSpeed` | each return | The speed scale of the animation of walking through trees, passed through `move.treeSlowMultiplier`. |
| `IsoGameCharacter.damageWhileInTrees` | the start | Returns at once, with the chance `move.treeScratchChance` leaves out. |
| `IsoGameCharacter.addHole(BloodBodyPartType, boolean)` | the start | Returns false at once, with the chance `body.holeChance` leaves out. The one-argument `addHole` and `addHoleFromZombieAttacks` call it. |
| `BodyPart.generateZombieInfection(int)` | the start | Returns at once, with the chance `infection.woundChance` leaves out (read from the part's `parentChar`). |
| `BodyDamage.AddRandomDamageFromZombie` | just before and just after the call of `SetBitten(index, true)` | The bite shield's two moments (see `infection.biteShield`). There is one such call and the index is a local variable, or the hook does not go in. `BodyPart.SetBitten`, which a save loading a part calls too, is not hooked. |
| `Thermoregulator.getCatchAColdDelta` | each return | Times `body.coldMultiplier` (the thermoregulator's `player` field). |
| `CorpseCount.getCorpseCount(IsoGameCharacter)` | each return | Times `body.corpseCountMultiplier`, rounded. |
| `BodyDamage.GetBaseCorpseSickness` | each return | Times `body.corpseSicknessMultiplier` (the body's `parentChar`). |
| `IsoGameCharacter.DoLand(float)` | the start | Replaces the speed, the method's own argument, by what `fall.landingRemap` makes of it. |
| `IsoGameCharacter.handleLandingImpact` (labelled `:impact`) | the call of `FallDamage.getImpactIsoSpeed()` | The speed read passes through `fall.impactMultiplier`. The same method as the load's `:overload` hooks; two hooks, one class owner. |
| `ItemPickerJava.getActualSpawnChance` | each return | Times `loot.spawnMultiplier`. |
| `ItemPickerJava.getLootModifierFromType` | the read of `ammoLootModifier` | Times `loot.ammoMultiplier`; the only read of that field in the method. |
| `LightingJNI.getLumaInverted` | each return | Passed through `vision.darknessRestore` (the method is private; it is found by its signature). |
| `LightingJNI.calculateVisionCone` | before the call of `getWornItemsVisionMultiplier()` | The degrees on the stack have `vision.coneAdd` added before the worn items' multiplier. |
| `LightingJNI$JNILighting.update:stale`, `.updateFBORenderChunk:stale` | after each call of `LightingJNI.getSquareDirty(player, x, y, z)` | Also true when night sight raised the square to another least light than it has now (or has not read it since squares are raised), so that it is read again; the call's arguments are kept in new locals. |
| `LightingJNI$JNILighting.update`, `.updateFBORenderChunk` | after each call of `LightingJNI.getSquareLighting(player, x, y, z, int[])` | The corner lights it handed (from index 5, the 8 colours the floors, walls and models of the square are drawn with) are raised to night sight's least light for a local player, before the game reads them; the call's arguments are kept in new locals. Both reads, the chunk renderer's and the other, are hooked, so the game's own check for a changed square sees the raised corners. |
| `FBORenderCell.sanitizeLightInfo` | each return | The light a square's objects are drawn with: a copy raised to the least light (the square's own, which the game also asks for its zombies and its vision, is never changed). |
| `ShaderUnit.loadShaderFile` | each return | The source of `screen.frag` gets night sight's step (once; another file, or one without `textureBicubic` or the goggles' uniform, is left as it is). |
| `WeatherShader.onCompileSuccess` | each return | Hands the compiled program over; the step's uniforms are found in it when it next draws (-1 when the step is not there, which GL ignores). |
| `WeatherShader.startMainThread` | the start | Night sight moves on, once a frame for each player's screen: its least light, where its pixels are on the floor, and now and then the squares' values. |
| `WeatherShader.startRenderThread` | each return | Sets night sight's uniforms, the program being bound: whether it is on, the strength, the colour kept beyond the values, the values' texture (put in on its own unit) and where a pixel is on it. |
| `Helicopter.writes:flight` | after every store of `Helicopter.state` or `Helicopter.active` (outside the constructors) | Counts the store; see [What the frame job learns from the hooks](#what-the-frame-job-learns-from-the-hooks). |
| `IsoWorld.writes:currentCell` | after every store of `IsoWorld.currentCell` (`init`, `KillCell`; outside the constructors) | Counts the store; the same. |
| `ParameterZombieState.setState` | before the store of the new state, which comes after the game's early return for the same state | The new state (from the stack), the zombie and the old state (the parameter's `zombie` and `state`, which the hook reads; a class without them, or with another number of stores of `state` in the method than one, loses the hook) go to the [zombie sounds](#zombie-sounds) while a mod listens. |
| `ZombieVocalsManager$Slot.playSound` | before the one call of `BaseCharacterSoundEmitter.playVocals` | The zombie's voice starts: the zombie (the method's argument; a method that stores over it loses the hook) goes to the zombie sounds. |
| `IsoZombie.handleLandingImpact` | the start | A zombie lands from a fall (the zombie's own method, which `DoLand` calls for a landing it counts as a fall): to the zombie sounds. |

#### Night sight

Night sight has two parts, both on the screen alone: a least light the squares are drawn with, and a step in the screen
pass that greys what that light and the pass add.

- **The least light.** The game's lighting is native; it hands each square's light into an `int[]`
  (`LightingJNI.getSquareLighting`: the visibility, the light, two darknesses, the level, then 8 corner colours packed
  `0xAABBGGRR`), and the game draws the square's floor, walls and models with the corners and bakes them into its chunk
  textures. Right after each such call the bridge raises each corner's colours to the least light (0.9 x the value, of 255)
  for a local player. Its objects are drawn with `FBORenderCell.sanitizeLightInfo`'s light, which gets a raised copy. The
  square's own light (`lightInfo`), which the zombies (`spotted`, `TestIfSeen`), reading and the darkness the vision cone
  reads ask, is the game's: the native lighting gives a room light only through its openings (measured: a sealed basement
  room reads 0 at night), and with night sight it is still 0 for everything but the screen. The game reads a square's
  lighting again only when the native lighting says it changed (`getSquareDirty`, which does not know of the least light:
  making the native lighting work every square again changes nothing it hands), and bakes it again when the corners it
  reads change. So each square keeps the least light it was raised to (in a table for each player and floor, by x and y
  modulo 256), and `getSquareDirty`'s answer is followed by whether it was raised to another, or not read since squares
  are raised: a new least light (a rank changed, or night sight declared or cleared) has each square read again as the game
  next asks for it. The least light is one value for a value of the point and a place, so this is rare. In a dark place it is 0.1
  more (of the full light): with the values, the squares within 6 of the player that the game lights are counted, and at
  75% or more of them with less than 0.03 of the game's own light (a basement, a room with no light) the player is in
  one, at 55% or less no longer. PZ Optimization's per-pixel lighting reads the same corners.
- **The screen pass.** The game draws the world into a buffer and then through one screen pass (`WeatherShader`,
  `media/shaders/screen.frag`), which reads the world through `textureBicubic` on every path (the stock one, and the ones
  PZ Optimization's colour grading, god rays and HDR put in), and single texels of it with `texture2D(DIFFUSE, ...)`. The
  bridge puts its uniforms and functions in front of `textureBicubic`, has it return its colour through `pztNightSight`,
  and has the single texels read through it too. With night sight off (`PZT_SightOn` 0) or the goggles on, the colour is
  given back as it is; otherwise its luminance is lifted by a gamma (1 - 0.7 x the strength), what the eye saw without
  night sight keeps its colour and the rest is a cold grey:
  - A square keeps the share of its colour the game's own light gives it: the mean of its corner lights as the game handed
    them (kept as they are raised, with the least light) against the least light, all of it when the
    game's is the brighter (measured: a basement whose stairs let the night in reads 0 in its `lightInfo` but is drawn
    with its corners' light; a square not seen yet falls back on its `lightInfo`). What a light source lights is not lifted: a square's light sources' share is the
    light the lights the game finds reach it give it (`IsoGridSquare.lighting`, each falling off from its colour at its
    square to nothing at its radius, measured; a room's light fills it), against its light. The two are worked out for the
    64 squares on a side around the player on the player's floor, every 0.1 seconds on the game's thread, and put into a
    small RG texture on its own unit (16: PZ Optimization's passes use 3, 4, 6, 7, 12 to 14, 17 and 20) by the render
    thread. The shader finds the floor under each pixel from where the game draws three points of it (`isoToScreenX` and
    `Y`, every frame, in the window's pixels, which the pass draws to with PZ Optimization's upscaling too) and reads the
    square's values, smoothly between squares. Beyond them, the mean colour kept on their edge (`PZT_SightKeep`). A wall
    or a thing standing on a square is drawn above it and read as the squares behind; a character standing on a square
    (a player of this machine, a zombie) has the 3 squares behind it, where it is drawn, and their sides keep at least
    its square's values, so that it keeps the colour its square does (a player in a torch's light is drawn in colour, a
    zombie in the dark in grey).
  - The strength follows how dark it is for the player (`getLumaInverted`, which reads the square's own light: the least
    light does not make it lighter, so night sight never turns itself down and back up).

The strength is one number for the machine: split-screen players share the first one's, and get the least light but no
values (the pass does not say whose screen it draws): the colour is kept there.

#### The weight kept

`getInventoryWeight` used to walk the inventory, every bag and every item in it, on each question, and the question is
asked many times a frame (the inventory pane, the moodle, `hasRoomFor`, the path speed). With a carry point declared the
API keeps the answer instead, and a question on nothing that changed is a field read: no walk, no allocation, no clock.
Nothing in the game keeps a sum of the inventory's weight (it computes it on each question), so there is none to reuse.

- Each list of items (a container's, and what a character wears) has a kept account: a sum, in a `double`, of what each
  item adds, and what each added is kept per item, so that taking an item out subtracts exactly what was added. A bag adds
  its own weight under the carry points plus the sum of its container times the bag's tag factor; the account of a bag's
  container knows its parent, so a change inside a nested bag adds its difference up the chain, bag by bag (the depth of the
  nesting, not the size of the inventory). The sum is kept exact: after each addition the API checks that the rounding error
  of the sum is zero and drops the account (to be built again once) when it is not, so the returned value is the fresh walk's,
  to the bit.
- A character's total is the sum of the inventory's list less what the character holds, has on the hotbar or wears counted
  as unequipped, plus those at their equipped weights. What is equipped is compared by identity at each question (the two
  hands, the worn list and its version): a change moves a few items between the two terms, it is not a walk.
- A change reaches the account as it is made (the hooks above) and is settled at the next question, in the order it was
  made; more than 4096 unsettled changes drop the accounts instead (each is built again once). A declaration change
  (`formulas.set` of a carry point, or `clear`) invalidates every account at once with one counter; each is built again by
  the question that needs it. Nothing declared: the game's own method runs and nothing is kept.

What the API cannot see, and what it does about it:

| State | Why | What happens |
| --- | --- | --- |
| A script's weight of an item (`Item.actualWeight`), `ScriptManager` data | Read through a method the item calls, not a field of the item | Not followed: it does not change while a game runs |
| `ZomboidGlobals.equippedOrWornEncumbranceMultiplier` | A static the game's options set | Compared at each question; a change drops the accounts |
| The weight modifier of a weapon part already attached | Not a field the weapon's hooks reach | The part is reweighed when it is attached, detached or the parts cleared (the hooks above); a change of an attached part's modifier alone is not seen. The game does not do it |
| An item whose `container` field names a container whose list does not hold it, or the reverse | A mod or an old save that breaks the game's invariant | Such lists are kept by the list itself, not by the container the item names |
| A write that avoids the methods and the fields (reflection, `Unsafe`) | The hooks are on the game's code | Not seen |
| A list that is not `Tracked` (a container made before the API was attached) | The store was made before the hook | Upgraded to a tracked list the first time it is asked about, and built once; the hooks cover the later changes |
| Too many changes between two questions, or a lock held by another thread when a hook ran | A bound on the queue; hooks never block the game | The accounts are dropped and built again by the next question: once per list |
| Any hook above that is missing (`PZToolsAPI.hooks()`) | A class another mod rewrote | `ApiHooks.weightTracked()` is false and the game's own `getInventoryWeight` answers: the API does not keep an account it cannot follow |

A hook that edits a call site counts the sites it finds and goes in only when it finds as many as the game's method has
(3 weight reads, 3 load reads in the fall damage, and so on); a method another mod rewrote loses its own hook only, and
`formulas.points()` then says `"partial: ..."` for each point that needs it. The load tree needs the game's inventory
classes (`InventoryItem`, `ItemContainer`, `InventoryContainer`, `ItemType`, `ItemTag`, `VehiclePart`); in a game where
they cannot be read, its points say `"unavailable: ..."` and the body points go on.

### Verified

Against the installed game (7 October 2026, Build 42) and with PZ Optimize's loose classes, offline: every hook above was
put into the real bytes of `IsoGameCharacter`, `IsoPlayer`, `Stats` (the jar's and PZ Optimize's), and `Moodle`,
`ItemContainer` and `InventoryContainer` (the jar's; PZ Optimize does not override them), and the resulting classes
verified by the JVM. Behavior is tested against synthetic game classes of the same shape (the `api` suite): each point
changes the local player's answer and no other character's, several mods combine by the rules above, a declaration
goes with the world, survives a newer API and never makes the game fail. The kept weight is checked against a fresh
walk: after each of 10000 random operations (items made, taken out, moved between any two containers, bags nested,
weights, ammunition and fluid amounts changed, what is worn, held or on the hotbar changed, filters and clears) the answer
equals the walk's to the bit. Moving 3000 items one by one between two containers with a capacity question after each cost
6.4 us a move, looked at no item (the lists were already worked out) and worked out 3 item weights a move; a question after a
declaration change on 3003 items cost 0.73 ms once (every list built again). A question on nothing that changed iterates
and allocates nothing (counted). The hooks that follow the weight were put into the real bytes of `ItemContainer`,
`WornItems`, `InventoryItem`, `Food`, `HandWeapon`, `Moveable`, `InventoryContainer`, `ItemStatsPacket`, `FluidContainer`
and `IsoGameCharacter` (the jar's and PZ Optimize's loose class) and verified by the JVM. Not tried in the game yet: the
weight kept against a real inventory, with real fluids and food, and the inventory pane refreshing; the load tree in
play (weights in the inventory pane, a full inventory, the moodle, the path speed and a fall), and the speed points on a
worn bag. The survival points (loot, vision, falls, trees, walking, the body's illnesses, clothes and wounds, the bite
shield) were put into the real bytes of `ItemPickerJava`, `LightingJNI` (the jar's and PZ Optimize's loose class),
`IsoTree`, `Thermoregulator`, `CorpseCount`, `BodyDamage`, `BodyPart`, `IsoGameCharacter` and `IsoPlayer` (the jar's and
the loose ones) and verified by the JVM; in the synthetic game each point is tested to change the local player's answer
and no other character's, to combine as its rule says, to give the game's answer when its hook fails, and to be taken back
by `clear`; the chances are counted over thousands of calls, a fall is tried at every side of the lethal height, the bite
shield through the zombie's bite, a save's load, two mods and a use for each declaration. Not tried in the game yet: how
much the trees' animation scale takes the slowdown away (`move.treeSlowMultiplier`), that a landing worked out lower plays
the right animation, that the walking multiplier is not undone by the animation's own speed (PZ Optimize's parallel
animation), and a real bite survived.

The hidden-zombie fix has no bytecode hook, so what was checked against the installed game (7 October 2026, Build 42) is
that every member it reads is there, with the types it expects, in the jar alone and with PZ Optimize's loose classes first
(`IsoGameCharacter`, `IsoPlayer`, `LightingJNI`; the update order `updateAlpha` then `updateSeenVisibility` is the same in both,
and the bytecode of `TestIfSeen` the API follows is the same in the two: the loose class only lays the early return out differently).
In the synthetic game: nothing is looked at before a declaration (no line, no alpha set); a zombie in sight is shown on the
first frame; one behind a wall, outside the cone or the view distance, two floors away, behind a floor with no opening or
that the game already draws is not changed; the alpha is set on every frame; a second at 60 frames draws 10 to 17 lines for a
zombie and offers its spotting 2 to 11 times; a wall that comes between, tried at six moments of a zombie's period, stops it
within 0.1 seconds (plus a frame), as does taking the wall away; several mods join as any, `clear` and `false` turn it off,
declaring it again shows the zombie at once; a sleeping or dead player, one in a vehicle or who sees all gets nothing shown,
and a narrow cone, one all round and a player who turns change who is a candidate; a second local player is looked for on its
own; and a fault in the zombie list stops the fix alone while the other formulas go on. The game's light test: a zombie in a
lit square is shown; the same in a square with a light of 0.0001 (below the game's test) is not, and in one of 0.01 it is; a
square that goes dark hides a shown zombie within 0.1 seconds and its light coming back shows it; a zombie in a black square
at 5 squares is not shown while one at 3 squares is (the detection range is 3.5, the player's square lit), with the player's
square dark it is not either, a range of 6 shows the first and a range of 2 hides the second; a zombie within 1 square in a
square of 0.00015 is shown (the light doubles) and one at 1.5 is not; one past the view distance, and one with no square, are
not shown. The cost per frame in the synthetic
game, for 1000 to 10000 zombies on a 128 by 128 map of 4 floors with random walls (15% of the edges on each axis, 5% of the
squares solid), 60% of them drawn by the game, view 40 squares, cone 144 degrees, the player walking and turning:

| Zombies | Placed | Fix off | Fix on, mean / 99th percentile | Lines a frame |
| --- | --- | --- | --- | --- |
| 1000 | over the map | 0.000 ms | 0.012 / 0.028 ms | 7.8 |
| 3000 | over the map | 0.000 ms | 0.035 / 0.079 ms | 22.5 |
| 10000 | over the map | 0.000 ms | 0.143 / 0.282 ms | 71.3 |
| 1000 | within 35 squares | 0.000 ms | 0.012 / 0.029 ms | 16.6 |
| 3000 | within 35 squares | 0.000 ms | 0.039 / 0.069 ms | 53.0 |
| 10000 | within 35 squares | 0.000 ms | 0.198 / 0.394 ms | 175.8 |

(The game's light test is in these numbers: every line that is clear is followed by it, in handles that are constants; it
is within the noise of the same table before it was added: 0.19 to 0.21 ms for the worst case.) Of the 0.198 ms, 0.053 ms is the pass over 10000 zombies the game all draws (one array read each) and 0.152 ms the pass over
10000 that are not drawn with a cone so narrow that almost none is a candidate (their positions are read and nothing more);
the lines are the rest. The design's offline measure for the same worst case was 0.16 ms on byte arrays with 1176 lines a
frame; the lines here are fewer because of the 0.1 second cadence, and the squares of the synthetic game are objects, as the
game's are, but are not the game's. The cost in the game is to be measured there. Not tried in the game yet: that a shown
zombie is drawn (the alpha is all that is set), a zombie seen across a stair or an opening in the floor, the cost with a real
horde, and that the light of a real square keeps a zombie in the dark unseen as the game keeps it (the lighting is native; the
synthetic game's is a number for each square).

The machine hooks were put into the real bytes of `IsoObject` (the jar's and PZ Optimize's loose class, which overrides it)
and verified by the JVM. In the synthetic game: an undeclared machine is not a consumer; a declared one is, with its
consumption, and an object that is not declared, or that the game powers itself, gives the game's answer; a declaration of 0
takes the game's load away; the load of an object (0.5, 0, 1000 held at 100, -3 held at 0, a string and a NaN left out, two
keys multiplied) scales the consumption; two declarations of one sprite add and one taken back leaves the other's; a
machine that was in the world is on the chunk's list in the next frame, its generators are told once for each square, and it
is not listed again; with no player to say what is loaded nothing is listed until there is one; and 100000 rounds of six
questions allocated 3984 bytes (no call allocates). Not tried in the game yet: a machine declared at `OnGameStart` with a
generator already running; the generator's fuel use following a load key; `buildings.objects` and a network reading a
declared machine.

The helicopter's state was read from the game's bytes (the state is a protected field of an enum the game does not make
public, which the API reads by reflection) in the jar, and `LuaEventManager.triggerEvent` with four arguments is there. In the
synthetic game the state is read as `Inactive`, an event is raised for each of a target set, `changeState` with the helicopter
moving, a state written straight, a take-off and a save loaded, with the target and position; nothing is raised for a move or
for a frame with no change; and a newer API taking over while the helicopter hovers raises nothing and reads the state. Not
tried in the game yet: a real flight, and that `Hovering` is the moment above the target that a mod dropping a crate looks for.

The two hooks that tell the frame job (`Helicopter.writes:flight`, `IsoWorld.writes:currentCell`) were put into the real bytes of
`Helicopter` (the jar's; PZ Optimize has no loose one) and `IsoWorld` (the jar's and PZ Optimize's loose class) and verified by
the JVM. The stores of the helicopter's `state` and `active` are in `pickRandomTarget`, `setTarget`, `changeState`, `update`,
`deactivate`, `clientSync` and `load`; the stores of `currentCell` are in `init` and `KillCell`. In the synthetic game: an event
for each of `setTarget`, `changeState`, a state written straight, a load (which stores the flag and then the state, and raises
one event), a client sync that takes it off and one that puts it on, `deactivate` and `pickRandomTarget` with nobody; none before
the frame; none for a state that came back within a frame; a frame in which nothing was written does not ask the helicopter
anything (counted over 4000 frames); a write from another thread, and a load from another, is raised by the next frame on
the game's thread; the first look is a baseline and the next change is raised; a store of the world's cell is counted once and
seen by the next frame, a cell that changed without a store is not looked for; with a hook missing (a class without the field it
needs) the status reads `polled: ...`, the frames look every time and a store nobody counted is seen, and with the hook back it is
not looked for and a counted one is. One frame of the API with nothing declared and no helicopter flying cost 140.6 ns before
(it read the game's cell twice and the helicopter's world, helicopter and flag through reflection, the ModData, and the clock twice, every frame) and 38 to 44 ns
after (the counts compared by four users, and one reading of the clock for the grids' cadence).

`zombies.near` was tested for the nearest in order among 500 zombies (the count is not bounded, the list is), the radius, the
level, the limit, a dead zombie, no world and wrong arguments. Over 10000 zombies spread over a 2000 by 2000 map a call took
about 60 us for a radius of 5 and 170 to 220 us for a radius of 1000 (every zombie within it, the nearest 8 kept), and
allocated 649 bytes whatever the number of zombies.

The zombie sounds' three hooks were put into the real bytes of `ParameterZombieState` and `ZombieVocalsManager$Slot` (the jar's;
PZ Optimize has no loose ones) and `IsoZombie` (the jar's and PZ Optimize's loose class), each applied, and the classes passed the
JVM's verifier (`-Xverify:all`). `ParameterZombieState$State` has `Idle`, `Eating`, `SearchTarget`, `LockTarget`, `AttackScratch`,
`AttackLacerate`, `AttackBite`, `Hit`, `Death`, `Reanimate`, `Pushed`, `GettingUp`, `Attack` and `RunOver`; `IsoZombie$ZombieSound`
gives Idle 15, Lunge 40, and Hurt, Burned, DeadCloseKilled and DeadNotCloseKilled 10; `LuaEventManager.triggerEvent` with six
arguments is in the jar and in PZ Optimize's class. In the synthetic game (the game's own `setState`, `calculateCurrentValue`,
`playSound` and `DoLand` called, with the hooks in): nothing is noted or raised with nobody listening; each kind is raised with
where the zombie was and its loudness (the aggravation from the game's own `calculateCurrentValue` with a target), a searching
zombie after a lunge is not an aggravation, the same state again and the states with no sound of their own note nothing; the
voice is raised once while it plays and again once it stopped; a fall upstairs keeps its floor, a player's landing is not raised;
a zombie beyond the radius is not noted, one exactly at it is, and so is one near a second player; the largest radius of two mods
is used and a mod's 0, nil or `clear()` takes its own away; the same kind from a zombie within a second is raised once (in the
same frame or the next), another kind or zombie is not a repeat, and 40 zombies' hits are all raised; 20 moments are raised 8,
8 and 4 a frame, oldest first, and 100 leave the newest 64; a hook on another thread is raised once by the frame, and two threads
noting 40000 moments against the frames tear none; a handler that throws leaves the game's three methods as they are; a newer API
takes the listening over and the function a mod kept refuses; a world left takes the listening with it. A voice state change (the
hooked `setState`) cost 4.6 ns with nobody listening (a call that returns early before the hook: 5.5 ns, the same within the
noise), 8.6 ns listening with the zombie beyond the radius, and 17.9 ns on average when every other change was noted (the ring
written over); the hooks allocated nothing (792 bytes over 4,000,000 changes, the measurement's own). Not tried in the game yet:
how often the voice starts in a real horde (whether the game's voice event loops; see [below](#zombie-sounds)), and how often a
chasing zombie is aggravated again.

## Systems

Areas that are not formulas: the game's helicopter, which the game's Lua cannot reach, a query over the zombies the cell holds,
and the sounds zombies make that the game hands to FMOD alone. None declares anything: a mod reads them, or listens.

### The helicopter

| Call | Effect |
| --- | --- |
| `helicopter.state()` | `"Inactive"` while the game's helicopter is not flying; otherwise `state, target, x, y`: the state (`"Arriving"`, `"Hovering"`, `"Searching"` or `"Leaving"`), the character it flies to (as the game has it, a local player or nil) and its position in squares. |

One event, `OnPZToolsHelicopter(state, target, x, y)`, raised through `LuaEventManager` when the state changes: `"Arriving"` as the
game sets a target (the helicopter starts 1000 squares off the target's), `"Hovering"`, `"Searching"` and `"Leaving"` as it
goes through them, and `"Inactive"` when it is taken off (it ends, or a world is left). `x` and `y` are where the helicopter
is. The API adds the event to the game with its Lua.

The game writes the state when a target is set (`setTarget`), in `changeState`, straight in `update` (the helicopter leaves when
its target is gone or dead), when a save loads (`Helicopter.load`) and when a client is synced, and takes the helicopter off in
`deactivate` and in `pickRandomTarget` with nobody to fly to. What `isActive()` reads is the field `active`; the state is
`state`. The bootstrap counts every store of those two fields in `Helicopter` (a hook after the store, whichever method makes it
and whichever thread), and the frame job reads the state only after the count moved (see
[below](#what-the-frame-job-learns-from-the-hooks)): the two fields cover all of the writers, and no shape of a method is
relied on, so a change in a method cannot lose one. The state is read when the frame runs, not taken at the store, so that a
method that stores both fields (a load) is seen whole, and an event comes at the start of the frame after the change, on the
game's thread. A state the helicopter passes through within one frame is not seen. The first look at a helicopter (the game
starting, a save loaded while it flies, a newer API taking over, and a new world) is its state, not a change: no event is
raised for it, and a mod that starts late reads `state()`.

### What the frame job learns from the hooks

The frame job (`GameApi.frame`, once a frame on the game's thread) does no work for things that change rarely: it compares two
counts the bootstrap keeps, and looks only when one has moved. The counts are of the stores of `IsoWorld.currentCell` (the game
stores it in `init` when a world starts and in `KillCell` when it is left; `getCell()` returns it) and of the stores of
`Helicopter.state` and `Helicopter.active`. A hook only counts (an atomic increment, on any thread), so it is safe in the middle
of the game's methods; each user of a count (the formulas, the networks, the water grid, the helicopter) remembers the last count
it saw, and acts, on the game's thread, when it differs.

- A world change (the cell stored) makes the formulas and the networks compare the game's cell with the one they hold and clear
  what was declared in the world that went, and the water grid read the changes owed to squares from the world's ModData (the
  game loads it in `init` before it stores the cell; the grid also reads it with its once-a-second work and when a mod draws or
  fills, and a frame with nothing owed does nothing). Writing the definitions (`dirty`) is a flag the changes set, not a look.
- The clock is read once a frame, for the grids' once-a-second cadence, and nothing else is done by the grids between their
  seconds. The hidden-zombie fix stays per frame, as it must (the game sets the alpha back each frame), and runs only while declared.
- A store of the cell outside `IsoWorld` (`IsoCell`'s constructor, the offline `WorldConverter`) is not counted: the game stores
  the cell in `IsoWorld.init` as well, after it is built, and nothing else makes a world.

When a hook is not in the game's class (the bootstrap is older, the class changed so that the hook does not fit, or it has not
loaded), the count means nothing and the users look at every frame, as they did before the hooks: no event is lost, the frame costs
a few reflective reads more. `PZToolsAPI.hooks()` (and the `api.tsv` the app reads) says which it is for each area: `Helicopter.events`
and `IsoWorld.change` read `applied` when the hooks tell the area, else `polled: <why the hook is missing>; every frame ...`, besides
the two hooks' own entries (`Helicopter.writes:flight`, `IsoWorld.writes:currentCell`) and the log line the bootstrap writes
for a hook that did not go in.

### Zombies near a point

| Call | Effect |
| --- | --- |
| `zombies.near(x, y, z, radius, limit)` | `count, list`: how many living zombies stand on level `z` (a whole number) within `radius` squares (0 to 1000) of `(x, y)`, and the nearest `limit` of them (0 to 64; 8 when it is left out) nearest first, each a table of `zombie` (the game's `IsoZombie`), `x`, `y`, `z` and `distance`. A zombie exactly `radius` away counts. Without a world: `0` and an empty list. |

It goes through the zombies the cell holds (`IsoCell.getZombieList()`, the loaded real ones: a zombie that has not been made
yet is not on it, and nor is one that is dead), once, asking each its position through handles the compiler builds into the
loop, so that a bigger radius costs no more than the zombies in it, and a zombie that is not near costs a few nanoseconds and
allocates nothing. The list is bounded: the `limit` nearest are kept as it goes. Other levels are other calls.

### Zombie sounds

For a mod that shows where a zombie was heard, for a while, instead of following the zombies (a "presence sense", a direction
indicator): the moments a zombie makes a sound that the game hands to FMOD alone and never tells Lua of. A zombie's thumps on a
door or a window and the breaking of one already reach Lua as `OnWorldSound`, and are not repeated here. Footsteps are not
hooked: every zombie makes them all the time, and an event for each would be following the zombies.

| Call | Effect |
| --- | --- |
| `zombies.listen(handle, radius)` | The mod (its handle from `PZToolsAPI.client`) listens for the sounds of zombies within `radius` squares (0 to 1000) of a local player, across the ground; 0 or nil stops it, as `handle:clear()` does. Returns the radius in effect: the largest any mod listens with. |

One event, `OnPZToolsZombieSound(kind, x, y, z, loudness, zombie)`, raised through `LuaEventManager` on the game's thread at the
start of a frame after the sound: `kind` below, where the zombie was when it made it (`z` its level, as a number, which the mod
judges: a sound on another floor is not left out), how far the game would have it heard in squares, and the game's `IsoZombie`.
Every handler of the event gets it, at the largest radius any mod listens with; a mod that listens closer leaves out the rest.

| `kind` | When | `loudness` |
| --- | --- | --- |
| `voice` | `ZombieVocalsManager$Slot.playSound` starts the zombie's voice (`playVocals`) | 15 (`ZombieSound.Idle`) |
| `aggro` | the state its voice is played in goes to `SearchTarget` from a calm one (`Idle`, `Eating`, `GettingUp`, `Reanimate`) | 15 (`Idle`) |
| `lunge` | to `LockTarget` (the second tick of `LungeState`) | 40 (`Lunge`) |
| `attack` | to `Attack` (`AttackState`'s animation event) or to `AttackScratch`, `AttackLacerate` or `AttackBite` (set on the zombie by `BodyDamage.AddRandomDamageFromZombie` as it wounds) | 15 (the game gives an attack none; `Idle`'s) |
| `hit` | to `Hit` (its hurt sound, its hit reaction), `Pushed` (staggered back) or `RunOver` | 10 (`Hurt`) |
| `death` | to `Death` (`IsoGameCharacter.playDeadSound`) | 10 (`DeadCloseKilled`) |
| `fall` | `IsoZombie.handleLandingImpact`: a landing the game counts as a fall | 10 (`Hurt`) |

The loudness is the radius the game gives the zombie's sound in `IsoZombie$ZombieSound` (what a server tells its clients to play
it over), read from the game; the numbers above are the API's own should the game not have them. A change to `Idle`, `Eating`,
`GettingUp` or `Reanimate` makes no event, nor does a state set again (the game returns early, before the hook).

How the game makes these sounds, from its bytecode:

- **The voice.** Every 500 ms `ZombieVocalsManager` takes the 20 zombies nearest a listener that should play and gives each a
  slot; the slot starts the zombie's voice (`playVocals`, an FMOD event) only when the zombie has none playing (`vocalEvent` 0).
  `IsoZombie.updateVocalProperties` sets `vocalEvent` back to 0 when the event no longer plays, and a zombie that leaves the 20
  has its voice stopped. So `voice` comes when a zombie becomes one of the 20 nearest (again each time it comes back), and again
  each time its voice event ended and the next 500 ms round starts it: at most twice a second for each of 20 zombies, and once a
  second after the repeats are left out. Whether the game's voice event loops (one `voice` for as long as the zombie stays near) or
  ends after each moan is in the FMOD bank, not the bytecode.
- **The voice's state.** `ParameterZombieState` is the FMOD parameter of the zombie's voice (`IsoZombie.parameterZombieState`);
  `setState` returns at once for the same state, so the hook after that return sees changes only. The states that walk towards
  or look for a target (`WalkTowardState`, `PathFindState`, `ZombieIdleState`) set `Idle` on their second tick, and
  `calculateCurrentValue`, which FMOD asks while the voice plays, turns `Idle` into `SearchTarget` while the zombie has a target
  (and back without one): so the aggravation is heard only from a zombie whose voice plays (one of the 20), and a chasing zombie
  that enters those states again is aggravated again (once a second at most, after the repeats). `LungeState` sets `LockTarget`;
  `AttackState` (and `AttackNetworkState`) `Attack`; the wound a zombie makes `AttackScratch`, `AttackLacerate` or `AttackBite`;
  `IsoZombie.playHurtSound` and `ZombieHitReactionState` `Hit` (and `RunOver`); `StaggerBackState` `Pushed`; the climbing states
  set a state an animation event names.
- **The fall.** `DoLand` calls `handleLandingImpact` for a landing it counts as a fall (not while climbing or in a ragdoll fall);
  the zombie's own, which the hook starts, plays its hurt sound when the fall is one that damages (which is also a `hit`).

The hooks run on the thread that updates the zombie: the game's thread in vanilla, the world's worker with the debug option
`Threading.World` (off by default), and PZ Optimize's workers, several at once, as it updates the zombies in batches
(`pzopt.UpdateBatch`). So a hook notes the moment, never raises it: under a lock (one that nobody else holds is a
few nanoseconds) it writes the zombie, the kind and its position into a ring of 64 places, and the ring is written over from its
oldest when the frames fall behind. A moment no local player is within the radius of (squares across the ground, from each
player's position as it is then) is not noted. Nothing is allocated. While no mod listens the bootstrap holds no handler, and a
hook is one volatile read. The frame job raises at most 8 events a frame, oldest first, and leaves out the same kind from the same
zombie within a second of the last one raised (it keeps the last 32 it raised); what it leaves for the next frame waits there.

What a mod listens with is kept in the API table's metatable: a newer API takes it over, and the function a mod kept from an older
one refuses to be called. It belongs to the world it was made in: a world left drops it, and the mods listen again in the next
(at `OnGameStart`, say). A fault in the frame job stops the zombie sounds alone, once, with a line in the game's log (the hooks are
given back and `listen` answers 0); a fault in a hook gives the game's method back as it would be, logged once.

## Moodles (mechanism)

A mod defines a moodle of its own, and the game's moodle column draws it as it draws its own: in a slot of the column, at the
player's moodle size, on the game's background tinted by good or bad and by level, with the game's mouse-over text, coming in
and wiggling when its level changes. The mod says the level; the API holds no moodle's meaning. Mods that draw moodles of their
own today (Moodle Framework, workshop 3396446795) put UI elements of their own beside the column instead.
([`Moodles`](../../src/PzTools.GameBridge.Agent/java/pztools/api/Moodles.java))

### How the game does it

Read from the bytecode of Build 42.21 (`projectzomboid.jar`; PZ Optimize overrides none of these classes):

- **Types.** `MoodleType` is a registry, not an enum: `Registries.MOODLE_TYPE` holds the game's 26 types under the namespace
  `base`. `MoodleType.register(id)` registers another; the id must name a namespace (`mymod:sense`), `base` is refused
  (`Default namespace 'base:sense' is not allowed!`), and a name registered twice throws. The location is lower-cased
  (`ResourceLocation`); the type's `translationName` is the id as given. `RegistryReset.resetAll()` removes every type of
  another namespace: the game calls it as it leaves a world (`IngameState.exit`) and before it reloads its Lua
  (`Core.ResetLua`, which then makes the moodle columns again and loads the mods' Lua).
- **A character's moodles.** Only players have them (`IsoGameCharacter`'s constructor makes `Moodles` for an `IsoPlayer` that is
  not an animal). `Moodles` makes a `Moodle` of every type the registry has *when it is made*, in a map. A type registered
  later is not in a character's map, and `getMoodleLevel(type)` (and the display and description strings) then fail with a
  `NullPointerException` (tried in the game). The game's own Lua and Java ask fixed types only; a mod that goes through the
  registry (Moodle Framework does, for every type, to count the moodles shown) fails on such a type.
- **The level.** `Moodles.Update()` calls `Moodle.Update()` for each moodle once a tick; it works the level out of the
  character's stats in a chain of tests on the type (0 for a type it does not know, and 0 for a dead character but for the
  `Dead` and `Zombie` moodles) and sets it through the private `updateMoodleLevel(level)`, which says whether it changed;
  a change marks the moodles for the column (`setMoodlesStateChanged`).
- **Good or bad.** `Moodles.getGoodBadNeutral(type)` asks the private `GoodBadNeutral(type)`: 1 (good) for `FoodEaten`, 2
  (bad) for every other type. 0 is neutral.
- **The column.** `MoodlesUI`, one for each local player (`UIManager.MoodleUI`, made again by `UIManager.init` and
  `IsoCamera.SetCharacterToFollow`), keeps a slot of every type the registry had when it was made. When the moodles changed,
  its `update()` asks every slot's level: a moodle above 0 takes the next place in the column (the column's own map order),
  comes in from below when it was not shown, wiggles when its level changed and asks good or bad then; one at 0 leaves.
  `render()` draws each placed moodle: the background (`_Moodles_BGsolid`) tinted from grey to the good or bad colour of the
  game's options by level over 4 (grey for neutral), the outline, then the picture `MoodleTextureSet.getTexture(type)` at
  its own size, and for the moodle under the mouse the display and description strings. A `MoodleTextureSet` has the
  pictures of the game's own types at one size (32, 48, 64, 80, 96 or 128, the moodle size option), loaded by path; a type it
  has none for fails there (`NullPointerException`). The column draws no chevrons in Build 42.21 (only the temperature
  moodles set them, and nothing draws them); there is no joypad code of its own.
- **Text.** The display string is the translation of `Moodles_<translationName>_lvl<level>`, the description
  `Moodles_<translationName>_desc_lvl<level>`. The game's translations are JSON files,
  `media/lua/shared/Translate/<language>/Moodles.json`, read from the game and from each mod's common and version folders
  (`Translator.tryFillMapFromMods`); a key is any JSON string and is found as it is, so a key with a colon works.

### Calls

| Call | Effect |
| --- | --- |
| `moodles.define(handle, id, spec)` | Defines the mod's moodle `id` (1 to 64 letters, digits, `_`, `.` or `-`, not case sensitive), or changes the kind and pictures of one it defined. Returns the game's `MoodleType` and its translation name, `<handle name>:<id>`. `spec` is `{ kind = "good" | "bad" | "neutral", picture = path or { path1, path2, path3, path4 } }` (see [pictures](#what-a-mod-provides)). The type is registered once, as `MoodleType.register("<handle name>:<id>")`, so its location is `<handle name>:<id>` in lower case. Defined again by the same mod (also after `clear`), by a newer API that took the definitions over, or in another world, it is the type the API registered, with the id's case as first defined (the type's translation name). A handle named `base` (any case) is refused before anything is looked up: the game's own moodles are `base:...`. A type the registry has under that name that the API did not register (another mod's, through `MoodleType.register`) is never taken over. Either, a moodle another mod defined under that name, a wrong spec, or a name the game refuses is a Lua error. |
| `moodles.set(handle, id, level, playerIndex)` | The level (0 to 4) the local player of that index (0 to 3) shows; `nil` for every local player. 0 hides it. |
| `moodles.level(handle, id, playerIndex)` | The level set for that player (0 when `nil`). |

`handle:clear()` takes the mod's moodles back: they show no more (the game's next update sets them to 0; a column not updated
since, the game paused, still draws them with their pictures), `set` and `level` say the mod has no such moodle, and the type
stays in the game's registry, the mod's to define again, until the game resets it. A mod can call `define` as its Lua loads, before any character exists, or later, in a world: the API adds the
type to every character's moodles and every moodle column made before (the characters' moodles it has seen made since the game
started, through a hook in the constructor, and the local players'), so that every registered type can be asked of every
character; characters and columns made after it have it from the registry. The levels are the API's, not saved: they go back to
0 when a world is left, and a mod sets them again as a world loads (`OnGameStart`, `OnCreatePlayer`). The definitions stay with
the Lua environment: when the game resets its registry while they stay (a world left without the Lua reloaded), the API
registers them again after the world change, once no world is loading (`GameLoadingState.loader` is null: that thread makes the
player's moodles from the registry), and adds them as above; one whose name another mod registered meanwhile is not shown. A newer API takes the definitions and levels over, as it takes
over the formulas; a function a mod copied out of the table says the API was updated.

Only a local player's moodle shows a level: another character's, a remote player's included, is 0. A dead player's is 0, as the
game's update has it. Multiplayer is not blocked: on a client the local players' moodles are its own, and no message is sent.

### What a mod provides

- **Pictures.** `picture` is a path the game loads as it loads its own pictures (`Texture.getSharedTexture(path)`, mipmapped),
  such as `media/ui/MyMod/Sense_{size}.png`. `{size}` is replaced by the column's size (32, 48, 64, 80, 96 or 128), so a mod
  gives a file for each size as the game does (`media/ui/Moodles/<size>/`); a size it has no file for is drawn from the largest
  it has, scaled to the size. A path without `{size}` is one picture, scaled to every size (the column draws a picture at its own
  width and height; the API draws a copy of the game's texture that has the column's size). A list gives a picture for each level
  from 1; a level above the list has the last. A picture that is not square is scaled by its long side and centred in the
  slot. A picture the game has not read yet is drawn as it is until it has. A picture that is not there, or that the game could
  not read (`isFailure()`), is drawn as the empty frame, with one line in the game's log, and not looked for again. Vanilla pictures are 32 to 128 pixels square
  with a transparent background; the background and outline are the game's.
- **Text.** In the mod's `media/lua/shared/Translate/EN/Moodles.json` (and other languages), for each level the mod uses:

  ```json
  {
      "Moodles_MyMod:Sense_lvl1": "Uneasy",
      "Moodles_MyMod:Sense_desc_lvl1": "Something is watching.",
      "Moodles_MyMod:Sense_lvl2": "Watched",
      "Moodles_MyMod:Sense_desc_lvl2": "It is close."
  }
  ```

  The name is the translation name `define` returns, the handle's name and the id as the mod first defined it, cases kept.
- **Good and bad.** A type is one kind. A mod whose state can be good or bad (as Moodle Framework's moodles are) defines two
  moodles and shows one of them.

### Moodle Framework

Moodle Framework places its moodles below the game's column by counting the registered types whose level is above 0 for the
player (`Registries.MOODLE_TYPE:values()` and `getMoodleLevel`, the `FoodEaten` moodle from level 3). The API's types are in the
registry and in the player's moodles, so they are counted, and Moodle Framework's moodles stack below them; a type a mod registered
itself after the player was made would make that count fail instead. Its moodles and the API's do not otherwise meet.

### Hook sites

| Hook | Where | What it does |
| --- | --- | --- |
| `Moodle.Update:level` | the start | For one of the API's types, `updateMoodleLevel(level)` with the API's level, and return; for any other type (`-1`), the game's update goes on. The same method as the load's `:overload` hook. |
| `Moodles.GoodBadNeutral` | each return | The kind of one of the API's types; the game's answer for any other. |
| `Moodles.<init>` | the return | The character's moodles are kept, held weakly, so that a type defined later is added to them. Without it, only the local players' are. |
| `MoodlesUI.render` | the call of `MoodleTextureSet.getTexture(type)` | The set's picture; for a type the set has none for, the API's picture of the moodle's level at the set's size. For a type no one has a picture for (no API answers, it failed, or it no longer knows the type), the set's outline: the column would otherwise fail on every frame while the game is paused, and draw none of the moodles below it. |

A hook that fails gives the game's answer (the game's update sets the level of a type it does not know to 0, and kind 2). Without
`MoodlesUI.render` the column could not draw an API moodle, so none shows (its level is 0) and `PZToolsAPI.hooks()` says why.
The level hook is asked once a tick for every moodle of every player: a type of the game's costs one identity-map lookup, an API
type also the local players' array and, while it is shown, `isDead()`; nothing allocates.

### Verified

Against the installed game (9 October 2026, Build 42.21): the four hooks were put into the real bytes of `Moodle`, `Moodles` and
`MoodlesUI` (the jar's; PZ Optimize has none of them), checked by the ClassFile verifier, and the classes defined, linked and
initialized by the JVM over the game's jar. In the synthetic game (the `api` suite, `MoodlesTest`): a type defined after a player,
a remote player and the column were made is registered under the mod's name and is in all of them, so every registered type can
be asked of every character; a level shows for the local player alone, through the game's update and column (placed, good, wiggled
on a change and not on the same level), with the picture of the column's size, the largest scaled to a size without a file, one
path scaled, one picture a level, a picture not read yet drawn as it is and then scaled, a missing one drawn as the frame and looked
for once; a second local player has its own level, and a player and a column made after the definition have the type; a dead player
shows none; defined again it is the same type with its new kind, another mod cannot take its name, and wrong arguments and a handle
named `base` are Lua errors; a world left takes the levels and keeps the definitions; the registry reset makes a new type at the next
world, added to the player and the column; a newer API takes the definitions and levels over and finds the type in the registry;
a handler that fails gives the game's answers and the frame; `clear` hides it at the next update, and a column not updated since draws
it with its picture; a handle named `base` and a type another mod registered under a handle's name are refused; the registry is not
changed while a world loads; a picture the game could not read is the frame, looked for once; one that is not square is centred; and
a type no one has a picture for is drawn as the frame. The level hook cost 4 to 12 ns for a game's type and
8 to 22 ns for an API type (runs of the synthetic game differ that much), and allocated nothing over 3,000,000 calls; a kept picture
allocated nothing over 100,000 frames.

Not tried in the game yet: the picture drawn (the scaled copy of a texture, mipmapped), the translation keys with a colon read from
a mod's JSON, a define at load and one in a running world (the player's map and the column), the registry reset going back to the
main menu and loading another save, a second local player, and Moodle Framework's moodles stacking below.

## Text (mechanism)

A mod shows text on the screen: a line in a font, a colour and a size, that comes on, stays and goes with an effect; or a
title, a large line in the middle of the screen with a smaller one under it, in one of a few styles, one title after another.
The mod says what and when, from its own events (a quest done, a search done); the API draws it with the game's own text
drawing, once a frame, with no Lua running for it.
([`Texts`](../../src/PzTools.GameBridge.Agent/java/pztools/api/Texts.java))

### How the game does it

Read from the bytecode of Build 42 (`projectzomboid.jar`, and PZ Optimize's loose `UIManager`, `IsoCamera` and `IndieGL`,
which override the jar's; it overrides none of the text classes):

- **Drawing.** `TextManager.instance.DrawString(UIFont, x, y, zoom, text, r, g, b, a)` draws a string at a zoom: the font's
  `AngelCodeFont.drawString` puts each character's quad at its size times the zoom (`CharDef.draw`). This is what
  `ISUIElement:drawTextZoomed` calls in the game's Lua. A string has no line breaks of its own here: the API draws each
  line by itself. `MeasureStringX(font, text)` and `getFontHeight(font)` measure at zoom 1.
- **Fonts.** `UIFont` names the fonts. The usual ones (`Small`, `Medium`, `Large`, `Title`, ...) are the language's bitmap
  fonts (`media/fonts/<language>/fonts.txt`; Korean's `Large` is `zomboidLargeKorean`, 11821 characters), of a fixed
  size (`Large` is 33 to 50 pixels high by the font size option, `Small` 19 to 38), which blur when zoomed. `Massive` is 47 high and has 99 characters, Latin alone. The distance-field fonts
  (`SdfRegular`, `SdfBold`, `SdfItalic`, `SdfBoldItalic`, `SdfRobertoSans`, `SdfCaveat` and the `SdfOld...` ones;
  `media/fonts/*.fnt`, 873 to 1116 characters: Latin, Cyrillic and some signs, no Hangul) stay sharp at any zoom, but
  only through the game's shader: their pictures hold distances, not letters, and drawn as they are they show as a blur. The game's own new interface (`AtomUIText`) draws them as
  `TextManager.sdfShader.updateThreshold(0.125 / scale)`, `updateShadow`, `updateOutline`, then `IndieGL.StartShader`, the
  characters, `IndieGL.EndShader()`; the updates go into the render queue (`IndieGL.ShaderUpdate1f`), so each text has
  its own. A font's characters are `AngelCodeFont.chars`, by code: one beyond the array is drawn as `?`, one the array has
  no entry for is left out.
- **When.** `UIManager.render()` draws the interface on the main thread, as the game's state draws its frame: `OnPreUIDraw`,
  the windows (`UIElementInterface.render` for each), then the tooltip (`getToolTip()`, asked twice: whether there is
  one, then to draw it), the paused message, the fade drawn over the interface, and `OnPostUIDraw`. With the interface
  drawn into its own buffer, not on every frame (`useUiFbo`, `Core.uiRenderThisFrame`), it returns at once on the frames
  it is not drawn. PZ Optimize's loose class draws its windows through a retained cache
  (`UiRetained`) and has the same order and the same two tooltip calls.
- **Where.** `IsoCamera.getScreenLeft`, `getScreenTop`, `getScreenWidth` and `getScreenHeight(player)` give each local
  player's part of the window in the interface's pixels (half or a quarter of it in split screen). PZ Optimize's
  `IsoCamera` gives its scaled view's size instead only on the render thread during the world's pass, never on the main
  thread the interface is drawn on. Without a local player (the main menu), `Core.getScreenWidth()` and
  `getScreenHeight()` are the window.

### Calls

| Call | Effect |
| --- | --- |
| `text.show(handle, spec)` | Shows a text; returns its key (a number). `spec` below. |
| `text.title(handle, spec)` | Shows a title in a style, queued on each player's screen; returns its key. `spec` below. |
| `text.hide(handle, key, now)` | The mod's text (or title, with its line) leaves with its effect; with `now` true it goes at once, and a title still waiting leaves the queue. `true` when there was one. |
| `text.shown(handle, key)` | Whether it is on the screen or waiting. |
| `text.styles()` | The titles' styles: `{ "stamp", "discovery", "notice" }`. |
| `text.status()` | Whether the hook that draws is in the game: `"applied"`, `"not-loaded"` (the interface's class has not loaded), or why not, worded as `PZToolsAPI.hooks()` is. A mod shows the player what is not applied. |

`show`'s spec; every field but `text` may be left out:

| Field | Value | Meaning |
| --- | --- | --- |
| `text` | 1 to 512 characters | The text; `\n` breaks it into at most 8 lines. |
| `font` | a name, or a list of 1 to 8 | One of the game's `UIFont` names (`"Large"` when left out). In a list, the first that has every character of the text is used, the last when none has: `{ "SdfBold", "Large" }` is the sharp font for Latin text and the language's for the rest. |
| `size` | 0.005 to 0.5 | The height of a line as a share of the player's screen's height, whatever the font and the resolution. |
| `scale` | 0.05 to 20 | The zoom of the font instead (1 when left out), when there is no `size`. |
| `color` | `{ r, g, b, a }` or `{ r = , g = , b = , a = }`, 0 to 1 | White when left out; `a` is 1 when left out. |
| `x`, `y` | 0 to 1 | Where on the player's screen, as shares of its width and height (0.5, 0.5: the middle). The text's lines are centred on `y`. |
| `align` | `"left"`, `"center"`, `"right"` | Which side of the text is at `x` (`"center"`). |
| `shadow` | boolean | A dark copy a little below and to the right. |
| `outline` | 0 to 8 pixels | Copies around the text, in `outlineColor` (black). |
| `delay` | 0 to 30 seconds | Before it comes on. |
| `enter`, `enterTime` | `"none"`, `"fade"`, `"pop"`, `"slam"`, `"rise"`, `"drop"`; 0 to 30 seconds | How it comes on: fades in; pops from half its size past its size and back; slams down from 2.5 times its size; rises, or drops, three quarters of a line into its place as it fades in. |
| `hold` | 0 to 3600 seconds | How long it stays once on; left out, until the mod hides it. |
| `leave`, `leaveTime` | `"none"`, `"fade"`, `"rise"`, `"sink"`, `"grow"`, `"shrink"`; 0 to 30 seconds | How it goes: fades; drifts half a line up, or down; swells by 30%, or shrinks by half; each as it fades. `"none"` goes at once. |
| `player` | 0 to 3 | The local player whose screen it is on; left out, every local player's. |
| `queue` | boolean | It waits for the titles and queued texts before it on its screen (see titles). |

`title`'s spec: `text` (the title), `subtitle` (the line under it), `style` (`"stamp"` when left out), and to change the style's
`color`, `subtitleColor`, `hold` (seconds), `y`, `player`, and `now`. A style is a pair of `show` specs:

| Style | Title | Line under it |
| --- | --- | --- |
| `"stamp"` | White, `SdfBold` (or `Large`), a line 10% of the screen high at `y` 0.28 (above the player), a shadow and a faint dark outline; slams on in 0.22 s, stays 2.4 s, swells away in 0.7 s. For something done: a quest complete. | Light grey, `SdfRegular` (or `Medium`), 4.5%; fades in 0.2 s after the title, goes with it. |
| `"discovery"` | Amber (1, 0.8, 0.38), `SdfRobertoSans` (bold italic; or `Large`), 8% at `y` 0.28, a shadow; rises into place in 0.6 s, stays 2.4 s, drifts up as it fades in 0.9 s. For something found: a search complete. | Pale amber, `SdfRegular` (or `Medium`), 4.2%; rises 0.25 s after the title, goes with it. |
| `"notice"` | Cool white, `SdfBold` (or `Medium`), 3.6% at `y` 0.2; drops in in 0.35 s, stays 2.6 s, fades in 0.6 s. For news that is not an event of its own. | Grey-blue, `SdfRegular` (or `Small`), 2.6%. |

Each local player's screen has a queue of titles: one shows at a time (the title and its line), and the next starts when it
has gone. A title for every player goes into each player's queue. `now` lets a title go first: the one on that screen leaves
within 0.25 s and this one follows, before those waiting. At most 8 wait on a screen; a ninth makes the oldest waiting go. A
text with `queue` waits in the same queue.

A text's time starts when it is first drawn, not when it is shown: one shown while nothing is drawn (a loading screen) comes
on as the screen does. The time is the interface's (`System.nanoTime`), which goes on while the game is paused. A mod has at
most 64 texts shown or waiting, all mods 256; more is a Lua error. `handle:clear()` takes the mod's texts away at once. A text
belongs to the world it was shown in: leaving it takes the text away. A text for a player who is not there waits for them. A
newer API takes what is shown over at the moment it was at, keys included; a function a mod copied out of the table says the
API was updated.

Multiplayer is not blocked: the text is drawn on the machine that shows it, for its local players; nothing is sent.

### Drawing

The hook calls `Texts.draw()` once a frame from the interface's drawing (below). With nothing shown it returns after one
read of an array. Otherwise, for each local player's screen (or the window, without one), it lets the first title waiting
go when none is on that screen, then works out each text's moment from the clock (its delay, enter, hold and leave, and
when its mod hid it) and draws each line: `x` and `y` on the screen, the line's width and the font's height measured once
for the font the game has (the font size option makes the fonts again, and they are measured again), the zoom from `size`
or `scale` times the effect's, the effect's shift in lines, the alpha the effect gives times the colour's. A shadow is one
copy offset by a 24th of a line (at least a pixel) at 55% of the alpha; an outline is 8 copies at `outline` pixels. A font
the game says is a distance-field font (`TextManager.isSdf`) is drawn inside the game's shader, as `AtomUIText` does it, with
the threshold for the zoom, no shadow and no outline of the shader's own. A text hidden while it comes on leaves from where
it was. Drawing allocates nothing.

| Hook | Where | What it does |
| --- | --- | --- |
| `UIManager.render:text` | before the first of the method's two calls of `getToolTip()` | Draws the text: over the windows, under the tooltip, the paused message and the fade over the interface. The two calls are counted: a method with another number of them gets no hook. |

The text is drawn as often as the interface is: with the interface drawn at a lower rate, it moves at that rate. A hook that
is not in gives no text and `text.status()` says why; a fault while drawing is reported once in the game's log, and the
interface goes on being drawn (the tooltip and what follows it).

### A mod's use

```lua
-- Operation Acorn: a quest done stamps its title, a search done shows what was found.
local function textApi()
    local api = PZToolsAPI
    return api and api.version == 1 and api.text or nil
end

local function onQuestComplete(questName)
    local text = textApi()
    if not text then return end -- without the API, the mod's own message instead
    text.title(PZToolsAPI.client("OperationAcorn"), {
        text = getText("IGUI_OA_QuestComplete"),
        subtitle = questName,
    })
end

local function onSearchComplete(found)
    local text = textApi()
    if not text then return end
    text.title(PZToolsAPI.client("OperationAcorn"), {
        style = "discovery",
        text = getText("IGUI_OA_SearchComplete"),
        subtitle = getText("IGUI_OA_ItemsFound", found),
    })
end

-- A text of its own: a counter at the top right that stays until the mod hides it.
local key = PZToolsAPI.text.show(PZToolsAPI.client("OperationAcorn"), {
    text = "Credits: 120", font = { "SdfBold", "Medium" }, size = 0.03, x = 0.97, y = 0.06, align = "right",
    color = { 1, 0.9, 0.6 }, shadow = true, enter = "fade", enterTime = 0.3, leave = "fade", leaveTime = 0.3,
})
-- later: PZToolsAPI.text.hide(PZToolsAPI.client("OperationAcorn"), key)
```

In Korean, `getText` gives Hangul: the styles' lists fall back to the language's fonts (`Large`, `Medium`), which have it,
zoomed to the same share of the screen.

### Verified

Against the installed game (9 October 2026, Build 42): the hook was put into the real bytes of `UIManager` (the jar's, and PZ
Optimize's loose class), once each, before the first `getToolTip()` (in the jar after the windows' loop and its handler; in the
loose class after `UiRetained.loopEnd`), checked by the ClassFile verifier with the game's classes, and the class defined,
linked and initialized by the JVM over the game's jar. Every member `Texts` reads is public in the jar, and in the loose
`IsoCamera` and `IndieGL`. In the synthetic game (the `api` suite, `TextsTest`): with nothing shown the interface is drawn as
before, and 100,000 frames draw and allocate nothing; a text is drawn between the windows and the tooltip, centred, zoomed and
coloured as asked, and goes after its hold; fades are at their alpha halfway in and out; the time starts at the first frame drawn;
`hide` lets it leave as its effect says, at once with `now`, and not another mod's; lines, left and right alignment, a size as a
share of the screen, a shadow and an 8-copy outline are placed to the pixel; a font list takes the first font with every
character (Hangul to `Large`, Cyrillic to `SdfBold`, the last when none has them), a distance-field font is drawn inside the
shader with the threshold for its zoom and the others outside it, and a font made again is measured again; slam, rise, grow and pop
are where they should be at known moments, and a text hidden as it comes leaves from where it was; a stamp title and its line are
placed under one another, go together after 3.32 s, and the discovery after it waits, then shows amber in its font; `now` has the
title on the screen leave within 0.25 s and the new one follow; a Hangul title takes `Large`; a ninth waiting title makes the
oldest go; in split screen a text for every player is on both players' parts, one for a player on theirs alone, and titles queue
on each; without a player the window is used; `clear` takes one mod's texts, a world left takes its texts and a new world's stay;
wrong arguments and a 65th text are Lua errors; a drawing that fails leaves the windows, the tooltip and what follows drawn, and
draws again once it can; a newer API takes a text over at the alpha it was at, with its key, and the old functions refuse. A
frame with a stamp title and its line (12 strings) took about 0.4 us to place in the synthetic game and allocated nothing over
100,000 frames.

Not tried in the game yet: how the titles look (the sizes, the colours, the effects' timing, a zoomed `SdfBold` and
`SdfRobertoSans` through the shader, and the copies of the outline at that zoom); a Hangul title in `Large` zoomed (bitmap, so
softer); split screen; the interface's lower frame rate option; whether hiding the interface (the key that hides the HUD) hides
the text too; and the text over the main menu.

## How the game is answered

| Game question | Vanilla method | With networks |
| --- | --- | --- |
| Does this square have electricity? | `IsoGridSquare.haveElectricity()` (generators); `hasGridPower()` is the grid | Vanilla, or its building is a consumer of a supplied network |
| Is this appliance powered? (fridge, freezer, stove, washer, dryer, street light) | `ItemContainer.isObjectPowered(object, …)`, cached per tick by `IsoObject.checkObjectPowered()` | Vanilla, or it is a consumer (added on its own, or in a member building and not excluded) of a supplied network |
| Does this light switch's room have power? | `IsoLightSwitch.hasElectricityAround()` | Same rule; lights are switched per room, not per bulb |
| Is this room's light on, and this switch's lamps? | `LightingJNI.checkLights()`: a room light asks its switches' squares (`haveElectricity()`); a lamp with switches asks its first switch (`canSwitchLight()`, which asks `hasElectricityAround()`) | A switch of the room that the network supplies (its room's building is a member), not excluded |
| Can this radio or television be powered? | `DeviceData.canBePoweredHere()` | Same rule |
| Does this fixture take water from another object? | Each water question of `IsoObject` (`getFluidAmount`, `useFluid`, `hasWater`, `getUsesExternalWaterSource` and the others) reads its field `usesExternalWaterSource` | Vanilla, or it is a consumer of a network that has water |
| Which object does it take water from? | `IsoObject.checkExternalFluidSource()` | For a consumer, the producer its network's policy picks (the fullest, or the nearest network's fullest); vanilla when none holds water |
| What comes out of it, and is it tainted? | `IsoObject.createSampleAndPurifyWater(source, amount)` (TaintedWater becomes Water), behind `transferFluidTo`, `getPrimaryFluid` and `getFluidUiName`; `IsoObject.isTaintedWater()` | Vanilla; for a consumer of a network that does not purify, a sample with the producer's fluids as they are, and tainted while the producer holds TaintedWater |
| Which squares does this generator power, and how much does it burn? | `IsoGenerator.setSurroundingElectricity()`, then hourly in `IsoGenerator.update()` | No squares; the network's load |
| How much has this food aged? | `Food.updateAge(boolean)` asks its container's square (`haveElectricity()`), and ages it over the hours since it last aged | The container's object, by the appliance rule; the hours split where the network's supply started and stopped |

The bootstrap ([`ApiHooks`](../../src/PzTools.GameBridge.Agent/java/pztools/bridge/ApiHooks.java))
puts the hooks in as the classes load. Each return of the square and object questions passes the
game's answer to the API, which can only add to it; `setSurroundingElectricity()` and
`updateGenerator()` ask the API first; `Food.updateAge` passes the hours it ages the food over. Each
read of `usesExternalWaterSource` in the water questions passes the field and the object to the API;
`save` keeps the game's own field, so the world saves what vanilla would. `createSampleAndPurifyWater`
asks the API first, at its start because it reassigns its amount, and returns the API's sample when
there is one; each return of `isTaintedWater` passes the game's answer.

Each hook is checked and put in on its own. A method that is not shaped as expected (another mod
changed it, or a game update did) gets no hook, and that question gets the game's answer; the class's
other hooks still go in. Should the class fail to build with all its hooks (new stack maps over a
type that cannot be loaded, say), the hooks go in one at a time and only the ones it takes stay. The
game's log names each missing hook and why; `PZToolsAPI.hooks()` gives the same to mods, and the game
writes it to the install folder for the app, which says so on the startup loader's card
([startup loader](startup-loader.md#the-game-that-runs)).

The answers come from a snapshot the API makes again when something changes
([`PowerGrid`](../../src/PzTools.GameBridge.Agent/java/pztools/api/PowerGrid.java)).
A definition that changes marks it out of date: the next frame makes it again, or the first question
the game asks before then on its own thread, the one the mods' calls come on (a world's generators
make up for the hours away as they first update, which can come before the next frame). So a mod that
defines many objects in a row costs one snapshot, and a call that changes nothing costs none. It holds,
for each supplied network, one bit per square of its buildings, kept in blocks of 8 by 8 squares of a
level only where a room reaches, so that buildings far apart cost no more than buildings side by side;
and the networks' object rules by square. `haveElectricity()` is called very often (lighting, food,
sounds), so it costs a box test and a hash lookup per supplied network, never a walk over buildings.
An object question the game answers yes ends at once while no network has a rule for an object. With
rules, the object's square, and those of its other parts for one that covers several, are looked up
among the squares that have rules, and its sprite is read only on such a square. One the game answers
no while a network has supply is asked also whether a supplied network lights its room (a light
switch: a search of the supplied rooms' sorted ids) and whether it hangs on a wall of a supplied
building, which its sprite says (kept per sprite). For an object that no rule names, none of this
allocates. For an excluded object the API asks the game again with the networks silenced on that
thread. The water questions have their own snapshot
([`WaterGrid`](../../src/PzTools.GameBridge.Agent/java/pztools/api/WaterGrid.java)):
the areas of the networks that have water, their producers' squares and their object rules. A question
about an object that takes no pipes, which its sprite says, ends there; one about a fixture costs the
lookups of an object question.

## What vanilla does that mods need to know

- Player-built enclosed spaces with at least half a roof become buildings
  (`WorldRegionToMetaGrid`, user-defined `BuildingDef`), with touching levels combined into one. A
  player-built room touching or overlapping a map building is discarded, so an extension of an
  existing house belongs to no building.
- Basements are merged into the building above (`Basements`).
- Player-built rooms never have grid power (`IsoGridSquare.isNoPower()`).
- A running generator inside a building makes it toxic (`IsoGenerator.update()` →
  `IsoBuilding.setToxic`).
- Street lights run only on grid power, and only at night. Generators never power them.
- Without the sandbox option `AllowExteriorGenerator`, squares outside get no generator power. A
  single object added to a network is not subject to it.
- A generator burns fuel hour by hour in `update()`: on the first update after its square loads, it
  burns every hour since `lastHour` at its current consumption, until its fuel or condition runs out.
- A fixture that takes water from another object takes no water from the mains, even before the
  water shut-off (`IsoObject.isWaterInfinite()` asks `getUsesExternalWaterSource()`). So a consumer of
  a water network that has water draws from its producers from the start; without water it has the
  mains while they run, and its own reserve after.
- Water through a fixture that takes it from another object is purified: TaintedWater in the source
  comes out as Water, and the fixture says it is not tainted while its source holds anything
  (`IsoObject.createSampleAndPurifyWater`, `isTaintedWater`). Drinking from or filling at the source
  object itself gives its water as it is.
- Rain collectors are kept by a Lua global object system (`SRainBarrelSystem`) that adds rain every
  ten minutes while it rains, whether or not the collector's square is loaded, and writes the amount
  into the object when it loads. Rain is always `TaintedWater`. A change to the object's fluid while
  it is loaded reaches that system through `OnWaterAmountChange`.

## Measured in the game

On 7 October 2026, a throwaway Java agent hooked `IsoGridSquare.haveElectricity()`,
`ItemContainer.isObjectPowered` and `IsoLightSwitch.hasElectricityAround()` in a running Build 42
single-player game (debug mode, grid power and water off), powered one building and excluded chosen
objects. Retransforming the three classes took 135 ms.

| Check | Result |
| --- | --- |
| A player-built shack (walls, door, floor, roof) | A user-defined `BuildingDef`: levels 0..0, one room, 4 by 3. Player-built buildings are found in single player. |
| A map building (gas station) powered through the square hook | Its lights could be switched on and its fridges ran, on both levels. |
| Two fridges excluded through the object hook | They stopped. Appliances ask about power when something needs it (the container open: about 900 asks a second; idle: none), so a change shows at that moment. |
| One light switch excluded through the switch hook | The switch could not be used, as in a power cut, but its room stayed lit. |
| Calls to `haveElectricity()` standing near buildings | 30,000 to 44,000 a second; `hasElectricityAround()` about 3,000 a second. |

Consequences for the design:

- The square check has to cost one table lookup. 44,000 calls a second leave no room for a walk over
  buildings or for reflection.
- Lights are not decided by the switch alone. A room light (`IsoRoomLight.addInfluence`) and a
  switch's light sources (`IsoLightSource.update`, `LightingJNI`) ask the square, and the switch stays
  `activated`. Excluding a switch must also reach its light sources (`IsoLightSwitch.lights`) and its
  room's light (`IsoLightSwitch.roomId`).
- Food freshness is decided by the square: `Food.updateAge` asks `haveElectricity()` of the fridge's
  square, not the fridge. Food in an excluded fridge on a supplied square would stay chilled, so
  `Food.updateAge` needs the object's answer too. (Read from the bytecode; aging was not watched in
  the game.)

On 7 October 2026 the built `buildings` area was called from the debug Lua console of a game the
startup loader started:

| Check | Result |
| --- | --- |
| The gas station (map building), standing in its shop | Key `3570,10891,0`, not player-built. `objects`: 47, all squares loaded: fridges (0.13, a fridge and a freezer), stoves, radios, a television, a washer (power and water), a dryer, sinks, bathroom fixtures and light switches, each in the room it lights. Appliances that are off report 0; one switch that was on reported 0.002. `near` (5 squares): 9. |
| The player-built shack | Key `3578,10907,0`, player-built, its one room unnamed (`""`). No objects; `near` (5 squares): 2. |
| The app open before the game started | Found the attach-first case (see [startup loader](startup-loader.md#the-app-open-as-the-game-starts)); with it fixed, the API was there. |
| A square's object list | `PZArrayList` has no iterator (`UnsupportedOperationException`); it is read by index. |

On 7 October 2026 a power network was defined from the debug Lua console of a game the startup loader
started (sandbox generator fuel rate 0.1, no grid power): the gas station as its building, one
generator outside it as its producer.

| Check | Result |
| --- | --- |
| The hooks going in | No `[PzTools API]` report in the game's log: every power hook found its method. |
| The generator switched on | The network supplied; load 0.652 (five fridges at 0.13, one lamp at 0.002 on the upper level); the generator's consumption 0.672, which the game shows as 0.0672 after its sandbox fuel rate. The square beside the generator had no power. |
| One fridge excluded | Load 0.522; that fridge unpowered, the others powered on both levels. |
| One part of a two-square fridge excluded | Both parts unpowered; load 0.262. |
| The generator switched off | The building's lights and fridges went off. |
| The room light and food hooks (game started again) | No `[PzTools API]` report: both found their question in `LightingJNI.checkLights` and `Food.updateAge`. |
| The switch of a lit room excluded | The room went dark and the switch could not be used; after `reset` it could switch the light on again. |
| Two generators under `"sequential"`, the first with 0.05 fuel (0.067 an hour) switched on at hour 6.41 | `supply` at 6.41. The first ran out and the second started by itself: `producer` at hour 7, the first's `lastHour` (6) plus one hour of fuel. |
| The first refuelled and switched on while the second ran | `producer` at 7.41; the second was switched off. |
| The first switched off | `supply` at 7.43; the building went dark and the second stayed off. |

These checks predate out of service (8 October 2026). With it, the last row changes: the first,
switched off by hand, is out of service, and the second, on standby, takes over at once with
`producer` instead of `supply`. Not yet checked in the game: the `modData` mark of a generator
switched off while the game ran without the API, and a multiplayer server and client.

On 8 October 2026 the rest was checked with Building Utilities' `tests/ingame/api_power.lua`: a
network of its own handle over generators it put down, an extra load of 1 (0.102 litres an hour at
the sandbox's rate) and no building.

| Check | Result |
| --- | --- |
| By hand | A switched on carried. B switched on carried, A on standby. B switched off: out of service, and A took over at once. |
| A failover | A switched off by hand: out of service; C took over and B stayed off. |
| A running-out | C with half an hour of fuel from 196.45 stopped: `supply` at 197.000; A and B stayed off and out of service. |
| A source | Switched on, it carried and C went on standby. Not available, C took over; A and B stayed off. |
| `setEnabled` | Off: no supply, C stopped on standby (not out of service). On: C started again, A and B stayed off. |
| A running-out not loaded | C with an hour and a half of fuel from 197.08, F added to the list, the player taken about 9,400 squares away to F: `producer` at 199.000 (C's `lastHour` 197 plus 2), F running. Back at C later: C off and empty, no event. |
| After a load | F with fuel to 202, the world saved and loaded, the network defined again: `supply` at 202.000, and the network stopped (A, B and C not loaded). Back at A and B: both off and out of service, their marks read after the load. |

On 7 October 2026 stage 3 was checked in the same game, started again with the new bootstrap, by a
throwaway Lua script loaded from the debug console. No `[PzTools API]` report: the water hooks found
`IsoObject`'s flag reads and `checkExternalFluidSource`, and the food hook its place in `Food.updateAge`.

| Check | Result |
| --- | --- |
| `state` of the gas station's network, one generator with 9.915 fuel | Load 0.654; `hoursLeft` 147.1, its fuel over (0.02 + 0.654) times the sandbox fuel rate 0.1; the producer `running`, with its fuel and condition. |
| The shack as a child | Supplied with its parent, `parent` set, the same `hoursLeft`; the parent's load is its own plus the child's. |
| A rain barrel (made as the game makes a map's) outside the gas station, filled to 400, as the producer of a water network over the gas station | Supplied, amount 400 of 400. All 13 fixtures (sinks, toilets, a washer) took their water from the barrel; a draw of 2 from a sink left 398 in the barrel. The network removed, the sink had its own 20 again. |
| A steak in the gas station's fridge, the generator off for an hour (13.24 to 14.24) and on for half of one | Aged from 14.24: 0.0042; aged from 13.24: 0.0458. The difference is the hour off unchilled; the fridge factor seen is 0.2, the sandbox's (vanilla would give 1). |
| Found on the way | A milk carton is a fluid container in Build 42, not food: it does not age. |

On 8 October 2026 the game was started from Steam with PZ Optimize installed (its loose class
overrides include `IsoGridSquare` and `IsoLightSwitch`). At the main menu `api.tsv` had the hooks of
the classes loaded by then applied and the rest not loaded; after the save loaded, all 15 were applied,
and `PZToolsAPI.hooks()` in the debug console gave 15 of 15 applied. With one hook's line changed to a
failure by hand, the app's next round logged a warning naming `IsoGenerator.update`.

## Costs and risks
- A generator in use whose square is not loaded when its network is switched off cannot be switched
  off then: it runs on in the save. Switched on again before its square loads, the network goes on
  with it; otherwise the API switches it off as its square loads, after the game burned the hours it
  was away.
- If the API switches a generator off first (another took over), a player's switch-off of it already
  under way finds it off and does nothing (vanilla's action), so it ends on standby, not out of
  service.
- While a network is switched off its generators are off. If the API then faults, or the game starts
  without it, they stay off and the game powers nothing from them until a player switches one on, as
  in vanilla: the API does not fail closed into running them.
- The generator's hourly wear is random; computing it for hours that were not loaded draws the same
  chances in one go, not the same sequence vanilla would have drawn.
- Splitting food age changes a vanilla calculation that other mods may also change.
- A producer that breaks before its fuel runs out stops at a random hour the API does not see. The
  next producer starts from the hour the first's fuel would have run out (or now, if that hour has not
  come), later than it broke; the hours between burn no fuel.
- The moodles' types are registered again on the game's thread when the API finds the registry without them after a world change
  (see [moodles](#calls)), never while `GameLoadingState.loader` (the thread that loads a world and makes its player) is set. In
  42.21 the game resets the registry only as it leaves a world (the next frame, at the main menu, registers them again) and as it
  reloads its Lua (which makes a new API with no definitions). A game without that field gets the registration at the world change.
- User-defined buildings are removed and created again when walls change
  (`removeUserDefinedBuildingsFromCell`); a network follows its building from the square it was named
  by.

## Open questions

- How soon after the last wall or roof a player-built space becomes a building.
- Whether `buildings.at` should report an extension room that vanilla discards, and as what.
- The name of an event that says the API appeared or went away.

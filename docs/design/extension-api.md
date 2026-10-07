# Extension API for Lua mods (in progress)

[Documentation index](../README.md)

> **In progress.** Built: the `PZToolsAPI` table, `version`, `client`, the
> [buildings](#buildings-facts) area, power [networks](#networks-mechanism) under `"sequential"` and
> water networks under `"fullest"`, with children, and food aged across supply changes
> ([built so far](#built-so-far)). Planned: `"parallel"`. The first areas serve a separate power and water mod. The game facts below were read from the
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
| Adds to vanilla | Every answer is vanilla's answer, or more. Something no network contains behaves as in vanilla. |
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
| `buildings`, `networks` | The areas below. Later areas are added as fields; an area a mod does not use is ignored. |

Functions are called with a dot (`PZToolsAPI.buildings.at(x, y, z)`); a handle's functions with a
colon (`handle:clear()`). A wrong argument is a Lua error that names the function and the argument.

How the table gets there:

- The bootstrap adds one call to the end of `LuaManager.init()`, which makes each new Lua
  environment, before the game loads any Lua
  ([`ApiHooks`](../../src/PzTools.GameBridge.Agent/java/pztools/bridge/ApiHooks.java)). The call sets
  the table into the new environment, so mods find it as they load.
- The payload that answers that call loads beside the game's start. If the game's first Lua
  environment comes first, the call waits for the payload, at most 10 seconds, once per game.
- A payload that replaces another, or that came after the game's Lua started, sets the table on the
  next frame. It updates the table in place, so the tables a mod holds stay valid, and the mods'
  handles are kept. A function a mod copied out of the table (`local define =
  PZToolsAPI.networks.define`) belongs to the payload replaced: calling it is a Lua error that says
  the API was updated, and the mod reads it from `PZToolsAPI` again. A payload that fails to set the
  table leaves the game as in vanilla, and the functions mods copied give the same error.
- A game started by an install from before the API has no API until it is started again.

A mod checks `PZToolsAPI` on `OnGameStart`. Without it (PZ Tools not installed, or this game not
started by the loader), the mod changes nothing and says why. It keeps its definitions in the save
(`ModData`) and defines its networks again each time a world loads, on `OnGameStart`: a world's
generators make up for the hours it was away as they first update, and the API sees that only for
networks defined by then. Until a mod defines its networks, the game behaves as in vanilla.

When the app updates the API's code in a running game, the new code takes over the definitions of the
old one, and what the old code knew of them: the producer in use and each producer as last seen (with
whether it is on standby), the supply, the load of consumers that are not loaded, and the supply's history for food. Mods do not
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
([`Buildings`](../../src/PzTools.GameBridge.Agent/java/pztools/bridge/runtime/api/Buildings.java))

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
| Policy | How producers share the load. Power: `"sequential"` (the first producer that can run carries everything; the next starts when it stops) or `"parallel"` (all running producers share it). Water: `"fullest"` (each draw comes from the container with the highest fill ratio). |

A call that changes a network takes the mod's handle (from `PZToolsAPI.client`) first; changing
another mod's network is a Lua error. Network ids are 1 to 64 letters, digits, `_`, `.` or `-`, one
id per network across all mods. Squares are `x, y, z`; objects are a square and a sprite name.

| Call | Effect |
| --- | --- |
| `networks.define(handle, id, utility, policy)` | Creates the network, or empties the mod's own network of that id. Now `"power"` with `"sequential"`, and `"water"` with `"fullest"`. Defined again with another utility, it detaches its children. |
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
| `networks.setEnabled(handle, id, on)` | Switches the network on (`true`) or off (`false`). Switched off, it has no supply, nor have its children, and its producers are left as the game runs them. A network is defined switched on. |
| `networks.setLoadFactor(handle, id, factor)` | Power only: multiplies the load of the network, its children's included, on its way to its producer (a number from 0 to 100; 1, the default, for none). A child's factor counts inside its parent's. The API does not know why: a mod uses it for losses or savings of its own. |
| `networks.setPurify(handle, id, on)` | Water only: whether the water its fixtures give is purified, as vanilla purifies plumbed water (`true`, the default), or keeps the taint of the producer it comes from (`false`; see [fluids](#water)). Its own setting, also for a child. `false` is a Lua error in a game without both of the hooks it needs (`IsoObject.createSampleAndPurifyWater` and `isTaintedWater`, as the class is now): a game started by an install from before them gets them as it starts again; `PZToolsAPI.hooks()` says why one is missing. |
| `networks.state(id)` | `nil`, or `owner`, `utility`, `policy`, `supplied`, `enabled`; `parent` for a child; `producer` (the producer in use, its square or a table with its `source`; absent without one running); `load` (its children's that are switched on included, times its load factor; what it draws while it has supply, also while it is switched off), `ownLoad` (its own consumers' and its extra load, without the factor), `extraLoad` and `loadFactor`; `complete` (whether every consumer was loaded when the load was last worked out); `fuelPerHour` (the litres of fuel a generator burns an hour carrying the load now: its base consumption and the load, times the sandbox's fuel rate; also while a source carries it or nothing runs; for a child, that of the network at the top of its parents); `hoursLeft` (how long the fuel of the producer in use and of those on standby that can take over lasts at the load now, as last seen; absent without supply and while a source carries it); and `producers`, in order, each its square and, once seen loaded, `running`, `fuel` and `condition`, and `standby` (`true` while it is off and on standby: the API may switch it on when the one in use stops, if it can run; absent otherwise), or a source's `source`, `running` and `available`. A generator with `running` false and no `standby` is out of service: switched off by hand, and the API never switches it on (see [power](#power)); its fuel and condition tell one that could not run anyway. For water, instead of the power fields: `purify`; `amount` and `capacity` (what the producers it draws from hold, as last seen and with what draws and fills owe them: its own and, for a child, its parents') and `producers`, its own alone, each its square, `pending` (the litres draws and fills owe it, signed: below 0 for draws) and, once seen loaded, `amount` (with `pending` counted) and `capacity`. |
| `networks.consumers(id)` | The objects it supplies on loaded squares, as `buildings.objects` gives them, and whether every square was loaded. |
| `networks.draw(handle, id, amount)` | Water only: takes up to `amount` litres (0 to 1,000,000) from the producers the network draws from, the fullest first (see [draw and fill](#draw-and-fill)). Returns the litres taken and a table of what they were, by the game's fluid name (`{ Water = 12.5, TaintedWater = 2.5 }`). |
| `networks.fill(handle, id, amount, fluid)` | Water only: adds up to `amount` litres of `fluid`, a name from the game's fluid registry (`"Water"`, `"TaintedWater"`), to the producers the network draws from, the emptiest first, as far as they have room. Returns the litres added. |

One event, `OnPZToolsNetworkChange(id, what, hour)`, raised through `LuaEventManager` after the
change, never per frame. `what` is `"supply"` (it started or stopped), `"producer"` (another producer
carries it) or `"load"` (power only); `hour` is the world age in hours when it happened, which is in the past when
a producer ran out while its square was not loaded. A mod reads the rest with `networks.state(id)`.

### Built so far

- Power networks under `"sequential"`: buildings and single objects as consumers, and exclusions.
- Supply under `"sequential"`: one producer runs at a time and carries the load. The one the player
  switched on last carries it, and the API switches the others off, which puts them on standby. A
  generator the player switches off is out of service: the API never switches it on until a player
  switches it on again. When the one in use is switched off, runs out of fuel or breaks, the API
  switches on the first other producer, in order, that is on standby and can run, at once or from the
  hour the first ran out (see Time below); with none, the network stops (see Standby below).
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
  the world), the API removes them, and the mods define them again in the next world.
- Events: `OnPZToolsNetworkChange` for supply, the producer in use and the load.
- Children: a child has supply while its parent has (its supply events carry the parent's hour), and
  the parent's producer burns both loads.
- Water networks under `"fullest"`: a fixture the game can pipe water to (`waterPiped`), in a member
  building or added on its own and not excluded, takes its water from the network while one of its
  producers holds some: from the fullest of them by share of its capacity, at each question. A child's
  fixtures draw from its own producers and its parents', the fullest of them all; a parent's never
  draw from its child's. A producer's square has
  no consumers. The producers are read once a second; a `"supply"` event says when the network got or
  lost water.
- Food: the hours food in a network's fridge or freezer ages over are split where the network's
  supply started and stopped (see Food below).
- Switch: `setEnabled` switches a network off and on, for power and water.
- Load factor: `setLoadFactor` multiplies a power network's load on its way to the producer.
- Rooms: `addRoom` takes single rooms of a building instead of all of it.
- Sources: producers its mod runs (`setSource`), in the same order as generators under `"sequential"`;
  `setExtraLoad` adds a load to a network.
- Draw and fill: `draw` and `fill` move water out of and into a water network's producers, also those
  whose squares are not loaded, which take the change as they load ([draw and fill](#draw-and-fill)).
- Purification: `setPurify(false)` lets a water network's fixtures give their producer's taint
  instead of vanilla's purified water.
- Not yet: `"parallel"`.

### Power

- **Supply.** A network is supplied while its producer in use runs. Under `"sequential"` only that
  one is switched on; the API switches on the next on standby when it is switched off, runs out or
  breaks. A child is supplied
  when its parent is. A network switched off (`setEnabled`) is not, nor are its children; its
  producer in use keeps running as the game runs it and burns its base consumption alone, and a child
  switched off adds nothing to its parent's load.
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
- **Standby.** Under `"sequential"` a generator that is off is on standby or out of service. On
  standby: the API switched it off (another carries the load, or a source took over), or it stopped
  in use for want of fuel or condition; when the one in use stops, the first on standby, in order,
  that can run takes over. Out of service: switched off by hand while it could run (the API knows the
  switches it makes; any other is by hand), and the API never switches it on: not when
  the one in use is switched off, runs out or breaks, nor when a source stops. Switched on by hand, it
  carries the load as the one switched on last, and is in service again. Switching off the one in use
  hands the load to the next on standby at once (`"producer"`); only with none does the network stop
  (`"supply"`). A source is as its mod sets it: switched off by its mod while available, it stops the
  network, as before; no longer available, the next on standby takes over.
- **First seen off.** A generator that is off when the API first sees it (a new producer, a world
  loaded, a save from before standby) is on standby only if the API switched it off itself and it
  has not run since; otherwise it is out of service. The API cannot tell a generator never switched
  on from one a player switched off to work on, and it must never start one a player switched off. So
  generators new to a network are put in service by switching each on once by hand: switched on one
  after the other, the last carries the load and the others are on standby.
- **Settled state.** The generators' own saved fields (switched on, fuel, condition, `lastHour`) are
  the state, with one mark the API keeps on each generator on standby: `PZToolsStandby` in its
  `modData`, its `lastHour` when it was marked. The world saves it with the generator, as it saves
  its switch, so a world loaded again knows which generators are on standby as their squares load;
  picked up, a generator leaves it behind (`ISTakeGenerator` copies fuel and
  condition, not `modData`). The game changes `lastHour` only while the generator runs, so a mark
  whose hour is not the generator's is from before it ran again, and counts for nothing: switched on
  and off by hand where the API did not see it, it is out of service. In a running game the API keeps
  the marks also in memory, for generators on squares that are not loaded too, and a newer payload
  takes them over. After a world loads, the producer
  the game runs is the one in use; the API records it as its first update starts, before the game
  makes up for the hours away.

### Water

- **Supply.** A network has water while one of the producers it draws from holds some, as last seen
  loaded and with what draws and fills owe it, and it is switched on. A child draws from its own producers, if it has any, and from each
  parent's up to the one at the top; it has water while one of those holds some and it and each
  parent above it are switched on. A parent switched off cuts its children, whatever they hold.
  Without water, its fixtures are the game's again.
- **Draws.** A consumer fixture draws from the network: the producer with the highest fill ratio
  gives each draw. Levels converge as water is used, and space opens first in the containers that
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
  same way, so the emptiest takes first. Each container gives every fluid it holds in proportion,
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

## How the game is answered

| Game question | Vanilla method | With networks |
| --- | --- | --- |
| Does this square have electricity? | `IsoGridSquare.haveElectricity()` (generators); `hasGridPower()` is the grid | Vanilla, or its building is a consumer of a supplied network |
| Is this appliance powered? (fridge, freezer, stove, washer, dryer, street light) | `ItemContainer.isObjectPowered(object, …)`, cached per tick by `IsoObject.checkObjectPowered()` | Vanilla, or it is a consumer (added on its own, or in a member building and not excluded) of a supplied network |
| Does this light switch's room have power? | `IsoLightSwitch.hasElectricityAround()` | Same rule; lights are switched per room, not per bulb |
| Is this room's light on, and this switch's lamps? | `LightingJNI.checkLights()`: a room light asks its switches' squares (`haveElectricity()`); a lamp with switches asks its first switch (`canSwitchLight()`, which asks `hasElectricityAround()`) | A switch of the room that the network supplies (its room's building is a member), not excluded |
| Can this radio or television be powered? | `DeviceData.canBePoweredHere()` | Same rule |
| Does this fixture take water from another object? | Each water question of `IsoObject` (`getFluidAmount`, `useFluid`, `hasWater`, `getUsesExternalWaterSource` and the others) reads its field `usesExternalWaterSource` | Vanilla, or it is a consumer of a network that has water |
| Which object does it take water from? | `IsoObject.checkExternalFluidSource()` | For a consumer, the network's fullest producer; vanilla when none holds water |
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
([`PowerGrid`](../../src/PzTools.GameBridge.Agent/java/pztools/bridge/runtime/api/PowerGrid.java)).
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
([`WaterGrid`](../../src/PzTools.GameBridge.Agent/java/pztools/bridge/runtime/api/WaterGrid.java)):
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

These checks predate standby (8 October 2026). With it, the second in the row of two generators
starts only if it was on standby (switched on once by hand and then off by the API), and in the last
row the second,
switched off by the API, takes over at once with `producer` instead of `supply`. Not yet checked in
the game: a generator switched off by hand stays off through a failover, a running-out and a source
stopping; the mark in `modData` after a save is loaded again; and a generator switched on and off by
hand within the same hour that the API marked it (the API sees the switch only through the
generator's update while it runs).

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
- The generator's hourly wear is random; computing it for hours that were not loaded draws the same
  chances in one go, not the same sequence vanilla would have drawn.
- Splitting food age changes a vanilla calculation that other mods may also change.
- A producer that breaks before its fuel runs out stops at a random hour the API does not see. The
  next producer starts from the hour the first's fuel would have run out (or now, if that hour has not
  come), later than it broke; the hours between burn no fuel.
- User-defined buildings are removed and created again when walls change
  (`removeUserDefinedBuildingsFromCell`); a network follows its building from the square it was named
  by.

## Open questions

- How soon after the last wall or roof a player-built space becomes a building.
- Whether `buildings.at` should report an extension room that vanilla discards, and as what.
- The name of an event that says the API appeared or went away.

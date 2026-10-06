# Extension API for Lua mods (in progress)

[Documentation index](../README.md)

> **In progress.** Built: the `PZToolsAPI` table, `version`, `client` and the
> [buildings](#buildings-facts) area. Planned: [networks](#networks-mechanism) and everything below
> them. The first areas serve a separate power and water mod. The game facts below were read from the
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
| Single player | PZ Tools runs only in a local single-player world; so does the API. |

## Reaching the API from Lua

In a game the startup loader started, the resident runtime sets one global table, `PZToolsAPI`, in
the game's Lua environment (`LuaManager.env`) as the game's Lua starts, before any world loads. It is
not one of the extensions the player switches on and off, and it stays until the game exits. Its
functions are Kahlua `JavaFunction`s, so no class has to be exposed to Lua.

| Field | Meaning |
| --- | --- |
| `PZToolsAPI.version` | Integer, raised on any incompatible change. A mod refuses a version it was not written for. Now 1. |
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
  handles are kept.
- A game started by an install from before the API has no API until it is started again.

A mod checks `PZToolsAPI` on `OnGameStart`. Without it (PZ Tools not installed, or this game not
started by the loader), the mod changes nothing and says why. It keeps its definitions in the save
(`ModData`) and defines its networks again each time a world loads. Until it does, the game behaves
as in vanilla.

When the app updates the API's code in a running game, the new code takes over the definitions of the
old one; mods do not define anything again. A change that cannot take them over waits for the game's
restart, as other bootstrap changes do.

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
building for those, and `near` leaves out every switch that lights a room. Objects exist only on
loaded squares; the second result says whether some were missing.

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
| Children | Networks whose load this network carries. Networks form a tree; a cycle is refused. |
| Policy | How producers share the load. Power: `"sequential"` (the first producer that can run carries everything; the next starts when it stops) or `"parallel"` (all running producers share it). Water: `"fullest"` (each draw comes from the container with the highest fill ratio). |

| Call | Effect |
| --- | --- |
| `networks.define(id, utility, policy)` / `networks.remove(id)` | Creates or removes a network. Removing one gives its producers back to vanilla. |
| `networks.setProducers(id, list)` | Producer positions, in order. |
| `networks.addBuilding(id, square)` / `networks.removeBuilding(id, square)` | A building as a consumer. |
| `networks.exclude(id, object)` / `networks.include(id, object)` / `networks.reset(id, object)` | Excludes an object of a member building, adds a single object, or undoes either. |
| `networks.setParent(id, parentId)` | Makes a network a child; `nil` detaches it. |
| `networks.state(id)` | Supplied or not, load (own and children), the producer in use, time left at the current load, and for water the amount and capacity. |
| `networks.consumers(id)` | The objects it supplies, by building and room, with their consumption: the same classifier the hooks use. |

Events (raised through `LuaEventManager`, never per frame): a network's supply started or stopped,
its producer in use changed, its load changed. Each carries the network id and the game time it
happened, which can be in the past when the network's squares were not loaded.

### Power

- **Supply.** A network is supplied while a producer can run (activated, fuel, condition). Under
  `"sequential"` only the producer in use is activated; the API activates the next one when it
  stops. A child is supplied when its parent is.
- **Load.** The sum of vanilla consumption (`IsoObject.getGeneratorPowerConsumption()` and the
  constants on `IsoGenerator`) over its consumers and its children's, computed when a consumer is
  added, removed, placed or picked up, never per frame. Load of consumers in squares that are not
  loaded is the last value computed while they were.
- **Range.** A producer in a network powers no square around it. It adds itself to no chunk
  (`IsoChunk.addGeneratorPos`), and its consumption is the network's load.
- **Time.** Fuel and condition are computed from the last settled state, the load, the policy and
  the time since. The API writes the result into the generator when its square is loaded and
  advances the generator's `lastHour`, so vanilla's own catch-up does not burn the same hours
  again. Condition wear follows vanilla's hourly rule (a chance of 1 in the item's
  `ConditionLowerChance` per hour to lose 1 to 2 points).
- **Food.** Vanilla ages food in a container over the whole time since it last aged, as refrigerated
  if the square has power now, and splits that time only at the grid's shut-off. The API splits it
  also at the times its network's supply stopped and started, so a fridge that lost power while the
  player was away spoils from that moment, and one that kept power does not.
- **Settled state.** Kept in the producers' own `ModData`, so it is saved with them. The API keeps no
  other state in the save.

### Water

- **Draws.** A consumer fixture draws from the network: the producer with the highest fill ratio
  gives each draw. Levels converge as water is used, and space opens first in the containers that
  are fullest, so rain is lost only when all are full. No water is moved between containers.
- **Fluids.** Vanilla decides amount, draw and taint from the container the draw comes from, as it
  does for a fixture plumbed to a barrel.
- **Time.** Water is drawn only when a fixture is used, which happens with its square loaded. Rain
  collectors fill themselves (see below), so a water network needs no catch-up of its own.

## How the game is answered

| Game question | Vanilla method | With networks |
| --- | --- | --- |
| Does this square have electricity? | `IsoGridSquare.haveElectricity()` (generators); `hasGridPower()` is the grid | Vanilla, or its building is a consumer of a supplied network |
| Is this appliance powered? (fridge, freezer, stove, washer, dryer, street light) | `ItemContainer.isObjectPowered(object, …)`, cached per tick by `IsoObject.checkObjectPowered()` | Vanilla, or it is a consumer (added on its own, or in a member building and not excluded) of a supplied network |
| Does this light switch's room have power? | `IsoLightSwitch.hasElectricityAround()` | Same rule; lights are switched per room, not per bulb |
| Can this radio or television be powered? | `DeviceData.canBePoweredHere()` | Same rule |
| Where does this fixture's water come from? | `IsoObject.getUsesExternalWaterSource()`, `checkExternalFluidSource()` | For a consumer, the network's producer that gives the next draw |
| Which squares does this generator power, and how much does it burn? | `IsoGenerator.setSurroundingElectricity()`, then hourly in `IsoGenerator.update()` | No squares; the network's load |
| How much has this food aged? | `Food.updateAge(boolean)` | Split at the network's supply changes |

The answers to the square and object questions come from an index the API keeps up to date: per
chunk, the networks that touch it and a bitmap of their member squares. `haveElectricity()` is
called very often (lighting, food, sounds), so it costs one lookup, never a walk over buildings.

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

## Costs and risks
- The generator's hourly wear is random; computing it for hours that were not loaded draws the same
  chances in one go, not the same sequence vanilla would have drawn.
- Splitting food age changes a vanilla calculation that other mods may also change.
- User-defined buildings are removed and created again when walls change
  (`removeUserDefinedBuildingsFromCell`); a network follows its building from the square it was named
  by.

## Open questions

- How soon after the last wall or roof a player-built space becomes a building.
- Whether `buildings.at` should report an extension room that vanilla discards, and as what.
- The names of the events, and of the one that says the API appeared or went away.

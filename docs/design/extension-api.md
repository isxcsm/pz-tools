# Extension API for Lua mods (planned)

[Documentation index](../README.md)

> **Planned.** Nothing on this page is built. The first areas serve a separate power and water mod.
> The game facts below were read from the bytecode of Build 42 (`projectzomboid.jar`, 7 October
> 2026) and have not been tried in a running game.

PZ Tools changes the game through Java hooks ([game extensions](game-extensions.md)). Lua mods
cannot reach most of what those hooks reach, and what they can reach is often too slow to run often.
The extension API gives Lua mods that reach: it reports what the game knows and lets a mod override
the game's own answers. It holds no game content. Panels, networks, generator order, distances,
recipes, screens and balance belong to the mods that use it.

The first users are two mods kept outside this repository:

- a power and water mod: panels that power and water whole buildings;
- the talent mod, later: spatial queries, carried weight and formula adjustments.

Both depend on the API. Neither has a variant that runs without it; without the API, a mod changes
nothing and says why.

## Principles

| Principle | Meaning |
| --- | --- |
| No content | The API speaks the game's terms: squares, buildings, objects, generators, fluid containers, power and water. It never names a mod's concept, and it enforces no gameplay rule (how many of anything, how far, in which order). |
| Facts and overrides | A call either reads a game fact or sets an override of one of the game's answers. Nothing else. |
| Declarative | A mod sets overrides. It never registers a Lua callback that the game calls per square or per frame; the hot questions are answered in Java from the overrides. |
| Narrow | No general reflection, file or process access. Any Lua mod can call the API, so nothing in it may reach outside the game. |
| PZ Tools owns the hooks | One owner per vanilla method, so two areas that touch the same class do not conflict. Mods see areas, not hooks. |
| Owned overrides | Each override belongs to the mod that set it (a name it passes once). A mod can only change or clear its own; two mods' overrides combine by the rules of each area. |
| Runtime state only | PZ Tools keeps nothing in the save. A mod keeps its state in the save (`ModData`) and sets its overrides again each time a world loads. |
| Installed mode | Effects that must not stop with the app need the [startup loader](startup-loader.md). The API says whether the game was started that way; the mod decides what to do about it. |
| Single player | PZ Tools runs only in a local single-player world; so does the API. |

## Reaching the API from Lua

PZ Tools sets one global table, `PZToolsAPI`, in the game's Lua environment (`LuaManager.env`) when
the extension that provides it activates in a world, and removes it when that extension stops. Its
functions are Kahlua `JavaFunction`s, so no class has to be exposed to Lua.

| Field | Meaning |
| --- | --- |
| `PZToolsAPI.version` | Integer, raised on any incompatible change. A mod refuses a version it was not written for. |
| `PZToolsAPI.installed` | Whether the startup loader started this game, so that the API outlives the app. |
| `PZToolsAPI.client(name)` | A handle for one mod; every override is set through it and belongs to it. `handle:clear()` drops them all. |
| Area fields (`buildings`, `power`, `water`, `generators`) | The areas below. Later areas are added as fields; an area a mod does not use is ignored. |

A mod checks `PZToolsAPI` on `OnGameStart`, and again on a PZ Tools event when the table appears
later (the app attached after the world loaded). Until its overrides are set, the game behaves as in
vanilla.

Objects are named by position and sprite name (`x, y, z, sprite`). An object that moves is a
different object; overrides on its old name stop applying.

## Areas for power and water

### Buildings (facts)

| Call | Returns |
| --- | --- |
| `buildings.at(x, y, z)` | The building the square belongs to, as the game sees it now, or `nil`: a key, whether the player built it, its levels (lowest to highest, a basement included) and its bounds. |
| `buildings.rooms(key)` | Its rooms per level, with the game's room names. |
| `buildings.objects(key, filter)` | Objects in it that use power, water or both, with their room and vanilla power consumption. |
| `buildings.near(key, tiles, filter)` | The same for squares within `tiles` of its edge that belong to no building. |

A key is derived from the building's position; a player-built building changes key when the game
rebuilds it after its walls change, so a mod finds its building again from a square it remembers.

### Power (overrides)

| Call | Effect |
| --- | --- |
| `power.setBuilding(key, on)` | While on, every square of the building has electricity. |
| `power.setObject(object, mode)` | `"on"`: the object is powered wherever it stands; `"off"`: it gets nothing from this mod's overrides (vanilla still applies); `nil`: back to following its square. |
| `power.state(object)` | Whether the object is powered, and by what: grid, a generator's range, an override. |

Overrides only add to vanilla. A square or object that vanilla powers stays powered whatever a mod
sets. Between mods, an object is powered if any mod's overrides power it.

### Generators (overrides)

| Call | Effect |
| --- | --- |
| `generators.setRange(generator, enabled)` | Disabled: the generator powers no square around it, as if it were off, while it still runs, burns fuel, wears and makes noise. |
| `generators.setLoad(generator, load)` | Its consumption, in vanilla's units, replacing what it would compute from the objects in its range. `nil` restores vanilla. |
| `generators.state(generator)` | Activated, fuel, condition, load. |

Starting and stopping generators uses the game's own Lua functions; the API adds nothing there.

### Water (overrides)

| Call | Effect |
| --- | --- |
| `water.setSource(fixture, source)` | The fixture draws from that fluid container, wherever it is. `nil` restores the fixture's own plumbing. |
| `water.state(fixture)` | Its current source, amount, and whether the water is tainted. |

Once a fixture's source is set, vanilla code reads the amount, draws the water and decides taint, as
it does for a fixture plumbed to a barrel.

## How the game is answered

| Game question | Vanilla method | With overrides |
| --- | --- | --- |
| Does this square have electricity? | `IsoGridSquare.haveElectricity()` (generators); `hasGridPower()` is the grid | Vanilla, or its building is on |
| Is this appliance powered? (fridge, freezer, stove, washer, dryer, street light) | `ItemContainer.isObjectPowered(object, …)`, cached per tick by `IsoObject.checkObjectPowered()` | Vanilla, or the object's override is on, or it follows a powered square |
| Does this light switch's room have power? | `IsoLightSwitch.hasElectricityAround()` | Same rule; lights are switched per room, not per bulb |
| Can this radio or television be powered? | `DeviceData.canBePoweredHere()` | Same rule |
| Where does this fixture's water come from? | `IsoObject.getUsesExternalWaterSource()`, `checkExternalFluidSource()` | The source set for it, if any |
| Which squares does this generator power, and how much does it burn? | `IsoGenerator.setSurroundingElectricity()` adds the generator to every chunk in range (`IsoChunk.addGeneratorPos`) and sums the consumption of powered objects | No chunk when its range is disabled; the set load when one is set |

## What vanilla does that mods need to know

- Player-built enclosed spaces with at least half a roof become buildings
  (`WorldRegionToMetaGrid`, user-defined `BuildingDef`), with touching levels combined into one. A
  player-built room touching or overlapping a map building is discarded, so an extension of an
  existing house belongs to no building.
- Basements are merged into the building above (`Basements`).
- Player-built rooms never have grid power (`IsoGridSquare.isNoPower()`).
- Street lights run only on grid power, and only at night. Generators never power them.
- Without the sandbox option `AllowExteriorGenerator`, squares outside get no generator power. An
  object override is not subject to it.
- Vanilla's consumption figures are `IsoObject.getGeneratorPowerConsumption()` and the constants on
  `IsoGenerator`; `buildings.objects` reports them so a mod can compute load in the same units.

## Costs and risks

- `haveElectricity()` is called very often (lighting, food, sounds). The answer must be a lookup
  of the square's chunk in a table PZ Tools keeps up to date, never a walk over buildings.
- An object turned `"off"` still sits on a powered square. Paths that ask about the square, not the
  object (room light rendering, food freshness), may disagree with the object's own answer. This has
  to be checked in the game, object kind by object kind.
- User-defined buildings are removed and created again when walls change
  (`removeUserDefinedBuildingsFromCell`); `power.setBuilding` follows the building through that from
  the square it was set on.

## Open questions

- Whether player-built spaces become buildings in single player too (the method is named
  `clientProcessBuildings`), and how soon after the last wall.
- Whether `buildings.at` should report an extension room that vanilla discards, and as what.
- The event that tells a mod the API appeared or went away, and its name.
- How overrides of a mod that is removed from a save are cleared (they are runtime only, so a
  world loaded without the mod has none).

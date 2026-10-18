# PZ Extension API: design (in progress)

[Back to the README](../README.md)

> **In progress.** Built: the `PZExtAPI` table, `version`, `client`, the
> [buildings](#buildings-facts) area, power [networks](#networks-mechanism) under `"sequential"` and
> water networks under `"fullest"` and `"nearest"`, with children, and food aged across supply changes
> ([built so far](#built-so-far)), and the [formulas](#formulas-mechanism) area (the body points, the load tree, the
> speed points, the survival points, the [hidden zombies](#the-hidden-zombies), the [machines](#machines) and the
[attached animations](#attached-animations)), the
> [helicopter](#the-helicopter), the [zombies near a point](#zombies-near-a-point), the [sounds zombies make](#zombie-sounds), the [moodles](#moodles-mechanism) mods
> define and the [text](#text-mechanism) they show, with the [zombies' hits](#zombie-hits), the [containers](#containers) of buildings,
> [timers](#timers), [chunk watches](#chunk-watches), [wrapping and fitting text](#wrapping-and-fitting-a-width) and
> [many shapes at once](#drawing-many-shapes). Planned: `"parallel"`. The first areas serve two mods
> (see below). The game facts below were read from the
> bytecode and Lua of Build 42 (7 October 2026); the ones under [measured](#measured-in-the-game)
> were tried in the game with a throwaway probe.

Lua mods cannot reach most of what the game does in Java, and what they can reach is often too slow to
run often. PZ Extension API gives Lua mods that reach, through Java hooks of its own ([loader](loader.md)): it reports what the game knows, and it runs mechanisms
that are too slow or too far-reaching for Lua, such as utility networks. It holds no game content.
Panels, which objects join a network, distances, recipes, screens and balance belong to the mods
that use it.

The first users are two mods, which live in this repository's monorepo under `mods/` (the API refers to
neither, and holds nothing of theirs):

- one built on the networks and the buildings (power and water);
- one built on the formulas and the spatial queries (carried weight, adjustments to the game's formulas).

Both depend on the API. Neither has a variant that runs without it; without the API, a mod changes
nothing and says why.

## Principles

| Principle | Meaning |
| --- | --- |
| No content | The API speaks the game's terms and neutral ones: squares, buildings, objects, networks, producers, consumers, power, water. It never names a mod's concept and enforces no gameplay rule (how many of anything, how far, what joins what). |
| Facts and mechanisms | A call reads a game fact, or configures a mechanism that the API runs. The mechanism's policies are parameters chosen by the mod. |
| Declarative | A mod states what a network contains. It never registers a Lua callback that the game calls per square or per frame; hot questions are answered in Java. The callbacks the API does call are few and never per square: an event for something rare (a zombie hit, a chunk loaded) or a [timer](#timers) at a period the mod chose, raised from the frame job on the game's thread, with the counting, looking and filtering done in Java. |
| Independent of chunks | A network works whether or not its squares are loaded. Its state is computed from time, not simulated frame by frame. |
| Narrow | No general reflection, file or process access. Any Lua mod can call the API, so nothing in it may reach outside the game. |
| The API owns its hooks | One owner per vanilla method, so two areas that touch the same class do not conflict. Mods see areas, not hooks. |
| Owned definitions | Each network belongs to the mod that created it (a name it passes once). A mod can only change or remove its own. |
| Vanilla unless declared | An answer differs from vanilla's only for what a mod declared: a network it built, a multiplier or rule it set. Anything no mod declared behaves as in vanilla. A declared change may give more or less than vanilla (more power, less carried weight, a device cut off). |
| Part of the install | The API is infrastructure, not a feature with its own switch: turning it off would cut every dependent mod's power at once. It exists in a game its [loader](loader.md) started, and it is always on there. |
| Never fails closed | Other extensions are revoked when they fault. The API is not: a hook that cannot answer gives vanilla's answer for that call, and the API keeps running. A fault is reported, never turned into a power cut. |
| Single player supported | Single player is what is supported and tested. Multiplayer is not blocked, only untested: the API runs there as it does in single player, and only what would be wrong on a client (changing what producers hold) is refused. |

## Reaching the API from Lua

In a game its [loader](loader.md) started, the API sets one global table, `PZExtAPI`, in the game's
Lua environment (`LuaManager.env`) as the game's Lua starts, before any world loads. It stays until
the game exits. Its functions are Kahlua `JavaFunction`s, so no class has to be exposed to Lua.

| Field | Meaning |
| --- | --- |
| `PZExtAPI.version` | Integer, raised on any incompatible change. A mod refuses a version it was not written for. Now 1. |
| `PZExtAPI.hooks()` | A table of the API's hooks in this game, by game class and method (`IsoGridSquare.haveElectricity`): `"applied"`, `"not-loaded"` (its class has not loaded yet; most load with the first world), or why it did not go in. Where a hook is missing, that question gets the game's own answer. |
| `PZExtAPI.client(name)` | A handle for one mod; everything it defines belongs to it. `handle:clear()` removes it all. The name is 1 to 64 letters, digits, `_`, `.` or `-`; the same name gives the same handle. |
| `buildings`, `networks`, `formulas`, `moodles`, `text`, `zombies`, `helicopter`, `timers`, `chunks`, `squares`, `draw`, `floor` | The areas below. Later areas are added as fields; an area a mod does not use is ignored. `moodles`, `text`, `zombies` and `helicopter` are left out, with a line in the game's log, in a game that lacks what they read (`moodles` and `text` also in a game started by an install from before them). |

Functions are called with a dot (`PZExtAPI.buildings.at(x, y, z)`); a handle's functions with a
colon (`handle:clear()`). A wrong argument is a Lua error that names the function and the argument.

How the table gets there:

- The boot layer adds one call to the end of `LuaManager.init()`, which makes each new Lua
  environment, before the game loads any Lua
  ([`Hooks`](../src/boot/pzext/boot/Hooks.java)). The call sets the table into the new environment, so
  mods find it as they load.
- The API's code is its own jar (`pzext-api.jar`), which the boot layer loads as the game loads
  `GameWindow` ([`Host`](../src/boot/pzext/boot/Host.java)). If the game's first Lua environment comes
  first, the call waits for the API, at most 10 seconds, once per game.
- The jar is loaded once, and only if its bytes are the ones the install vouched for (the digest the
  loader gives the boot layer). A developer building the API sets `PZEXT_DEV_RELOAD=1` in the game's
  environment: the boot layer then looks at the jar about once a second, and a changed one (a build copied
  over it while the game runs) loads without the digest check. Set to the full path of a built jar instead, the
  switch has the API loaded from there, and each build loads in the running game, the install untouched (its
  folder takes administrator rights). Without the switch nothing is read again.
- An API that replaces another, or that came after the game's Lua started, sets the table on the
  next frame. It updates the table in place, so the tables a mod holds stay valid, and the mods'
  handles are kept. A function a mod copied out of the table (`local define =
  PZExtAPI.networks.define`) belongs to the API replaced: calling it is a Lua error that says
  the API was updated, and the mod reads it from `PZExtAPI` again. An API that fails to set the
  table leaves the game as in vanilla, and the functions mods copied give the same error.

A mod checks `PZExtAPI` on `OnGameStart`. Without it (the API not installed, or this game not
started by its loader), the mod changes nothing and says why. It keeps its definitions in the save
(`ModData`) and defines its networks again each time a world loads, on `OnGameStart`: a world's
generators make up for the hours it was away as they first update, and the API sees that only for
networks defined by then. Until a mod defines its networks, the game behaves as in vanilla.

When the API's code is updated in a running game (the developer's reload), the new code takes over the definitions of the
old one, and what the old code knew of them: the producer in use and each producer as last seen (with
whether it is out of service), the supply, the load of consumers that are not loaded, and the supply's history for food. Mods do not
define anything again, and a producer running on a square that is not loaded goes on carrying its
network. The old code keeps the definitions in the API table's metatable, written once a frame when
they changed, and hands them over with the rest as the new code takes over. A change that cannot take
them over waits for the game's restart, as other bootstrap changes do.

A world keeps the same as it is saved: as the game raises `OnSave` (before it saves the global
ModData), the API writes what it knows of the networks, as it hands them to a newer API, into the
world's global ModData (`PZExtNetworkState`, its `state` text). Loaded again, the world gives it to
the networks its mods define again, at the first frame some are defined (mods define them on
`OnGameStart`), for the networks and producers they still have. So a network carried by a producer
whose square is not loaded runs on from the load, without the player going there first, and so does
a generator running there (see [power](#power)); water producers there count as they were. Without
the event, or for a network defined later, the API works them out anew. A multiplayer client keeps
none: the server does.

Uninstalling the API removes it from the next game start.

Objects are named by position and sprite name (`x, y, z, sprite`). An object that moves is a
different object; so is one whose sprite changes, unless its mod gives that sprite the name of another
(`machine.spriteName`).

## Buildings (facts)

A building is what the game's map data (`IsoMetaGrid`) says it is: the rooms of one `BuildingDef`,
for loaded and unloaded squares alike. A square belongs to it when one of its rooms covers the square
(`IsoMetaGrid.getRoomAt`); walls and yards outside its rooms do not.
([`Buildings`](../src/api/pzext/api/Buildings.java))

| Call | Returns |
| --- | --- |
| `buildings.at(x, y, z)` | The building the square belongs to, or `nil`: `key`; `playerBuilt`; `minLevel` and `maxLevel` (a basement included); `minX`, `minY`, `maxX`, `maxY` (inclusive); and the square's `room` (the game's room name) and `roomId`. |
| `buildings.rooms(key)` | A list of its rooms: `id`, `name`, `level` and `rects` (a list of `x`, `y`, `w`, `h`). |
| `buildings.objects(key, filter)` | A list of its objects that use power, water or either, and whether every square of the building was loaded. |
| `buildings.near(key, tiles, filter)` | The same for squares that belong to no building, within `tiles` (0 to 32) of it on its own levels, a diagonal step counting as one. |
| `buildings.producers(key, tiles, filter)` | What could be a network's producer there: in its rooms and on squares of no building within `tiles` (0 to 32) as `near` reads them, generators (`utility` `"power"`) and objects with a fluid container that holds some (`"water"`), whichever network has them now; each `x`, `y`, `z`, `sprite`, `type` and `utility`. And whether every square was loaded. `filter` as below. |

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
wall does. Any other square of no room belongs to a building's room if it is its shell: the square
right under it is that room's (a roof, a balcony), or else a square beside it on its level is, the
four sides first (north, east, south, west), then the corners (north-east, south-east, south-west,
north-west); the first square of any building's room in that order decides, so a square between two
buildings is one's. `objects` lists what stands on a building's shell with that room, and `near`
leaves it out. A network supplies such an object with that room, and its square too, as it does
the room's own squares. Objects exist only on loaded squares; the second result says whether some
were missing.

A key is the position `"x,y,z"` of the corner of the building's lowest level that is furthest north,
then west: a square of that building, so no two buildings share it. A key that no longer names a
building (`rooms` gives `nil`, `objects` and `near` give `nil, false`) means the building was
removed or rebuilt. A player-built building changes key when the game rebuilds it after its walls
change, so a mod finds its building again from a square it remembers, and a network names its
buildings by such a square.

| Call | Returns |
| --- | --- |
| `buildings.version()` | A number that stays the same while no building and none of the game's region data can have changed: a mod keeps what it read of buildings until it differs. It moves with every swap of the region data, wherever in the world a player built, so it suits what depends on the region data (`attached`). |
| `buildings.version(x, y, z)` | The same for one building, the one at the square (`nil` without one): it moves when the building is described anew (another world, `setRooms`), and, for a building players built, when the region data was swapped in after a change in the chunks it stands in or beside, or after a change the API did not see (a swap of unknown cause moves every player-built building). A change far from the building leaves it, and a map building's moves with the first alone. The rooms built onto a building (`attached`) can change by a wall far from it, so they follow `buildings.version()`. The first call listens to the game's square changes (see [square watches](#square-watches)); a swap before it counts as unknown. |
| `buildings.counters()` | For a look: `version`, `epoch` (the number that moves when every building is described anew), `swaps` of the region data, `globalBumps` (the swaps whose cause the API did not see, which move every player-built building's version), `worldChanges` and whether the square changes are `listening`. |
| `buildings.attached(key)` | The rooms players built onto the building, which the game leaves out of it: a list of `level`, `host` (the id of the building's room the space touches most), `count` (squares), `extent` (the larger side of its box) and `rects`; empty for a building players built; `nil` without such a building, without the game's region data, or where a space grows past 1500 squares. |
| `buildings.attachedObjects(key, filter)` | The objects on those rooms' squares that belong to no building, as `near` gives them, each with the `room` and `roomId` of its space's host; and whether every square was loaded. `nil, false` when `attached` is `nil`. |
| `buildings.name(object)` | The name a world object is known by in `objects`, `near` and the networks: its sprite's, or the one `machine.spriteName` gives it. A mod keys its own records of objects by it, so a machine that changes its look stays the one it recorded. |

A room a player builds against a map building belongs to no building: the game drops a player-built
building that touches a map one (`WorldRegionToMetaGrid`), so its squares have no room. `attached`
finds such rooms from the game's region data (`IsoRegions`): a space is a region, or regions joined
by doors and windows, that is enclosed and at least half roofed (what the game takes for a room a
player built) and shares a side with a room of the building on the same level, at or above the
ground.

The game's thread reads the region data its worker thread last handed over, and swaps in new data
once the worker has worked out what changed (`IsoRegions.update`, once a frame at most); with the
swap it makes, changes and drops the buildings players build (`DataRoot.clientProcessBuildings`). A
map building is made as its world loads. So the API describes each building once and finds its
attached rooms once, and keeps both, while the world's meta grid and the region data are the same
objects; `version` counts the changes. It looks each frame and as each call that reads buildings
starts, so no swap goes unseen (one frame holds one swap). A game whose region data cannot be read
gives a new `version` at every call, keeps nothing, and has no attached rooms.

### Rooms set

A map building's rooms are the map's, whatever happens to its walls: a wall taken down leaves two
rooms where one stands, and a wall built across a room leaves one. The game remakes the rooms of
the buildings players build from their walls, but never a map building's. It has one way to change
them, its building editor (`zombie.buildingRooms`, a debug tool), which takes a building out of the
map and puts a new one in its place, and reads what it wrote back as a world loads. `setRooms` gives
a map building new rooms through it; which rooms the walls make is the mod's to say.
([`RoomEdits`](../src/api/pzext/api/RoomEdits.java))

| Call | Returns |
| --- | --- |
| `buildings.setRooms(key, rooms)` | `true` when the building has the rooms (it had them, or was given them), with a second result when the save cannot hold them (why); or `nil` and why not. `rooms` is a list of `level` (-32 to 31), `name` (optional) and `rects` (a list of `x`, `y`, `w`, `h`; 4096 rectangles at most). |

The new rooms cover the squares the building's rooms cover, each once (rooms that overlap are the
mod's error); other squares are refused, so the building keeps its key. A building players built is
refused: the game makes its rooms. Each new room is the old room it shares most squares with (the
first of them in `rooms(key)` on a tie): it takes its flags (explored, zombies spawned, lights on)
and its name unless one is given. The rooms' numbers all change (`rooms`, `at`), `version` changes,
and so do the networks' views of the building.

What the editor leaves behind is mended. The new building takes the old one's own state (the door
keys' number, the alarm, what was seen and visited, the loot respawn hour). The map's objects of the
old rooms (where a building's zombies stand) move to the room over their square. A light switch that
lit one of the old rooms lights the new room on its square, or else the room its old room became
most of. The editor's debug window, if open, is not told.

As it puts its buildings in, the editor goes over the whole map: every loaded square worked out again twice over (each square's
room; then its properties, its picture and the paths over it), the buildings and rooms of every cell numbered again, and their
numbers checked three times, a check that only logs. In game that was a quarter of a second for a house (the squares about 170 ms,
the checks most of the rest), where rooms set change one building. While rooms are set, the API does the building's part: the
squares of its box and its outside squares', with a square around them, on its levels and one above and below, are given to the
editor's passes (`updateSquares`); the cells the box is in are numbered again (`recalculateBuildingAndRoomIDs`, one cell at a
time); and the checks are left out. The editor's own use is as the game's.

The editor also tells the lighting the buildings changed (`LightingJNI.buildingsChanged`, as the game does when the rooms players
build change), and at its next update the lighting draws and lights every loaded chunk again (`checkChangedBuildings`): 70 to 120
ms in one frame in game. For rooms set, it goes over the chunks of the building with a chunk around them; when the game changed
buildings of its own before the lighting went through them, over every chunk, as the game does. With these, a wall taken down in a
house and the rooms set after it cost about 10 ms in game.

The rooms are written to the save's `pzext_rooms.bin`, in the format of the game's
`player_buildings.bin` (the building editor's file), which the game reads in its place as the world
loads (`PlayerRoomsFile.load`, before the map's data on rooms, which then gives each room its flags
by its place): the squares of the map buildings taken out, then the buildings put in their place.
The file is the API's own so that a save stays whole without the API: the game, not knowing it,
loads the map's buildings as they were (it would take the editor's buildings for ones players
built and fail loading the world dropping them). A save with no API file reads the game's own
file as before (a debug editor's rooms); the game never writes it outside the editor. A building given rooms twice
is taken out of the map once. A world that saves nothing gets no file. Not for a client of a server:
the game reads the file only where it is not one.

The file is written as the world saves, in the call that writes the map's data on rooms
(`map_meta.bin`, `IsoMetaGrid.savePart`), not as the rooms are set: the two files then agree
whenever the world was saved, and a game that stops between a change and a save loses the change
whole, not half. A save changes the file only when the rooms did. `setRooms` itself says now
whether the save can hold the rooms.

`map_meta.bin` keeps each room's flags (explored, lights, zombies spawned, roof) under the room's
number, which is made from the room's first rectangle in its cell. The rooms set have numbers
the map's own rooms have no entries under. Without the API, the game loads the map's rooms as they were and
finds no entry for them: their zombies would spawn again (in a base built there) and the game would complain of
each entry it has no room for. So the map's data gets, after each cell's own entries, one entry for each of the
map's own rooms that were replaced, with the flags of the room over most of its squares now (a number a room
of the cell has keeps that room's own entry). The map's rooms are kept at the end of the API's file (after what the
game reads of it), so that a save after a load keeps them. As the world loads with the API, the game's
complaint of those entries (`invalid room metaID`) is left out; its other complaints are not.

The editor made each building it wrote one "players built" (`new BuildingDef(true)` in
`BREBuilding`), and the game drops every such building of a cell when the rooms players build in
that cell change: a map building given rooms would be gone at the next wall built near it. While
rooms are being set, and while the game loads the API's file, the editor's buildings are map
buildings; at any other time (the game's own editor, used by hand) they are what the game makes
them. `setRooms` refuses without the hooks that read and write the file in (see the hook sites).

### Wall watches

Which rooms the walls of a map building make, told to a mod when a wall between two of its squares goes up or comes down, for a
mod that gives the building those rooms (`setRooms`). Working it out in Lua meant a table for each square and a Lua call for
each wall read: entering a building of a few thousand squares cost tens of milliseconds in one tick, and a large one hundreds.
Here the squares, their walls and the work are Java's, and Lua is called only with the rooms.
([`WallWatches`](../src/api/pzext/api/WallWatches.java))

| Call | Returns |
| --- | --- |
| `buildings.watchWalls(handle, key, fn)` | The watch's `id`; or `nil` and why: no building has the key, players built it (the game remakes its rooms), or it is larger than the game loads at once, or its rooms have more than 32768 squares. When the rooms the walls make are not the building's, `fn(key, rooms)` is called from the frame job, `rooms` as `setRooms` takes them (`level`, `rects`, `name`). |
| `buildings.unwatchWalls(handle, id)` | Stops the mod's own watch; `true` when there was one. |

A square's walls are its north and west sides as the game's regions tell a room's (`IsoRegions.calculateSquareFlags`): a wall or a
window's (`cutN`, `cutW`), a door frame (`doorFrN`, `doorFrW`); a corner post (`WallSE`) leaves the west side open. The watch reads
those of every square of the building's rooms once every chunk the building covers is loaded (until then it waits, looking every
30 frames), and keeps them with the room each square is of then. When a square's properties are worked out again (the hook of the
square watches, through `SquareDispatch`), the frame job reads its walls; when one differs from what was last seen, the squares are
grouped: two side by side are of one room when they were of the same room as the building was first read, unless a wall was built
between them since; or of two rooms when the wall between them then is down. What the map has stays: two rooms open to each other
stay two, and a room with a wall of its own inside stays one. When the groups are not the building's rooms now, `fn` is told them,
each made into rectangles (runs along x, grown down) and named after the room most of its squares were of (a room cut in two keeps
its name in both; two made one take the larger's). The groups are always worked out from that first reading, whatever rooms were
set since: a wall between two rooms taken down in part makes one, and built again makes the two again, named as they were (were
the reading moved on to the rooms set, the rest of that wall would be a wall inside one room, which parts nothing). A building whose
rooms another call changed is compared with its rooms now; one whose rooms cover other squares now is read again whole, what its
squares were first read as kept.

Cost: the hook asks each watch's box and then the square's slot in a table indexed by place (no hash, nothing allocated; 23 ns a
square change elsewhere, 37 ns in a watched building in the tests). Reading a building of 32400 squares (90 by 90 on four floors)
took 5 to 8 ms in the tests once the code was warm (36 to 59 ms the first time, before the JIT), most of it the synthetic game's
square lookup by text (the game's is by index); a wall taken down in it was worked out in about 5 ms warm. A house of a few hundred
squares is a hundredth of that. A building has at most 32768 squares in its rooms. A mod has at most 4 watches, all mods 16. Watches belong to the
world and are kept in the API table's metatable; a newer API takes them over and reads their walls again.

### Containers

The containers that world objects hold (shelves, counters, fridges, crates; not a vehicle's trunk, which belongs to no square),
walked in Java over the loaded squares of a building or around a point, and handed back flat and compact, for a mod that would
otherwise ask every object of every square for its containers each time it looks
([`Containers`](../src/api/pzext/api/Containers.java)).

| Call | Returns |
| --- | --- |
| `buildings.containers(key, options)` | `list, complete, stamp, total, opened` for the building named by `key`; `nil, false` for a key that names no building. |
| `buildings.containersNear(x, y, z, radius, options)` | The same for the squares within `radius` (0 to 32) of `(x, y)` on level `z`, in a box, whether or not they belong to a building. |

`list` is one flat table, 7 values for each container: the game's container (`ItemContainer`), the square's `x`, `y` and `z`, the
container's type (`"shelves"`, `"counter"`; the game's own string), how many items it holds, and whether it was opened: the
game's `isExplored`, or with `openedData` the object's own mark. The game sets `isExplored` when it rolls the container's loot, which
in single player is when the square first loads, so it says the loot was made, not that a player looked; a mod that needs the
second marks the objects itself (in mod data, when the player's loot window shows the container) and names the key. A mod reads it with a stride of 7 and makes no table for a container. A container that two squares reach (an object
that spans them) is listed once. `complete` is false when some of the squares were not loaded (the walk skips them); `total` and
`opened` count the containers that match the filters, changed since the stamp or not; `stamp` is a number for `options.since`.

| Option | Meaning |
| --- | --- |
| `type` | A container type, or a list of up to 16: only those. |
| `skipClasses` | The name of one of the game's object classes (`"IsoThumpable"`), or a list of up to 16: objects of those classes are left out. A name that is no class of the game is an error. |
| `skipData` | A mod data key, or a list of up to 16: objects whose mod data has one are left out. |
| `openedData` | A mod data key: a container counts as opened when its object's mod data has it, instead of by the game's `isExplored`. All the containers of one object go together. |
| `since` | A `stamp` an earlier call returned for the same question (the same key or square and radius, the same filters): only the containers that changed since, and those that call did not see, are in `list`. A stamp of another question, or one past the last 16 kept, lists everything. |
| `into` | A table to put the list in. It is written from index 1, with what an earlier call left past the end taken away, so a mod that calls every minute allocates only the numbers. |

The game keeps no change stamp for a container, so a call keeps what it saw: for each container its item count and whether it was
opened, under the stamp it returns (the last 16 stamps, and only for walks of at most 50,000 containers; the world left drops
them). `since` lists the containers whose count or flag differ. So an item replaced by another (the same count) is not seen, nor is
a container that vanished (its square unloaded or the object removed). A mod that needs those keeps its own list and calls without
`since` now and then. The walk asks each square for its objects once, and each object that has containers for them, through
handles the compiler builds into the loop: a square with none allocates nothing.

## Networks (mechanism)

A network carries one utility, power or water, from producers to consumers.

| Part | Meaning |
| --- | --- |
| Producers | Power: generators. Water: fluid containers (rain collectors, barrels, tanks), and fixtures' own water: a sink, bath or toilet of the map without a container keeps water the game's way (its reserve), which on a producer's square is the network's like a container's. Each belongs to at most one network. |
| Consumers | Whole buildings (named by one of their squares), with objects excluded from them; and single objects anywhere. An object in a building that no network contains is not a consumer unless added on its own. |
| Children | Networks that have supply while this network has, from its producers (power: whose load its producer carries; water: whose fixtures draw from its containers). A power child has no producers of its own and one parent; a water child may have its own, and several parents, and draws from its own and then from each parent's in turn. One mod's networks of one utility, each below its parents: trees for power; for water any graph without a loop (a loop is refused). |
| Policy | How producers share the load. Power: `"sequential"` (the first producer that can run carries everything; the next starts when it stops) or `"parallel"` (all running producers share it). Water: `"fullest"` (each draw comes from the container with the highest fill ratio) or `"nearest"` (from the network's own producers first, then its first parent's and those above that one, then its second's, and so on, each network once, the fullest within each; a container at least 95% full gives first wherever it is). |

A call that changes a network takes the mod's handle (from `PZExtAPI.client`) first; changing
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
| `networks.setParent(handle, id, parentId)` | Makes the network a child of another of the mod's networks, its only parent; `nil` detaches it. Removing a parent detaches its children from it. |
| `networks.setParents(handle, id, list)` | Water, or power with one at most: the network's parents, in the order it draws from them (a list of the mod's network ids; `nil` or an empty list detaches it). A parent that is already below the network is a Lua error. |
| `networks.setFluids(handle, id, list)` | Water only: the fluids its producers may hold, by the game's fluid names (`{ "Water", "TaintedWater" }`, the default, again with `nil`). A producer that holds more than a trace (0.001 litres) of any other is left out: no draw, fill or fixture reaches it, and it counts for nothing in the network's supply and amount, until it holds only what the network takes. `fill` with a fluid it does not take is a Lua error. |
| `networks.setEnabled(handle, id, on)` | Switches the network on (`true`) or off (`false`). Switched off, it has no supply, nor have its children. A power network at the top of its parents runs no producer while it is off: the API switches its running generators off, on standby, and leaves its sources off; a generator a player switches on meanwhile goes back off at once and becomes the one to start first, and so does a source its mod switches on meanwhile. Switched on again (`"supply"` at that hour), the producer in use before starts if it can run, or else the next that can take over (see [power](#power)); with none, it has no supply. A generator's turn to start first is marked on it and outlasts a world loaded again; a source's is not, and after a load the first producer, in order, that can run starts, a source only if its mod has said by then that it is available. One whose square is not loaded: if it still runs there, it carries the network on; if it is off and none other can start, the network waits for its square to load and starts it then. A generator out of service (switched off by hand) never starts. A child switched off leaves its parent's producers running. A mod sets the switch as it defines the network, before the next frame. A network is defined switched on. |
| `networks.setLoadFactor(handle, id, factor)` | Power only: multiplies the load of the network, its children's included, on its way to its producer (a number from 0 to 100; 1, the default, for none). A child's factor counts inside its parent's. The API does not know why: a mod uses it for losses or savings of its own. |
| `networks.setPurify(handle, id, on)` | Water only: whether the water its fixtures give is purified, as vanilla purifies plumbed water (`true`, the default), or keeps the taint of the producer it comes from (`false`; see [fluids](#water)). Its own setting, also for a child. `false` is a Lua error in a game without both of the hooks it needs (`IsoObject.createSampleAndPurifyWater` and `isTaintedWater`, as the class is now): a game started by an install from before them gets them as it starts again; `PZExtAPI.hooks()` says why one is missing. |
| `networks.setGridFirst(handle, id, on)` | Whether the game's own supply goes first (`false`, the default: the network supplies all its members). Power: while the grid runs (`SandboxOptions.doesPowerGridExist()`, read once a second), the consumers on squares it powers (not `IsoGridSquare.isNoPower()`: a player-built room or a NoPower zone is not one) are left out of the network's load, so its producer burns only for the rest; with the grid shut off they count again. They keep their power either way. Water: while the mains run (the world's day before the sandbox's water shut-off), a fixture the mains reach (the game's own answer, `IsoObject.isWaterInfinite`, asked with the networks silent: in a room, piped, outside a NoWater zone) takes their water, not the network's; once they are shut off, the network's. A newer API keeps it. |
| `networks.state(id)` | `nil`, or `owner`, `utility`, `policy`, `supplied`, `enabled`; `parent` (the first) and `parents` (all, in order) for a child; `producer` (the producer in use, its square or a table with its `source`; absent without one running); `load` (its children's that are switched on included, times its load factor; what it draws while it has supply, also while it is switched off), `ownLoad` (its own consumers' and its extra load, without the factor), `extraLoad` and `loadFactor`; `gridFirst`, `grid` (whether the grid runs) and `gridLoad` (what the grid carries of its own consumers now, left out of `ownLoad`; 0 without `gridFirst` or while the grid is shut off); `complete` (whether every consumer was loaded when the load was last worked out); `fuelPerHour` (the litres of fuel a generator burns an hour carrying the load now: its base consumption and the load, times the sandbox's fuel rate; also while a source carries it or nothing runs; for a child, that of the network at the top of its parents); `hoursLeft` (how long the fuel of the producer in use and of those on standby that can take over lasts at the load now, as last seen; absent without supply and while a source carries it); and `producers`, in order, each its square and, once seen loaded, `running`, `fuel` and `condition`, and `outOfService` (`true` while it is off and out of service: the API saw it switched off by hand and never switches it on; absent otherwise), or a source's `source`, `running` and `available`. A generator with `running` false and no `outOfService` is on standby: the API switches it on when the one in use stops, if it can run, as its fuel and condition tell (see [power](#power)). An API from before the field gives none, and has none out of service, so a mod reads the field without a version check; but that API also stops the network when the one in use is switched off by hand, and leaves generators running while the network is switched off. For water, instead of the power fields: `purify`; `gridFirst` and `mains` (whether the mains run); `fluids` (those it takes); `amount` and `capacity` (what the producers it draws from hold, as last seen and with what draws and fills owe them: its own and, for a child, those of every network above it; a producer that holds a fluid it does not take counts for nothing) and `producers`, its own alone, each its square, `pending` (the litres draws and fills owe it, signed: below 0 for draws) and, once seen loaded, `amount` (with `pending` counted), `capacity` and `fluids` (the litres it holds by the game's fluid names, as last seen), and `foreign` (`true` while it holds a fluid the network does not take). |
| `networks.ids()` | Every network's id, of every mod, in the order they were defined: for a look in the game (a mod knows its own). |
| `networks.revision(id)` | `nil`, or a number that moves whenever what `networks.state(id)` tells may have changed, whether the change is in the network or in one above it (a parent's supply is its children's): a definition changed, a producer seen otherwise (running, fuel, condition, in use), supply started or stopped, the load, what a water producer holds or is owed. It stays the same while nothing does, so a mod polling many networks reads `state` only for those whose number moved. It may move without the state differing (a pass that saw nothing new does not move it). The numbers only go up, across all networks and mods. |
| `networks.consumers(id)` | The objects it supplies on loaded squares, as `buildings.objects` gives them, and whether every square was loaded. |
| `networks.draw(handle, id, amount)` | Water only: takes up to `amount` litres (0 to 1,000,000) from the producers the network draws from, in its policy's order (see [draw and fill](#draw-and-fill)). Returns the litres taken and a table of what they were, by the game's fluid name (`{ Water = 12.5, TaintedWater = 2.5 }`). |
| `networks.fill(handle, id, amount, fluid)` | Water only: adds up to `amount` litres of `fluid`, a name from the game's fluid registry (`"Water"`, `"TaintedWater"`), to the producers the network draws from, the emptiest first, as far as they have room. Returns the litres added. |

One event, `OnPZExtNetworkChange(id, what, hour)`, raised through `LuaEventManager` after the
change, never per frame. `what` is `"supply"` (it started or stopped), `"producer"` (another producer
carries it) or `"load"` (power only: its load changed, or a consumer joined or left, also one that uses nothing); `hour` is the world age in hours when it happened, which is in the past when
a producer ran out while its square was not loaded. A mod reads the rest with `networks.state(id)`.

A second event, `OnPZExtGeneratorPower(generator, on, after)`, is about any generator, in a network or
not: raised whenever one is switched (`IsoGenerator.setActivated`: by a player, by a mod or the API's
networks, running out of fuel, breaking), twice. First with `after` false, before the game switches it:
`isActivated()` and the squares around it still say what they did. Then with `after` true, once they took
the new state. `on` is the new state. A generator switched to what it is already raises nothing; nor does
a world or chunk that loads. A mod that works something by the power it had does that work in the first,
and takes the new power in the second; a handler that switches the same generator again in the first is
the game's switch alone, with no events.

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
  (`IsoGenerator.updateGenerator`); and, while some consumers are not loaded, as one of the chunks
  they were missing from loads (each distinct chunk any network waits for is one lookup a pass, at
  most 1024 a pass: with more chunks waited for than that, one that loaded is found within as many
  seconds as the lookups take to go round them; nothing is gone through again until then).
  Consumers on squares that are not loaded count as they were last seen loaded,
  so a chunk that unloads changes nothing.
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
- Events: `OnPZExtNetworkChange` for supply, the producer in use and the load;
  `OnPZExtGeneratorPower` for a generator switched, before and after.
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
  networks) keeps it for them this way. The policy of the fixture's own network applies. On a producer's square
  only a fixture that holds no water of its own is a consumer: one with its own water (its container's, or its
  reserve) gives that first, to the game and to the network's other fixtures, and takes the network's once it is used
  up. A reserve takes in a fill only the fluid its fixture gives (clean water but for a fixture the game has tainted);
  its water counts in the state, and draws and fills reach it, as a container's. The producers are read once a second; a `"supply"` event says when the network got or
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
- Grid first: `setGridFirst` leaves to the game's grid and mains what they supply while they run.
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
  not loaded counts as stopped once it stopped there (see the next point), and the next takes over then
  if its own square is loaded.
- **Away.** For a generator running on a square that is not loaded, the game would burn every hour
  away at once as the square loads and roll a breakdown only once. The API runs it there hour by hour
  instead, as the game's update does while it is loaded (`IsoGenerator.update()`): from the hour the
  game last burned it up to, each hour its fuel; its condition worn by 1 or 2 one hour in its item's
  `ConditionLowerChanceOneIn` (30 for one without); and at condition 20 or below a breakdown, by fire
  one hour in 10, else by explosion one hour in 20. A breakdown leaves its condition 0 and switches it
  off, without fire or explosion, which cannot start on a square that is not loaded. It stops in the
  hour its fuel runs out, its condition reaches 0 or it breaks down, and the next producer takes over
  from that hour. `state` reports what the API found as the producer's `running`, `fuel` and
  `condition`. As the square loads, before the game's update and before the API reads it, the
  generator takes that state: its fuel and condition, switched off if it stopped (on standby: a
  generator that broke down or ran out is not out of service), and its `lastHour` the hour the API ran
  it up to, so the game burns no hour twice and rolls no breakdown for them. A loaded generator is the
  game's alone. A newer API taking over goes on with what this one found, and so does a world loaded
  again from what it saved.
- **Food.** Vanilla ages food in a container over the whole time since it last aged, as refrigerated
  if the square has power now, and splits that time only at the grid's shut-off. The API splits it
  also at the times its network's supply stopped and started, so a fridge that lost power while the
  player was away spoils from that moment, and one that kept power does not. The API keeps those
  times in memory, from when it first works a network out: supply it then finds running counts as
  running before, and a producer that ran out meanwhile stops it at the hour its fuel ran out. The
  hours a network or a parent above it was switched off count as without supply. A fridge
  with the game's own power now (the grid, a generator in range), an excluded one and frozen food age
  as in vanilla. Freezing and thawing follow the power now, as in vanilla. The times are not saved: a
  world loaded again starts them anew; a newer API takes them over.
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
  newer API taking over from one before the marks) is out of service if it carries the
  out-of-service mark, or if it is off, can run, and carries the running mark: it was switched off
  where the API did not see it, the game running without it. Off and unable to run, it stopped by
  itself, and is on standby. Off without either mark (never seen running in a network by this API),
  it is on standby.
- **Settled state.** The generators' own saved fields (switched on, fuel, condition, `lastHour`) are
  the state, with three marks the API keeps in the `modData` of a network's generators, each written
  as it changes, never per frame. `PZExtRunning` (`true`) while the API sees it running; it goes
  when the API sees it stop or switches it off. `PZExtOutOfService` (`true`) on one out of service;
  it goes when it is seen running. `PZExtResume` on the one to start first when its network,
  switched off, is switched on again: its `lastHour` when it was marked, read only while the network
  is off. The game changes `lastHour` only while the generator runs, so a resume mark whose hour is
  not the generator's is from before it ran again, and counts for nothing. The world saves the marks
  with the generator, as it saves its switch, so a world loaded again knows them as their squares
  load; picked up, a generator leaves them behind (`ISTakeGenerator` copies fuel and condition, not
  `modData`), and one placed there instead is new. A generator that leaves the producers loses its
  marks at the next frame if its square is loaded, and so does one switched on in no network: the
  marks are for network generators. In a running game the API keeps them also in memory, for
  generators on squares that are not loaded too, and a newer API takes them over; one from before
  the marks hands over none, and the next frame reads them from the generators as at first sight.
  After a world loads, the producer in use is the one the world saved (see above); without it, the one
  the game runs, which the API records as its first update starts, before the game makes up for the
  hours away.
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
- **Taken fluids.** A network takes water, clean or tainted, unless its mod names others
  (`setFluids`). A producer that holds more than a trace of anything else (a barrel of fuel, a tub
  with bleach in it) is left out as long as it does: fixtures neither draw from it nor see its
  water, `draw` and `fill` pass it by, and it adds nothing to the network's amount. Emptied, or once
  what it holds is only what the network takes, it is the network's again.
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
  collectors fill themselves, also far away (see below), so a water network needs no catch-up of its own.

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
- **Rain collectors far away.** As a chunk unloads, an object whose fluid container catches rain
  hands that container to a meta entity at its position (`GameEntityManager`,
  `FluidContainer.isQualifiesForMetaStorage`); the game's entity engine keeps updating it on the game's
  thread (`FluidContainerUpdateSystem`: rain in, a leak of petrol out), saves it with the world, its
  position included, and gives it back to the object as the square loads. So a producer whose square
  is not loaded but whose containers the game keeps that way is drawn from and filled in those
  containers, at once, as a loaded one is, owing nothing; there is no object to sync or to raise
  `OnWaterAmountChange` for. What was owed to its square before goes into them at the next frame. The
  network's supply, `amount` and the producer's `amount` follow them once a second. The API finds
  them by position in the engine's meta entities, indexed again when their number changes, also in a
  world loaded again before the square was seen. A fixture still draws only from loaded containers.
- **Not loaded.** Any other producer whose square is not loaded is drawn and filled as last seen, with what it
  is owed already, its fluids included; the change is owed to its square. A producer never seen loaded
  since the networks were defined takes neither. `state` counts what is owed in `amount` and reports
  it as `pending`.
- **Owed.** What is owed belongs to the world, by square, not to a network: defining a network again
  or changing its producers loses none. The world keeps it in the game's global ModData under
  `PZExtPendingFluids` (`next`, the next sequence number, and `deltas`, a list of `x`, `y`, `z`,
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
  (`PZExtFluidsApplied`), which is saved with them; a square takes no change at or below it, and once
  seen loaded, `state` and the supply count none of them as owed while it is not loaded. A number is past
  every one given, read or seen taken in the game, and a newer API goes on from the last; it is past
  the clock as well, so that a change owed in a game started again after such a world is numbered past
  the ones taken. A square never seen loaded since the world loaded counts every change read as owed, as
  only its containers know which it took.
- **Multiplayer.** Only the server, or a single-player game, changes what producers hold: on a
  multiplayer client `draw` and `fill` are a Lua error.
- Rain into a producer that is not loaded is the game's own, in the container it keeps running (see
  rain collectors far away); a barrel without a rain catcher is not kept, and changes only as owed.

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
| `formulas.points()` | `{ [point] = status }` for every point, worded as `PZExtAPI.hooks()` is: `"applied"` when every hook the point needs went in, `"not-loaded"` while its class has not loaded, why one did not go in, `"partial: ..."` when some did and one did not, or `"unavailable: ..."` when the game lacks what a point reads. A mod shows the player what is not applied. |
| `formulas.tune(name, value)` | Changes one of the numbers the formulas work with while the game runs (a tuning: one value for the game, not declared by a mod, not saved; a game starts with the defaults), and answers its value; with no value it goes back to its default. Read as a formula works, so the next frame has it. For tuning in the game rather than by a build: the defaults are then made the tuned values. |
| `formulas.tunings()` | `{ [name] = { value, default, min, max, about } }` for every tuning. Now night sight's: `nightSight.floor` (1: the lift for each 1 of the value, at most 0.45 in all); see [night sight](#night-sight). |
| `formulas.nightSight()` | What night sight is doing now, read-only, for a look in game: `{ level, hooks, floor, sources, failed, files, programs, settings, problem }` (the declared value; the point's hooks; the lift now, of the full light; how many shader sources the game loaded got the step, how many of them did not compile with it and were compiled again without, and their files; how many linked programs took the lift the last time it was set, and how many times it was set; why night sight does not work, if it does not: a game whose lighting it cannot read, or no program taking the lift). |

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
| `carry.itemEfficiency` | table: item type to -0.9 to 100 | add per name | The same by the item's type (`isItemType`), e.g. `base:moveable`. An item's efficiencies (its category's, its full type's and its types') add; its own weight is divided by 1 plus the sum. |
| `carry.fullTypeEfficiency` | table: full type to -0.9 to 100 | add per name | The same for the items of one full type (`getFullType`, `Module.Name`), e.g. one mod's own can. The name is checked for its form only: items load with their scripts, after a mod may declare. An item's own weight includes what a fluid container holds (the game counts a litre as 1). |
| `carry.efficiencyKey` | name or list of names | join | A carrying efficiency an item holds itself: each key of its `modData` that holds a number adds it to the item's efficiencies above (-0.9 to 100 each), so one item of a type can be lighter than the rest. The load reads the key when the item's weight is counted again; a mod that changes the number tells the game the weight changed (`item:setActualWeight(item:getActualWeight())`). |
| `uses.modDataKey` | name or list of names | join | Uses an item holds itself: each key of its `modData` that holds a number (0.1 to 100) divides the item's use delta (`getUseDelta`, and every read of the field in `InventoryItem` and `DrainableComboItem`: `getMaxUses`, the current uses), so `2` gives a blowtorch twice its uses at the same fill. Its number of uses saved stays; a save loaded without the key fills it past its most until used. |
| `craft.carryKeys` | name or list of names | join | The `modData` keys a craft hands on: when a recipe uses an item up and makes one of the same full type (a blowtorch refilled), before the recipe's `OnCreate` runs (`CraftRecipeData.luaCallOnCreate`) the new item takes the used item's keys and, when the player named it, its name. The first used item of that type that holds a key is the one; an item of another type takes nothing. |
| `item.nameKey` | name or list of names | join | The name an item holds itself: under the first of these keys of its `modData` that holds a string, a translation key; the item is named by its translation in the game's language of the moment (`Translator.getText`), so one item of a vanilla type is named apart from the rest and its name follows a change of language. A name a player gave (`isCustomName`) is the player's and stays. The kinds that dress a name dress this one (a worn, bloody or rotten one). Read where the item's naming methods read its name (`getName`, `getDisplayName`); the saved name stays the type's. See [one item of a vanilla type](#one-item-of-a-vanilla-type). |
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
| `infection.biteShield` | boolean | any | While declared true, the next zombie bite on the local player takes the infection it sets out of the part (`isInfected` and `isFakeInfected`, as they were before the bite; the wound infection and the bite itself stay), uses the shield up and raises `OnPZExtBiteSurvived(bodyPartIndex)` on a later frame. It is armed once each time it becomes declared: to arm it again a mod declares it `nil` or `false` and then `true`; while any mod keeps declaring it, one use is all there is. Only the bite a zombie makes (`BodyDamage.AddRandomDamageFromZombie`) counts, not a bitten part a save loads. |
| `fall.landingRemap` | 0 to 1000, floors | add | Floors of a fall forgiven: a landing (`IsoGameCharacter.DoLand(speed)`) is worked out as if from that many floors lower (the speed becomes `sqrt(speed^2 - 2 g x floors)`, `g` being `FallingConstants.IsoFallAcceleration`), or not as a fall at all when it was not as high as that. A fall at the speed that kills (`FallingConstants.lethalFallThreshold`) or above is left as the game has it, so the shift never turns a lethal fall into a survivable one. Damage is linear in the height of the fall, so half a floor off a one-floor fall halves the damage. |
| `fall.heightMultiplier` | 0 to 100 | multiply | Times the height of a fall: a landing (`IsoGameCharacter.DoLand(speed)`) is worked out as if from the height times the value (the speed times its square root), before `fall.landingRemap` forgives its floors. Everything the game works out from the landing follows: the kind of fall (light, hard, severe, lethal) and so the landing animation, being thrown down and dropping what is held, the damage (linear in the height) and the lethal height (3.5 floors over the value). The weight carried only scales the damage, so a fall at the lethal height kills whatever is carried. |
| `fall.impactMultiplier` | 0 to 100 | multiply | Times the damage a landing does (`handleLandingImpact`, which works it out from `FallDamage.getImpactIsoSpeed()` squared): the speed it reads is multiplied by the square root of the value. What kind of fall it is (light, hard, lethal) comes from the landing and does not change. |
| `loot.spawnMultiplier` | 0 to 100 | multiply | Times the chance an item is put into a container or on a corpse (`ItemPickerJava.getActualSpawnChance`), for containers filled from now on; one already filled stays. Not tied to a character. |
| `loot.ammoMultiplier` | 0 to 100 | multiply | Times the ammunition modifier of the loot (`ItemPickerJava.getLootModifierFromType("Ammo")`), which the chance above is worked out with. |
| `vision.darknessRestore` | 0 to 1, a reduction | reductions | The part of the dark the local player sees in that is taken away: `LightingJNI.getLumaInverted(character)` (0 light to 1 dark, which the vision cone and the shadows read) becomes `dark x (1 - value)`. The brightness of the screen is the native lighting's and does not change. |
| `vision.coneAdd` | -1000 to 1000, degrees | add | Degrees added to the width of the vision cone (`LightingJNI.calculateVisionCone`), where the game's traits add theirs: after its first limits (18 to 180) and before the worn items' multiplier and the last limits (18 to 360). Full-angle degrees; the cone is smoothed over time by the game as before. |
| `vision.nightSight` | 0 to 1 | the largest | Night sight for the local player: the light every square the player has seen is drawn with is lifted, the dark the most (to `nightSight.floor` x the value of the full light, at most 0.45; a sealed room too), and what the lift adds is drawn in a cold grey, as the eye's rods see, while what the game's own light shows keeps its colour (a lamp, a fire, the day, which leaves little to lift). The tiles (also those PZ Optimization's pixel light lights per pixel), the walls cut away for the player, characters, items, doors and vehicles are all drawn so. The squares' own light, which the vision cone and reading ask, is the game's; a zombie the game keeps unseen for the dark alone, on a square the player sees lifted, is shown (the light of its test lifted as the squares are, worked as [the hidden zombies](#the-hidden-zombies) are, with or without that point declared). A square the player has never seen (an unexplored room, which the game draws black) is left as the game draws it. The lift goes into the light each square's corners hand, and the shaders that draw the world undo it and grey what it added (see [night sight](#night-sight)). |
| `machine.baseConsumption` | table of sprite name to 0 to 1000 | add | Power use for objects of those sprites, in the game's units (a vanilla appliance is 0.03 to 0.13 and a generator's own base is 0.02): see [machines](#machines). A mod's machines are consumers of a generator in range, and of a network, with no other code. |
| `machine.loadKey` | a name, or a list of names | join | The keys of an object's mod data (`object:getModData()`) that scale its declared consumption: each holding a number multiplies it, so that a machine at rest, at work or broken draws as its mod sets it. |
| `machine.spriteName` | table of sprite name to sprite name | the first mod's | The name objects of a sprite are known by in `buildings.objects`, the networks and their rules, in place of the sprite's own: a machine that shows its state by changing its sprite (lit, running) gives its other looks the name of one, and stays one object, kept in the networks it was added to. One step: a name given is not looked up again. Where two mods name one sprite, the mod whose id comes first keeps it. Not tied to a hook. |
| `anim.stepKey` | a name, or a list of names | join | The keys of an object's mod data under which a number other than 0 has the animations attached to the object stepped by the game each frame it draws them, as the game steps a sprite's (`IsoSprite.update`: at each instance's own speed, looping, not while the game is paused), and the object drawn every frame as a fire is; see [attached animations](#attached-animations). Any other object's attached animations are drawn as in vanilla, never stepped. |
| `outline.models` | boolean | any | While any mod declares it true, the game's own object outline is drawn on what the game leaves out: objects drawn as models (doors, built furniture) and vehicles; until one does, the game's passes are its own. See [outlines](#outlines). |
| `vision.hiddenZombieFix` | boolean | any | While any mod declares it true, the zombies the player sees and the game does not draw (the shadow vision's bug: a zombie in the cone with nothing between it and the player, on a square the game finds unseen) are drawn, as long as the game's own light test would let it be seen. Worked each frame from the game's list, not by a hook: see [the hidden zombies](#the-hidden-zombies). |

The load counts an item of the character's inventory as the game does (unequipped, equipped, or on the hotbar, with a worn
bag's weight reduction on what is inside it), and a formula only changes the weight the game reads: the efficiencies above,
item by item, and a bag by what is inside it. The same weight is what `hasRoomFor` adds when the local player's inventory
is asked whether an item fits, whether directly or through a worn bag; a bag's own room still takes the item's real
weight. Another character, a crate, a vehicle and the floor count weight as vanilla.

The survival points change the local player's answers only (the loot points are not tied to a character); another character,
a zombie and a player of another machine get the game's. Every one is read from a field when asked and calls no Lua.

The event `OnPZExtBiteSurvived(bodyPartIndex)` is raised through `LuaEventManager` on the frame after a bite the shield
took the infection out of (the index counts as `BodyPartType.ToIndex`), as `OnPZExtNetworkChange` is raised; the API adds
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

The sprite is the name objects are known by in `buildings.objects` (the object's sprite name, or its sprite's, or the
name `machine.spriteName` gives it). Objects of
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

### Attached animations

The game draws the animations attached to an object (`IsoObject.attachedAnimSprite`, which `AttachAnim` and
`AttachExistingAnim` fill) in `IsoObject.renderAttachedSprites`, and after drawing each it calls the instance's
`IsoSpriteInstance.update()`, which does nothing. A fire steps its own in `IsoFire.update`, and a character steps its sprite
with `IsoSprite.update(instance)`; an ordinary object's attached animation stays on its frame unless a mod steps it from Lua
every tick. With `anim.stepKey` declared, an object whose mod data holds a number other than 0 under one of the keys has each
of its attached animations stepped right after that call, by the game's own `IsoSprite.update(instance)` of the instance's
sprite: the frame moves by the instance's speed (`setFrameSpeedPerFrame`) times the game time since the last update, a
looping animation starts again after its last frame, and nothing moves while the game is paused. A mod sets the number to
start the animation and 0 to stop it, where it is (`PZExtAPI.formulas.set(handle, "anim.stepKey", "spinStep")`, then
`object:getModData().spinStep = 1`).

Stepping alone is not enough with the chunk renderer (`PerformanceSettings.fboRenderChunk`, Build 42's default): it draws an
ordinary object, its attached animations with it, into the chunk level's texture, and draws it again only when that level is
invalidated (`FBORenderLevels.invalidateLevel`), so `renderAttachedSprites` runs now and then, not every frame. The renderer
sorts each object into a layer as it redraws the level (`FBORenderCell.calculateObjectRenderLayer`), and an object in the
`Translucent` layer is drawn every frame (`renderTranslucent`): a fire, and an object for which `IsoObject.isAnimating()` is true,
which the game sets while a door's model animation plays. The API answers yes to `isAnimating()` for an object that has
attached animations and holds a number other than 0 under a key, so the renderer draws it every frame and the step runs with
each draw. (The chunk renderer's other per-frame path, `renderAnimatedAttachments`, draws only clock hands and a light's
overlay, not attached animations.)

- **When it takes effect.** The renderer asks `isAnimating()` as it redraws the object's chunk level. Attaching or removing an
  animation on the game's thread redraws it (`addAttachedAnimSpriteInstance`, `RemoveAttachedAnims`: `DIRTY_OBJECT_MODIFY`),
  so a mod that sets the key just after attaching, in the same tick, has the object drawn every frame from the next frame; one
  that sets or clears the key alone, or declares the point after the object was drawn, calls
  `object:invalidateRenderChunkLevel(256)` after. An object whose key was cleared is no longer stepped at once, and leaves
  the per-frame layer at the level's next redraw.
- **A wall.** An object standing on a south or east wall is sorted before `isAnimating()` is asked (`MinusFloorSE`), and stays
  in the level's texture: stepped only as it is redrawn.
- **What else sees it.** `isAnimating()` is read by the chunk renderer alone in the game (and PZ Optimize's), and by a Lua mod
  that asks; such a mod sees true for a stepped object.

- **Once a frame.** The game may draw an object more than once a frame (once for each player's screen), so the API keeps
  the instances it stepped since the frame job last ran (at the start of `GameWindow.logic()`) in an identity table that the
  frame empties. The table grows to the most instances stepped in a frame, its only allocation. Only the thread the frame job
  runs on, the game's, steps.
- **Threads.** `isAnimating()` is asked on whatever thread bakes a chunk level (PZ Optimization records a level's objects
  on worker threads), and the API's answer only reads the object's mod data: it keeps and changes nothing, so it is safe from any
  thread. The mod data is a Lua table that Lua on the game's thread may write at the same time; a read that races such a write
  answers with the value from before or after (never a changed table), and an object whose answer was missed is drawn into the
  chunk's texture until the level is baked again, as the game does. The stepping itself is the game's thread's alone: a draw on
  another thread steps nothing.
- **Only while drawn.** An object the game does not draw (off the screen) is not stepped; its animation goes on from where
  it was.
- **No table made.** The mod data is read only for an object that has it (`hasModData`). A string, a NaN, 0 or no key leave
  the object as in vanilla.
- **Not looping.** An animation attached not to loop stops on its last frame, as the game's update has it; one attached to
  be deleted when it finishes (`AttachExistingAnim`'s `deleteWhenFinished`) has its sprite disposed by that update, so a mod
  attaches a looping one or one that is kept.
- **Faults.** A step that throws is reported once in the game's log and leaves that draw as in vanilla; the next draws try
  again.

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

The player and the zombie are bodies, not points: each has its middle and its two sides across the line between them, a quarter
square to each side. The cone takes the zombie's middle or either side. The line is drawn middle to middle, and when that is
blocked side to side (left to left, right to right, crossed, and the player's middle to each of the zombie's sides), so that a
zombie half behind a door frame or a wall's end, or one the player sees past a corner it stands at, is found by the sides that
show. A side is used only when nothing the game blocks vision at stands between it and its body's middle. The fix writes to
the game's log only when it turns on or off; what it decides each frame is not logged (the 10 s report that found the alpha
staying at 0 was taken out once the fix was seen to work).

For such a zombie it draws a line from the player, and when nothing blocks the line it sets `setTargetAlpha(player, 1)` on
that frame and each frame after it, once the rest of the game's test of a zombie it finds in sight is passed (below; the game
sets it back to 0 when it updates), and brings the alpha itself up: `setAlpha(player, min(1, alpha + frame / 0.3 s))`, the
frame counted at most 0.1 s, so a zombie shown comes up from unseen in 0.3 s. The game's own fade does not bring it up: in the
game with PZ Optimize the log showed shown zombies with the alpha 0 frame after frame, the alpha they fade to back at 0 by the
time it fades, though the update order (`updateAlpha` before `updateSeenVisibility`, the frame job at the start of `logic()`)
is the game's. Once the fix no longer shows it, the game fades it out as its own. Only the alphas are changed.
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
unseen, unless night sight lifts the dark: while `vision.nightSight` lifts the squares by f, each colour of the light the test
reads (the zombie's square's and the player's own) is lifted as the squares' are, `c + f (1 - c)^2`, so that a zombie in a room
the player sees lifted is seen in it. The same pass runs then though no mod declares the fix: a zombie the game does not draw is
in sight when the game finds its square so (`ILighting.bCanSee`, which a square in the dark has), not by a line of the API's,
and is shown when the lifted light passes the test. Nothing is done while the player is asleep, dead, in a
vehicle (the cone then is the vehicle's) or sees everyone (a cheat that has it done). While no mod declares the fix and night
sight does not lift, nothing runs, and the game is not touched.

A fault stops this part alone, once, with a line in the game's log: the point then reads `unavailable: stopped: ...`, the other
points go on and the game draws as it did. A game that lacks a member the fix reads makes the point read `unavailable: ...`
from the start.

### Hook sites

The hooks are found by the signature of the method and the shape of its call sites, never by position or hash: every
return of a method (or the one place a value is read) is hooked, and a method that is not shaped as expected loses its own
hook only. `PZExtAPI.hooks()` names each by game class and method.

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
| `InventoryItem.*`, `DrainableComboItem.*` (labelled `:useDelta`) | each read of the class's own `useDelta` field | The value read is divided by the item's `uses.modDataKey` numbers. The two classes each have a field of that name; the drainable's shadows the item's. |
| `CraftRecipeData.luaCallOnCreate(IsoGameCharacter)` | the start | The items made take the used items' `craft.carryKeys`, before the recipe's `OnCreate` reads them. |
| `InventoryItem.getName(IsoPlayer)`, `getDisplayName()`; `Food`, `Clothing`, `Moveable` `getName(IsoPlayer)` | each read of the item's `name` field | The name read passes through `item.nameKey`. `getName()` asks `getName(null)`; the kinds that dress a name override the one with the player. |
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
| `IsoTree.isPlayerInsideARoom(IsoPlayer)` | the one `IsoPlayer.isInARoom()` call | A fix, for every mod and none: the answer is "in a room" only when the player's square has a room too, so a room the game made no building of (one on a map building's roof) no longer throws for each tree drawn near it. |
| `GameSoundClip.getEffectiveVolume`, `getEffectiveVolumeInMenu` | each return | A fix, for every mod and none: the game's volume settings turn its sounds down through FMOD's mixer (its VCAs), which a sound script's `file` clip does not go through, so a mod's own sounds played at full volume with the settings at 0. A clip with a file and no event is times its sound's master's volume as the sound manager has it (`getSoundVolume`, `getAmbientVolume`, `getMusicVolume`, `getVehicleEngineVolume`: the option, or what turns it down for a while), read each time the game sets the channel's volume; an event's clip is left to the mixer. |
| `BREBuilding()` (the building editor's building) | the one `new BuildingDef(boolean)` | A fix: the building is a map building (`false`), not one players built, so the game does not drop it when players build in its cell, while rooms are being set and while the game loads the API's file; else the game's answer (see "Rooms set"). |
| `PlayerRoomsFile.load()` | the one `ZomboidFileSystem.getFileInCurrentSave(String)` | The file read is the save's `pzext_rooms.bin` when there is one (the rooms `setRooms` gave), else the game's `player_buildings.bin` (see "Rooms set"). |
| `BuildingRoomsEditor.load()` (`BuildingRoomsEditor.load`) | before each return | The editor's load of the world's rooms is done: its buildings are the game's again. |
| `BuildingRoomsEditor.updateSquares()` (`:squares`) | before each of the two `forEachSquare(Consumer)` | While rooms are set, the pass is given the building's squares by the API and the game's pass over every loaded square is left out (see "Rooms set"); else the game's. |
| `BuildingRoomsEditor.applyChanges(boolean)` (`:numbers`) | the one `recalculateBuildingAndRoomIDs()` | While rooms are set, the API has the editor number the cells the building is in, one at a time, in place of every cell of the map; else the game's. |
| `BuildingRoomsEditor.applyChanges(boolean)` (`:check`) | each of the three `checkBuildingAndRoomIDs()` | Left out while rooms are set (a check of every cell's numbers that only logs); else the game's. |
| `LightingJNI.buildingsChanged()` | the return | The API is told the buildings changed: rooms set (the chunks of the building, with a chunk around them, are kept) or the game's own (every chunk). |
| `LightingJNI.checkChangedBuildings()` (`:chunks`, `:done`) | after the one `IsoChunkMap.getChunk(int, int)`; the return | A chunk that is not one the buildings changed in is passed over as an empty place is (see "Rooms set"); at the end, what was kept is let go once the pass went through the chunks. |
| `IsoMetaGrid.savePart(buffer, part, flag)` (`savePart:saving`) | at its start | The world is saving its map data: for part 0 (the rooms), the API's file of the rooms is written. |
| `IsoMetaGrid.savePart` (`savePart:rooms`, `savePart:entries`) | the one `IsoMetaCell.getRoomCount(true)`, and the one `getBuildingCount(true)` | The count of a cell's rooms is the game's and the number of entries for the map's own rooms that were replaced; those entries are written after the cell's own. The two go in together or not at all (one alone would break the file), which the API checks. |
| `IsoMetaGrid.load(buffer)` (`load:complaint`) | the game's complaint of a room entry it has no room for (`DebugType.error`, the one that begins `invalid room metaID`) | Left out when the entry is one of the replaced rooms'. |
| `IsoObject.couldBePoweredByGenerator` | each return | True for an object of a sprite declared in `machine.baseConsumption` above 0, besides the game's answer. |
| `IsoObject.getGeneratorPowerConsumption` | each return | An object of a declared sprite gives its declared consumption times the load its mod data holds under `machine.loadKey`, in place of the game's. |
| `IsoObject.renderAttachedSprites` | after the one call of `IsoSpriteInstance.update()` (the method is private; it is found by its signature) | The instance just drawn and the object go to `anim.stepKey`'s step; the game's own call stays. Another number of such calls makes the hook not go in. |
| `IsoObject.isAnimating` | each return | True also for an object with attached animations that holds a key of `anim.stepKey`, so that the chunk renderer draws it every frame. |
| `IsoPlayer.calculateInTreesSpeed` | each return | The speed scale of the animation of walking through trees, passed through `move.treeSlowMultiplier`. |
| `IsoGameCharacter.damageWhileInTrees` | the start | Returns at once, with the chance `move.treeScratchChance` leaves out. |
| `IsoGameCharacter.addHole(BloodBodyPartType, boolean)` | the start | Returns false at once, with the chance `body.holeChance` leaves out. The one-argument `addHole` and `addHoleFromZombieAttacks` call it. |
| `BodyPart.generateZombieInfection(int)` | the start | Returns at once, with the chance `infection.woundChance` leaves out (read from the part's `parentChar`). |
| `BodyDamage.AddRandomDamageFromZombie` | just before and just after the call of `SetBitten(index, true)` | The bite shield's two moments (see `infection.biteShield`). There is one such call and the index is a local variable, or the hook does not go in. `BodyPart.SetBitten`, which a save loading a part calls too, is not hooked. |
| `Thermoregulator.getCatchAColdDelta` | each return | Times `body.coldMultiplier` (the thermoregulator's `player` field). |
| `CorpseCount.getCorpseCount(IsoGameCharacter)` | each return | Times `body.corpseCountMultiplier`, rounded. |
| `BodyDamage.GetBaseCorpseSickness` | each return | Times `body.corpseSicknessMultiplier` (the body's `parentChar`). |
| `IsoGameCharacter.DoLand(float)` | the start | Replaces the speed, the method's own argument, by what `fall.heightMultiplier` and `fall.landingRemap` make of it. |
| `IsoGameCharacter.handleLandingImpact` (labelled `:impact`) | the call of `FallDamage.getImpactIsoSpeed()` | The speed read passes through `fall.impactMultiplier`. The same method as the load's `:overload` hooks; two hooks, one class owner. |
| `ItemPickerJava.getActualSpawnChance` | each return | Times `loot.spawnMultiplier`. |
| `ItemPickerJava.getLootModifierFromType` | the read of `ammoLootModifier` | Times `loot.ammoMultiplier`; the only read of that field in the method. |
| `SelectorBucket(int[], SelectorBucketScript, SelectorBucket[], Randomizer)` (`SelectorBucket.<init>:children`) | the one write of `children` | A fix: the game makes a bucket of an item's config with no buckets under it with none (null) and reads their number as it resolves every bucket it reaches, so every config failed on every item the loot gave it; such a bucket gets an empty list. |
| `LightingJNI.getLumaInverted` | each return | Passed through `vision.darknessRestore` (the method is private; it is found by its signature). |
| `LightingJNI.calculateVisionCone` | before the call of `getWornItemsVisionMultiplier()` | The degrees on the stack have `vision.coneAdd` added before the worn items' multiplier. |
| `LightingJNI$JNILighting.update:stale`, `.updateFBORenderChunk:stale` | after each call of `LightingJNI.getSquareDirty(player, x, y, z)` | Also true when night sight's lift changed since the square was read (or it has not been read since squares were lifted), so that it is read again; the call's arguments are kept in new locals. |
| `LightingJNI$JNILighting.update`, `.updateFBORenderChunk` | after each call of `LightingJNI.getSquareLighting(player, x, y, z, int[])` | The corner lights it handed (from index 5, the 8 colours the floors, walls and models of the square are drawn with) are lifted by night sight for a local player (not a square the player has never seen), before the game reads them; the call's arguments are kept in new locals. Both reads, the chunk renderer's and the other, are hooked, so the game's own check for a changed square sees the lifted corners. |
| `FBORenderCell.sanitizeLightInfo` | each return | The light a square's objects are drawn with: a lifted copy (the square's own, which the game also asks for its zombies and its vision, is never changed). |
| `FBORenderCell.*:stale` | after each call of `LightingJNI.getChunkDirty(player, wx, wy, z)`, in any method | Also true while a square of the chunk level was last read with another lift, so that the renderer reads the level's squares again (given up for 3 s once the squares are not drawn); the call's arguments are kept in new locals. |
| `FBORenderCell.renderOneLevel_Blood:blood` | after each call of `IsoGridSquare.getVertLight(corner, player)` | The corner light floor blood is tinted with, unlifted, so that blood is not lit by night sight. |
| `FBORenderCell` (every method that calls it: `renderOneLevel`, and PZ Optimization's `pzoptBakeSnow`; `*:decals`) | before each call of `FBORenderSnow.RenderSnow(chunk, level)` | The [floor decals](#floor-decals) of the chunk level's floors are drawn over all of them, into the chunk level's picture. |
| `IsoGridSquare.RecalcProperties()` | the return | The square, if a mod [watches](#square-watches) it, is marked to be told at the next frame. |
| `ModelInstance$PlayerData.updateLights` (two), `ModelSlotRenderData.initModel:light`, `ItemModelRenderer.init`, `FBORenderCorpses$BodyParams.initAmbient` | after each call of `IsoGridSquare.interpolateLight(info, x, y)`, or of PZ Optimization's `ModelInstance.pzoptInterpolateLight(square, info, x, y)` (its copy of `ModelInstance$PlayerData`, which the game loads before its own, reads the light with that) | A character's, an animal's, a vehicle's, an item's and a corpse's light, worked out again from the corners before night sight's lift (see [night sight](#night-sight)); the call's arguments are kept in new locals. |
| `IsoObjectModelDrawer.renderMain:still`, `:animated` | the start | A model object's light: the square's own when it is the lifted copy `sanitizeLightInfo` handed. |
| `pzopt/BloodDecals.squares` (PZ Optimization's blood, when installed) | after its `SquareRules.fill` | The same for the colours of the squares it hands the GPU. |
| `ShaderUnit.loadShaderFile` | each return | The sources of the shaders that draw the world (the tiles, the walls cut away for the player, the models) get night sight's step, once; a source without the place it goes is left as it is. See [night sight](#night-sight). |
| `ShaderUnit.compile` | after the one call of `GL20.glCompileShader(shader)` | A shader with the step that did not compile is compiled again without it. See [night sight](#night-sight). |
| `ShaderUnit.compile:source` | before the one call of `GL20.glShaderSource(shader, source)`, with the unit's `fileName` | The source the GL is handed, which PZ Optimization's patches have changed since the load: the tiles' composite its pixel light makes gets night sight's step in its own place. See [night sight](#night-sight). |
| `PixelLight$Gl.init:pass` | before PZ Optimization's one call of `AmbientOcclusion.link(vertex, fragment)` (only with PZ Optimization) | The fragment source of its pixel light's pass (`pplMode=pass`): night sight's lift goes in. See [night sight](#night-sight). |
| `AmbientOcclusion.compile` | after PZ Optimization's one call of `GL20.glCompileShader(shader)` (only with PZ Optimization) | A shader with the lift that did not compile is compiled again without it, as `ShaderUnit.compile` does. |
| `TileDepthShader.startRenderThread`, `CutawayAttachedShader.startRenderThread`, `TileSeamShader.startRenderThread`, `IsoGridSquare$CutawayNoDepthShader.startRenderThread`, `Shader.startRenderThread` | each return | With the shader's program bound: night sight's lift is set into every linked program that has its uniform, when the lift or the number of sources with the step changed since it was last set. |
| `Shader.Start` (the core `Shader`, labelled `:bind`; and the models' `skinnedmodel.shader.Shader`) | each return | The same, where a shader is bound without a draw (`IndieGL.bindShader`). |
| `Helicopter.writes:flight` | after every store of `Helicopter.state` or `Helicopter.active` (outside the constructors) | Counts the store; see [What the frame job learns from the hooks](#what-the-frame-job-learns-from-the-hooks). |
| `IsoWorld.writes:currentCell` | after every store of `IsoWorld.currentCell` (`init`, `KillCell`; outside the constructors) | Counts the store; the same. |
| `ParameterZombieState.setState` | before the store of the new state, which comes after the game's early return for the same state | The new state (from the stack), the zombie and the old state (the parameter's `zombie` and `state`, which the hook reads; a class without them, or with another number of stores of `state` in the method than one, loses the hook) go to the [zombie sounds](#zombie-sounds) while a mod listens. |
| `ZombieVocalsManager$Slot.playSound` | before the one call of `BaseCharacterSoundEmitter.playVocals` | The zombie's voice starts: the zombie (the method's argument; a method that stores over it loses the hook) goes to the zombie sounds. |
| `IsoZombie.handleLandingImpact` | the start | A zombie lands from a fall (the zombie's own method, which `DoLand` calls for a landing it counts as a fall): to the zombie sounds. |
| `ZombieIdleState.execute` | the one call of `IsoZombie.pathToLocation(III)` | The square an idle zombie wanders to, through the [zombie holds](#zombie-marks-and-holds). |
| `WorldSoundManager.getBiggestSoundZomb` | after the one `List.get` of its sounds | A sound a held zombie must not hear becomes null, which the method skips. |
| `ZombiePopulationManager.removeChunkFromWorld` | each of the two `n_addZombie` calls (the zombie is the local just cast to `IsoZombie`) | A zombie of a dissolving hold is released (`releaseZombie`) instead of kept virtual. |
| `ZombiePopulationManager.virtualizeZombie` | the start | A zombie that walks out of the loaded area (`IsoMovingObject.postupdate`) is made virtual where it stands: one of a dissolving hold leaves the world instead (`removeFromWorld`, which lets the population release it) and the method returns. |
| `ZombiePopulationManager.registerZombie` | the start | A zombie comes into the world with its persistent number (a virtual one with the number it had): the world's marks of that number go back into its modData. |
| `ZombiePopulationManager.releaseZombie` | the start | The population lets the zombie go; a dead one (the game releases it on its next update, before the corpse, and takes its number away after): its marks go from the world's table. |
| `IsoZombie.removeFromWorld` | the start | The zombie leaves the world (dead, virtual or let go): its marks leave its modData (the object is kept for another zombie). |
| `IsoZombie.Hit` | after the one call of `IsoGameCharacter.Hit` (the weapon, the wielder, the damage multiplier) that its method makes, whose float result is the damage dealt | A hit the zombie takes: the damage and the arguments (a method that stores over them loses the hook) go to the [zombie hits](#zombie-hits). |
| `FBORenderObjectOutline.renderObject` | the start | An outlined object drawn as a model (a door, built furniture) gets the game's model outline and the method returns; any other object goes on to the game's sprite outline: see [outlines](#outlines). |
| `ModelSlotRenderData.initModel:outline` | each return, for a `BaseVehicle` | The vehicle's `characterOutline`, `outlineColor` and `outlineBehindPlayer` are filled from its outline, as the method fills a character's: the same. |
| `ModelSlotRenderData.renderVehicle` | the start, when `characterOutline` is on and the vehicle is drawn to the screen (not `renderToTexture`) | The vehicle's models are drawn into the game's outline buffer, as `performRenderCharacterOutline` draws a character's: the same. |

#### Night sight

Night sight has two parts, both on the screen alone: a lift in the light each square is drawn with, and a step in the
shaders that draw the world, which undoes the lift and draws what it added in grey. All of it is in the light each
vertex carries and the pixel's own colour: nothing is read across squares or from the screen, so walls, corners and
rooms are each drawn from their own light, and nothing reads across a wall.

- **The lift.** The game's lighting is native; it hands each square's light into an `int[]`
  (`LightingJNI.getSquareLighting`: the visibility, the light, two darknesses, the level, then 8 corner colours packed
  `0xAABBGGRR`, 4 for the floor and 4 at the top of the walls), and the game draws the square's floor, walls and models
  with the corners and bakes them into its chunk textures. A corner the squares around it share is still a copy in each
  of them; the bridge lifts a square's own copies, never a neighbour's. Right after each such call each corner colour c
  (0 to 1) becomes `c + f (1 - c)^2` for a local player, f the lift (`nightSight.floor` x the value, of the full light,
  at most 0.45): the dark is lifted to f, the light is all but left as it is, and by day the game's light leaves little
  to lift. The light a square's objects are drawn with (`FBORenderCell.sanitizeLightInfo`) gets a lifted copy. A square
  the player has never seen (the visibility's `bSeen` bit off: an unexplored room, which the game draws black) is left as
  it is, and so is its objects' light: night sight shows nothing the game hides. The square's own light (`lightInfo`),
  which the zombies (`spotted`, `TestIfSeen`), reading and the darkness the vision cone reads ask, is the game's: the
  native lighting gives a room light only through its openings (measured: a sealed basement room reads 0 at night), and
  with night sight it is still 0 for everything but the screen.
- **Reading again.** The game reads a square's lighting again only when the native lighting says it changed
  (`getSquareDirty`, which does not know of the lift), and bakes it again when the corners it reads change. So each
  square keeps the lift it was read with (in a table for each player and floor, by x and y modulo 256), and
  `getSquareDirty`'s answer is followed by whether it was read with another, or not read since squares were lifted: a
  new lift (a rank changed, or night sight declared or cleared) has each square read again as the game next asks for it.
  The table is the game's, not the API's: a Lua reload makes a new API, which reads again the squares the last one
  lifted. The renderer goes to a chunk level's squares at all only when `LightingJNI.getChunkDirty` says the level
  changed (the game's own renderer too; PZ Optimization asks in more methods), so each of its answers, wherever asked,
  is followed by whether a square of the level was last read with another lift. A level still asked after 3 s has
  squares the renderer does not draw: those are let go, and read again when the native lighting next says they changed.
- **The step.** The game loads each shader's source through `ShaderUnit.loadShaderFile`; the sources of the shaders that
  draw the world get the uniform `PZExt_NightFloor` (f) and the step before `main`, and the colour goes through it where it
  is lit:
  - the tiles: the game's `tileWithDepth`, `opaqueWithDepth`, `CutawayAttached` and `seamFix2`, and PZ Optimization's
    from them (`pzopt_sfTile`, `pzopt_sfOpaque`), after `c.rgb *= col.a;`;
  - the walls cut away for the player: `CutawayNoDepth` and `CircleStencil` (the rim of a lowered wall) after the wall's
    shade, `wallTile` and `floorTile` after the vertex colour;
  - the models, whose light the game works out from the squares': `basicEffect` (characters, items), its instanced
    form, `animalEffect`, `door`, PZ Optimization's horde shaders (`pzopt_horde`, `pzopt_hordeu`), the vehicles (with PZ
    Optimization's glass ones) and their wheels, where the light and the tint are put on (a vehicle's own lights after it,
    which keep their colour).

  From the light a pixel is drawn with (the corners', blended across the square by the GPU as the game's own) the step
  works out the light before the lift (`o = 1 - (1 - sqrt(1 - 4f (1 - l))) / 2f`, exact for f below 0.5), keeps the
  colour of what that light gives (`c x o / l`) and draws the rest in a cold grey of the same brightness (tinted
  0.92, 1, 1.18). A model is drawn with its own light as the game has it, and the lift a floor of that light would take
  (`f (1 - l)^2`) is added in grey: the game's light alone gives it colour. At no lift the colour is as it was. A source
  without the place the step goes (a newer game) is loaded as it is, and what it draws keeps its colour.
  The shaders load before any mod can declare a lift, so the step is put in every source whatever the declarations are;
  it does nothing until the uniform is above 0 (the colour is exactly the game's), and the uniform is 0 until a mod declares.
  A source that does not compile with the step (another tool changed it, or a game update did) is compiled again with the step
  taken out, wherever it is in the source the GL holds (the step is marked), and says so once in the log; every shader costs one
  query of the compile status (`ShaderUnit.compile`), which the game's own log query right after has already waited for. The
  shader then draws as the game's. `formulas.nightSight()` says how many sources did not compile with the step.
- **PZ Optimization's pixel light.** With its option `pixelLight` PZ Optimization bakes the world's tiles unlit into the chunk
  textures (the squares read white while a chunk is baked) and lights each pixel of the chunk's composite instead: its
  `pplLight` blends a light texture it packs per square from `lightInfo`, the square's own light, which night sight leaves as
  the game has it, and not from the corners the lift is in. So the tile shaders' step sees white and the composite draws the
  dark: tiles stayed black under night sight while the models, lit from the corners, were lifted. Its source is made in
  `ShaderUnit.compile` (its patches run between the load and the GL), so the step goes in at the GL call
  (`ShaderUnit.compile:source`), in any source that defines `pplLight`, whatever its file (`chunkShader.frag` made by the
  patch, `pzopt_chunkBase.frag`, the variants made from them), in three places that change none of the source around them:
  the uniform, the step and a macro that has the game's light function called `pztLight0`, before it; after it, a function of
  its name that lifts the light it returns as the corners are (`l + f (1 - l)^2`, each colour) and keeps it; and, before the
  composite makes its colour (`fragColor = c * col;`), the same step as the tiles' on what the light made (`pztNight` with the
  lifted light), so that the lift is drawn in grey and the light the square has keeps its colour, as without the pixel light.
  A square the player has never seen is not lifted: the light function ends with the composite's own visibility of the square
  (what its `PPL_UNSEEN_AMBIENT` reads), taken only while the lift is above 0. A source without all three places is left as
  it is, one with the uniform already is not changed again, and the fallback above takes the step out of one that does not
  compile. Nothing is done without PZ Optimization's pixel light: no source defines `pplLight`, and with the option off its
  composite is the game's. PZ Optimization's `pplMode` `pass` (the default, `composite`, is the one above) draws the
  light in a pass of its own, a program it links from its own source without `ShaderUnit`, and multiplies what is drawn by
  it (its blending). The pass's source gets the light function's macro, the state and the lifting wrapper as it is linked
  (`PixelLight$Gl.init:pass`; its compile falls back as the game's do, `AmbientOcclusion.compile`): the tiles come up from
  the dark with the models, but in their own colour, since a factor cannot take a colour to grey.
- **The models' light.** The game lights a model from the square's corners (`IsoGridSquare.interpolateLight`) and makes
  more light of that: a character's ambient colour (0.45 of it, in `Shader.startCharacter`) and two lights beside the
  character made from it (1.7 / 4 of it each, with a direction), a model object's the same way (1.5 / 4). A shader sees
  only the sum, and cannot take the lift back out of it: a character in a sealed room at night kept colour from the lights
  beside it. So the lift never reaches a model's light: each read of it is worked out again from the corners as they were
  before the lift they were read with (for a character, animal, vehicle, item or corpse), and a model object (a door,
  furniture) is drawn with the square's own light instead of its objects' lifted copy. The sprites drawn with the same
  light (a zombie far off drawn from its picture, curtains, a mannequin) are tiles to the step and keep the lift.
- **The uniform.** PZ Optimization draws the world's tiles with programs of its own, which the game binds without its
  hooks. So when the lift changes, or a source with the step is loaded, the bridge sets `PZExt_NightFloor` into every
  linked program that has it (program ids from 1 to 4096, or twice the highest met), the program that was bound bound
  again after; the check runs on the render thread where the game binds a shader (`startRenderThread` of the tile and
  cutaway shaders, the core `Shader`'s, and `Start` of the core and the models' `Shader`) and costs a compare otherwise.

The lift is one number for the machine: split-screen players share it.

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
| Any hook above that is missing (`PZExtAPI.hooks()`) | A class another mod rewrote | `Hooks.weightTracked()` is false and the game's own `getInventoryWeight` answers: the API does not keep an account it cannot follow |

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
that the game already draws is not changed; the alpha it fades to is set on every frame, and the alpha comes up on the first; a second at 60 frames draws 10 to 17 lines for a
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
zombie is drawn now that the alpha itself is brought up, a zombie seen across a stair or an opening in the floor, the cost with a real
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

The attached animations' two hooks were put into the real bytes of `IsoObject` (the jar's and PZ Optimize's loose class, each
with one call of `IsoSpriteInstance.update()`, right after `IsoSprite.render`) and both classes passed the class-file verifier.
`isAnimating()` is read in the jar only by `FBORenderCell.isObjectRenderLayer_MinusFloor` and `_Translucent`, and in PZ Optimize's
loose `FBORenderCell` by the same two and its count of translucent objects; neither renderer draws attached animations on
another per-frame path. Read
from the bytes: `IsoSpriteInstance.update()` is empty; `IsoSprite.update(IsoSpriteInstance)` (the same in PZ Optimize's loose
`IsoSprite`) moves `frame` by `animFrameIncrease` times `GameTime.getMultipliedSecondsSinceLastUpdate()` times 60 unless
`GameTime.isGamePaused()`, and loops it; `AttachExistingAnim` sets the sprite's `animate` (more than one frame), `loop` and
`deleteWhenFinished`, and a new instance is `looped`. In the synthetic game: nothing is stepped with nothing declared, nor an
object without a key, which is given no data table; an object holding a key, drawn three times in a frame, is stepped once
at its own speed with the game's call made each time, once again in the next frame, loops, and is not stepped in a frame it
is not drawn; 0, a string, a NaN and a key taken out leave it, a negative number steps it; two mods' keys join; a sprite whose
step throws is reported once in the log while the game's calls are made and the other objects step; `clear` gives vanilla
back; `isAnimating()` is true for an object with attached animations and a key, and false with nothing declared, without a
key or with 0, a string or a NaN under it, for an object with a key and no attached animation, and after `clear`, while the
game's own true stays; 100 frames of 1000 draws of two stepped objects (and their `isAnimating()`) allocated 792 bytes (the
measurement's own). A draw cost 7.8 ns with nothing declared, 18.3 ns declared but without the key and 37.8 ns with it (the
synthetic draw included).

In the game (10 October 2026, the chunk renderer on, PZ Optimize installed), with only the step hook: a lure (an
`IsoThumpable` with one attached animation of 6 frames at 0.08 a frame, the key held) stood on one frame for seconds and moved
a step now and then, as its chunk level happened to be redrawn. Invalidating the level each tick from Lua
(`invalidateRenderChunkLevel(256)`) stepped it about once a tick; so did `setAnimating(true)` with one invalidation: 2.56 frames in
30 ticks, one step each. Not tried in the game yet: the `isAnimating` hook itself, and a split screen.

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

One event, `OnPZExtHelicopter(state, target, x, y)`, raised through `LuaEventManager` when the state changes: `"Arriving"` as the
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
a few reflective reads more. `PZExtAPI.hooks()` (and the `api.tsv` in the install folder) says which it is for each area: `Helicopter.events`
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
allocates nothing. The list is bounded: the `limit` nearest are kept as it goes. Other levels are other calls, or one call
with `options.levels`.

`zombies.near(x, y, z, radius, limit, options)` takes a sixth argument, a table that narrows the zombies and adds what the game says
of each. Without it the call is the one above, unchanged (the zombies in the list carry only `zombie`, `x`, `y`, `z`, `distance`).

| Option | Meaning |
| --- | --- |
| `levels` | A list of 1 to 16 whole numbers: zombies on any of those levels (a zombie's level is the floor of its `z`). `z` is then not needed and may be `nil`. |
| `seenBy` | A player of this machine (as `getPlayer()` gives it). Each zombie in the list then has `seen`: whether the game shows it to that player (the visibility the game keeps for each local player, which a mod cannot read quickly from Lua). |
| `seen` | `true` or `false`, with `seenBy`: only the zombies the player sees, or does not see. |
| `targeting` | A character: only the zombies whose target is it. |
| `hunting` | `true`: only zombies with a target; `false`: only those without. |
| `crawling` | `true` or `false`: only crawling zombies, or only those that are not. |
| `state` | The name of one of the game's zombie states (a class of `zombie.ai.states`, with or without `State`: `"LungeState"` or `"Lunge"`), or a list of up to 16: only zombies in one of them. A name that is none is an error. |
| `into` | A table to put the list in, whose entries are used again, so a call every frame makes no table. |

With any option, each zombie in the list also has `state` (the name of its state's class, or nil), `crawling` and `hunting`
(booleans), and with `seenBy`, `seen`. The count is of the zombies that match every option. The filters read the game's fields
through the same handles as the position, so a zombie that fails one costs a few nanoseconds more and allocates nothing.

### Zombie sounds

For a mod that shows where a zombie was heard, for a while, instead of following the zombies (a "presence sense", a direction
indicator): the moments a zombie makes a sound that the game hands to FMOD alone and never tells Lua of. A zombie's thumps on a
door or a window and the breaking of one already reach Lua as `OnWorldSound`, and are not repeated here. Footsteps are not
hooked: every zombie makes them all the time, and an event for each would be following the zombies.

| Call | Effect |
| --- | --- |
| `zombies.listen(handle, radius)` | The mod (its handle from `PZExtAPI.client`) listens for the sounds of zombies within `radius` squares (0 to 1000) of a local player, across the ground; 0 or nil stops it, as `handle:clear()` does. Returns the radius in effect: the largest any mod listens with. |

One event, `OnPZExtZombieSound(kind, x, y, z, loudness, zombie)`, raised through `LuaEventManager` on the game's thread at the
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

### Zombie hits

For a mod that reacts to a wound a zombie takes (counts it, shows it, scores it) instead of following the zombies. The game raises
`OnHitZombie` for the weapon hits of its own Lua, with the arguments of the swing; this event comes from the zombie's own `Hit`, so
it covers every hit that reaches the zombie and carries what the game dealt.

| Call | Effect |
| --- | --- |
| `zombies.watchHits(handle, on)` | The mod (its handle from `PZExtAPI.client`) watches hits with `on` true; false or nil stops it, as `handle:clear()` does. Returns whether any mod watches. |

One event, `OnPZExtZombieHit(zombie, attacker, weapon, part, damage, killed)`, raised through `LuaEventManager` on the game's
thread at the start of a frame after the hit: the zombie (`IsoZombie`), the attacker (`IsoGameCharacter`, or nil), the weapon as
the game passed it (`HandWeapon`; nil for a hit with none), the name of the body part the hit was on (`zombie.lastHitPart`'s name,
such as `"Head"`, or nil), the damage the game dealt as a number, and whether the zombie was dead after it.

The hook is in `IsoZombie.Hit` after the call of `IsoGameCharacter.Hit` that works the damage out and applies it, so `damage` is
what was dealt, after the game's own reductions, and 0 for a hit that was turned away; and `killed` and `part` are as the hit left
the zombie. The hook runs on the thread that updates the zombie (see [the sounds](#zombie-sounds)), so it only notes the hit: under a
lock it writes the five values into a ring of 64 places, written over from its oldest when the frames fall behind, and the frame
job raises at most 16 events a frame, oldest first. While no mod watches, the bootstrap holds no handler and the hook is one volatile
read. Who watches belongs to the world: it is kept in the API table's metatable (a newer API takes it over; the function a mod kept
from an older one refuses to be called), and a world left drops it. A fault in the frame job stops the hits alone, once, with a line
in the game's log.

### Zombie marks and holds

For a mod that puts zombies somewhere and wants to know them again: a group to clear, a target to find. The game has no tag of its
own on a zombie: an outfit is one only while no other zombie may wear it, and the game dresses map zombies in any outfit it knows,
a mod's too (`OutfitManager.GetRandomOutfit`). A zombie's modData is the place for a mark, but the game keeps none of it while the
zombie is virtual or saved, and gives the object to the next zombie without clearing it. The marks are kept in both places so that
a marked zombie is one wherever the game takes it. Nor does the game keep a zombie in a place and still let it fight: `setUseless`
makes one that does nothing, and an idle zombie wanders off a few squares at a time, follows any sound it hears (an alarm, a siren
far away) and, once its chunk unloads, becomes a virtual zombie the population moves unseen.

| Call | Effect |
| --- | --- |
| `zombies.mark(handle, zombie, key)` | Marks a living zombie with the key (a name), replacing the mod's mark on it. A mod marks 5000 zombies at most in a world. |
| `zombies.unmark(handle, object)` | Takes the mod's mark off a zombie or a corpse. |
| `zombies.markOf(handle, object)` | The mod's key on a zombie or a corpse, or nil. |
| `zombies.marked(handle, key)` | A list of the loaded living zombies the mod marked with the key (those on a square). |
| `zombies.forget(handle, key)` | Takes the mod's marks of the key off every zombie, the virtual ones included; corpses keep theirs. |
| `zombies.hold(handle, key, { x, y, radius, margin, dissolve })` | Holds the zombies the mod marked with the key in the circle of `radius` (1 to 300) round `x`, `y`, replacing the mod's hold of that key. `margin` (0 to 300, 20 when nil) is how far beyond the circle a zombie is still held; `dissolve` true lets one go as its chunk unloads. 64 holds a mod. |
| `zombies.release(handle, key)` | Takes the hold away, as `handle:clear()` takes all of the mod's (its marks stay). |

A zombie's marks are a table of mod -> key in its modData under `PZExtMarks`; the game copies it to the corpse
(`IsoDeadBody` copies the character's modData), so a mod knows its dead too. The world's global ModData `PZExtMarks` keeps the
same table by the zombie's persistent number, the one the population keeps while the zombie is virtual and in the save. Two hooks
keep them true: a zombie that comes into the world with a number the table has (`ZombiePopulationManager.registerZombie`) gets
its marks back, and one that leaves it (`IsoZombie.removeFromWorld`, after the corpse took its copy) loses them from its object.
The table forgets a zombie as it dies (the population lets a dead zombie go, `ZombiePopulationManager.releaseZombie`, on its next
update and takes its number away, before the corpse is made), as a hold lets it go, as its last mark is taken off, and as the mod forgets its key; a zombie
the game drops in other ways (a cleanup of the population) stays in it until then, so a mod forgets a key it is done with. A
client in multiplayer has no persistent numbers: its marks are the zombie's modData alone.

A zombie marked with a held key, within the circle and its margin (on any level), is held:

- **Where it wanders:** the game sends an idle zombie to a square up to four away (`ZombieIdleState`); one outside the circle is
  brought in along the line to the centre, a square inside the edge.
- **What it hears:** of the sounds the game weighs for it (`WorldSoundManager.getBiggestSoundZomb`), it hears a player's and those
  within the circle and margin; any other is skipped as the game skips a missing one, so the loudest of the rest wins as before.
- A zombie that chased a player out past the margin is the game's until it comes back. Its fighting is never changed.

With `dissolve`, a zombie marked with the key (wherever it is) is let go as its chunk unloads, or as it walks out of the loaded
area (the game makes such a zombie virtual where it stands, `virtualizeZombie`): released from the population
(`ZombiePopulationManager.releaseZombie`) and taken off the world, instead of kept as a virtual zombie
(`removeChunkFromWorld`'s `n_addZombie`). A mod that counts its group makes it again when the player comes back; nothing of it is
left to wander unseen. A zombie the game saves with the world while its chunk is loaded comes back with the world, marks and all.

The hooks of the holds read the zombie's marks only while a hold is: with none, each returns after one volatile
read. Where a zombie wanders and what it hears are asked on whatever thread the game updates the zombie and weighs the sounds on
(PZ Optimization runs both on frame workers, while the game's thread writes marks from Lua), so they read no Lua table: a zombie's
marks are also kept as an immutable Java list (mod, key, mod, key...) in a concurrent map by zombie, replaced whole on the game's
thread each time a mark is set or taken off and as a zombie comes into the world (marks it came with included) or leaves it, rebuilt
from the loaded zombies when an API starts, and dropped with a world left. The hooks of a chunk unloading and of a zombie coming and
going change the world's table and a zombie's modData, and are asked on the game's thread only; they look the number up in a set of
the world's numbers, without boxing it, while the world has marks. The holds belong to the world: they are kept in the API table's metatable (a newer API takes them over) and a world
left drops them; the marks are the world's own data and go with it.

### Timers

A Lua function called every so many milliseconds, or so many minutes of the game's time, counted in Java, instead of a handler on
`OnTick` or `EveryOneMinute` that counts for itself and wakes every frame.
([`Timers`](../src/api/pzext/api/Timers.java))

| Call | Effect |
| --- | --- |
| `timers.every(handle, spec, fn)` | Calls `fn(id, periods)` every period, from the frame job on the game's thread; returns the timer's `id`. `spec` is `{ ms = 250 }` (1 to 86,400,000 of the interface's real time, which goes on while the game is paused) or `{ minutes = 10 }` (0.01 to 1440 minutes of the world's age, which does not), and optionally `once = true` to call it once and drop it. |
| `timers.cancel(handle, id)` | Stops the mod's own timer; `true` when there was one. |

The first call comes one period after `every`. A frame with nothing due costs one clock read and a comparison; a timer that falls
behind (a long frame, a game sped up) is called once, with `periods` saying how many periods it covers, and then goes on in step:
nothing is called in a burst. A function may make and cancel timers, its own included. A function that fails is reported once in the
game's log and called again at its next period. A mod has at most 64 timers and all mods 256. The timers belong to the world: leaving
it drops them, so a mod makes them again at `OnGameStart`. `handle:clear()` stops all of a mod's. They are kept in the API table's
metatable, where a newer API takes them over at the moment they were at.

### Chunk watches

A Lua function called when the map chunks under an area are loaded, instead of a handler of the game's `LoadChunk` event that is
called for every chunk and left to find out whether it is one it cares for.
([`ChunkWatches`](../src/api/pzext/api/ChunkWatches.java))

| Call | Effect |
| --- | --- |
| `chunks.watch(handle, area, fn, options)` | Calls `fn(id, kind, x, y)` for each chunk under `area` that is loaded, and returns the watch's `id`. `area` is `{ x, y, w, h }` in squares (`w` and `h` 1 when left out, at most 4096, covering at most 256 chunks). `kind` is `"load"` (or `"unload"`); `x` and `y` are the chunk's first square (a multiple of 8). |
| `chunks.unwatch(handle, id)` | Stops the mod's own watch; `true` when there was one. |

Options: `unload = true` also calls `fn` with `"unload"` when a chunk is let go (default false); `current = false` leaves out the chunks
that are loaded when the watch is made (default true: they are told as loads, at the next frame). A chunk is loaded when the cell finds
it and its `loaded` flag is set. The frame job looks at the watched chunks, and only those, ten times a second (one lookup each in
the game's chunk maps and a read of the flag): a watch of a hundred chunks costs a few microseconds a look, and none costs a check
of an empty list. A chunk reloaded between two looks is a new chunk: an unload (if asked) and a load. At most 64 calls are made a frame;
the rest are called in the next frames, none lost. A mod has at most 32 watches and all mods 128. Watches belong to the world and are
kept in the API table's metatable like the timers.

### Square watches

A Lua function called when what stands on a square a mod watches changes: something built on it or beside it, taken away, its
floor changed, or the square loaded. The game has no event for most of these (`OnObjectAdded` is sent only for a few objects and in
multiplayer), and looking at the squares again and again costs every tick whether anything changed or not.
([`SquareWatches`](../src/api/pzext/api/SquareWatches.java))

| Call | Effect |
| --- | --- |
| `squares.watch(handle, list, fn)` | Watches the squares of `list`, a flat list `x1, y1, z1, x2, y2, z2, ...` (at most 16384 squares; `z` from -32 to 31), and returns the watch's `id`. When one of them changes, `fn(id, x, y, z)` is called from the frame job at the next frame, once however often it changed meanwhile. |
| `squares.unwatch(handle, id)` | Stops the mod's own watch; `true` when there was one. |

What counts as a change: the game works a square's properties out again from its objects (`IsoGridSquare.RecalcProperties`), which it
does when an object is put on it or taken off (`AddTileObject`, `AddSpecialObject`, `RemoveTileObject`, `ClearTileObjects`), its floor
is put down (`addFloor`), a wall goes up or down beside it (`RecalcAllWithNeighbours` works out the neighbours too), a fire burns it,
and when it loads. A mod takes it as "look again": what changed is for it to find. A sprite changed in place without the game working
the square out again is not told.

The slot the game has for this ([`SquareDispatch`](../src/api/pzext/api/SquareDispatch.java)) is shared by the watches and by the
buildings' per-building versions (`buildings.version(x, y, z)`, which listens from its first call, marking the chunk of each square
that changes, without allocating, for the next swap of the region data to stamp): it holds the dispatch while either listens, and is
empty otherwise.

Cost: with no square watched the hook is not set and the game's call costs a null test (5 ns in the tests); with squares watched, a box
test and a hash probe in an immutable index, safe on the threads that load chunks (12 ns with 1000 watched near the squares changing).
A watched square that changes is marked once and queued under a lock only it takes. Nothing is allocated. At most 64 functions are
called a frame; the rest in the next frames, none lost. A mod has at most 32 watches, all mods 128 and 65536 squares. Watches belong
to the world and are kept in the API table's metatable like the chunk watches; a newer API takes them over.

### Drawing many shapes

For the interface that draws hundreds of rectangles or quads a frame (a ring of dashes, a graph, a grid) and would make a Lua call
for each. The shapes are in one flat table of numbers, read by the call without allocating, and drawn as the game draws them from
a window's `prerender`, `render` or `postrender`.
([`Quads`](../src/api/pzext/api/Quads.java))

| Call | Effect |
| --- | --- |
| `draw.rects(element, list, count)` | Draws `count` rectangles (as many as `list` holds when `count` is left out; at most 16,384): 8 numbers each, `x, y, w, h, r, g, b, a`, in the element's own pixels, as `drawRect` takes them (the colour parts 0 to 1). |
| `draw.quads(element, texture, list, count)` | Draws `count` quads of the texture: 12 numbers each, the four corners `x1, y1, x2, y2, x3, y3, x4, y4` in the screen's pixels and `r, g, b, a`, as `UIElement:DrawTexture` takes them. |

`element` is a window of the game's interface (or its `javaObject`). A rectangle is placed like `DrawTextureScaledColor`: at the
element's place plus its scroll, in whole pixels (cut), skipped when above the screen or below 4096 pixels; nothing is drawn for a
hidden element. The element's place is asked once for the call, not once for each rectangle. Every number is checked before
anything is drawn: a bad one (not a number, infinite, NaN) is a Lua error naming its place (`list[12] must be a number`) and no
shape is drawn. The numbers are read into a buffer kept between calls, so a call allocates nothing for the shapes.

### Floor decals

For what lies on the ground without being an object of the world: a cable or a pipe laid along the floor, a painted line. A
mod sets pictures (sprites the game knows, by name) on the floor of squares; nothing is saved, nothing can be picked up, walked
into or searched, and the game's objects are left as they are. A mod sets them again as its world loads.
([`FloorDecals`](../src/api/pzext/api/FloorDecals.java))

| Call | Effect |
| --- | --- |
| `floor.set(handle, x, y, z, list)` | The mod's decals on the square: `list` holds 5 values for each, the sprite's name and `r, g, b, a` (0 to 1), drawn in its order; at most 8. `nil` or an empty list takes the mod's decals on the square away. |
| `floor.clear(handle)` | Takes all the mod's decals away (`handle:clear()` does too). |

- **How they are drawn.** The chunk renderer draws a chunk level's floors into its picture (`FBORenderCell.renderOneLevel`) as
  the level is drawn again, not each frame: the squares of `IsoCell.SolidFloor` one after another (`renderFloor`), then the
  snow (`FBORenderSnow.RenderSnow(chunk, level)`). The hook before the snow's call draws the decals of the level's squares, over all
  the level's floors: a decal drawn just after its own square's floor was covered where it ran past the square's edge by the next
  square's floor, its grout drawn over the cable. With PZ Optimization the floors are recorded on a worker and the snow is replayed
  in order with them on the game's thread (`pzoptBakeSnow`), so the hook is at the snow's call, the one place that is on the game's
  thread in both, and takes the chunk and the level; the decals are looked up in the chunk's squares by level, not in a list the
  game keeps. Each is drawn as `renderFloor` draws a floor object: the square's floor object as the object drawn (its offsets and
  alpha), the square's light for the player times the decal's tint, with the depth test off (as for the snow that follows) and
  the depth not written (`IndieGL.glDepthMask(false)`, then `true`): the floors' depth stays, so whoever stands on a decal is
  drawn over it. So a decal lies over every floor and its overlays, under the snow, the blood, the items and everything
  standing on the floor, lit as the floor is. A square with no floor gets none. A level redrawn costs a lookup for each of its
  floor squares.
- **When they show.** A call that changes a loaded square's decals has its chunk level drawn again
  (`invalidateRenderChunkLevel(DIRTY_REDRAW)`); the same decals again change nothing. A square not loaded is drawn with them as
  its chunk loads.
- **Several mods.** Each mod's decals on a square are its own; they are drawn in the order the mods first set the square.
- **Limits.** 8 decals a mod on a square, 16,384 squares a mod, 65,536 squares for all mods. A sprite the game does not know,
  a tint outside 0 to 1 or a list that is not whole decals is a Lua error, and nothing changes.
- **The world.** The decals belong to the world they were set in; leaving it takes them away. A newer API takes them over.
- **Cost.** A floor drawn costs one test while no mod has decals (the hook is not set), and a probe of the squares' table
  otherwise; a square with decals costs a draw of each. Nothing is allocated.

### Outlines

The game's own object outline (`IsoObject.setOutlineHighlight(player, on)`, `setOutlineHighlightCol(player, r, g, b, a)`,
`setOutlineHlBlink`) is drawn on the objects the game leaves out. A mod declares `outline.models` (a boolean point of the
[formulas](#formulas-mechanism)) while it outlines such objects, and until one does the hooks are not set and the game's passes are its
own; then an object or vehicle outlined by the game, a mod or the API is drawn so, and a mod keeps using the game's calls.
([`Outlines`](../src/api/pzext/api/Outlines.java))

- **Objects drawn as models.** Most doors of Build 42, the doors players build and 3D furniture are drawn as models. The game's
  per-frame outline pass (`FBORenderObjectOutline.renderObject`) draws an outlined object's sprite silhouette and returns at once
  for a model; the model's own outline is not reached for an object baked into the chunk's picture. The hook queues the game's
  model outline (`IsoObjectModelDrawer.renderMainOutline`) where `IsoObject.renderModel` draws the model: the square's middle,
  the surface and render offsets, the render effects' shift, in the outline's colour with its alpha (the game's own model
  outline sets it to 1, which would draw a faint outline full), blinking as the game's. A double door's
  halves 2 and 3 are drawn with their partner's model (1 and 4), as `IsoDoor.renderWallTile` does. Nothing is drawn while the
  object is not shown (`ObjectRenderLayer.None`, target alpha 0) or its model animates (a door opening or shutting), as the
  game's own model drawing.
- **One colour together.** The game draws each outlined object's silhouette into one buffer and lays it over the frame
  outlined whenever the colour (or behind the player or not) changes from the object before; the pass goes through its
  objects in no set order, so the squares of one piece of furniture outlined alike showed seams wherever an object of
  another colour came between them. The hook at the start of each pass (`FBORenderObjectOutline.render(player, behind)`)
  puts its objects in order first: those outlined for the player one colour after another, a blinking one apart from a
  steady one of its colour, in the order they had otherwise. Touching objects outlined in one colour are outlined as one.
- **Vehicles.** The model renderer outlines characters alone. For a vehicle, `ModelSlotRenderData.initModel` (the main thread)
  takes the fields a character's outline uses: on or off, the colour (its alpha times `Core.blinkAlpha` when blinking), and
  whether it is behind the camera's character (`x + y` against the character's, as for a character standing). `renderVehicle`
  (the render thread) then draws the vehicle's models into `ModelOutlines`' buffer as `performRenderCharacterOutline` draws a
  character's: the game's solid shaders (`aim_outline_solid`, static and skinned) in the outline's colour, each model's own
  placing (its bones, or the identity for a static model) and its shader put back after, the depth not written; the GL state
  is put back as the game does after a character's. The game widens the outline and lays it over the frame with every other.

The outline's thickness (`setOutlineThickness`) does nothing with the render chunks (the width comes from the zoom), for these
as for the game's own. While no mod declares it, a frame costs nothing: the hooks answer as the game's code (one volatile read for
each outlined object and each vehicle drawn). Declared, a frame costs the same read for each, and a vehicle not outlined costs one more call.

### Item counts

For a menu or a tooltip that needs to know whether the character carries a tool, without a search of the inventory each time
it opens (a modded bag can hold thousands of items).
([`Inventory`](../src/api/pzext/api/Inventory.java), registered by `Formulas`)

| Call | Effect |
| --- | --- |
| `items.count(owner, name)` | How many items of `owner` (a character, its inventory, or any item container) are of the full type `name` (`Base.Paperclip`) or have the tag `name` (a registered name, `base:screwdriver`), in its bags too, at any depth. A bag that matches counts itself as well as what it holds. |

A list asked about keeps a count of every name asked about so far (at most 64), and the inventory hooks that keep the
weight ([`Tracked`](../src/boot/pzext/boot/Tracked.java)) keep it up item by item: an item
in or out changes it, a change that does not say which items (a `removeIf`, new list) has it counted again at the next
question, and so does a new name. A question when nothing changed reads one count for the list and each bag in it. Nothing
is kept for a list nobody asked about, and nothing is counted for a name nobody asked about. A name with a colon is a tag
and must be one the game has; anything else must be a full type (`Module.Name`). An item's condition is not looked at: a
broken tool counts.

### World items

For a mod whose items in the world must not be lost without it knowing: the game takes items by itself in two ways, and
neither tells Lua. ([`WorldItems`](../src/api/pzext/api/WorldItems.java), always on: nothing to
call.)

- **A fire.** A burnt object (furniture, a counter, a crate) gets its burnt sprite, and every container it has is emptied and
  taken away (`IsoGridSquare.BurnWalls`). Before each container is emptied, the event `OnPZExtContainerBurning(container,
  object)` is raised through `LuaEventManager` on the game's thread: the container (`ItemContainer`), its items still in it, and
  the object it belongs to. A mod looks into it for its own items there and then; afterwards they are gone. Items on the floor
  do not burn, and a sledgehammer, a pickup or a scrap does not empty a container (they need it empty or drop what it holds).
- **The sandbox's world item removal.** With `HoursForWorldItemRemoval` above 0, a floor item older than that is left out of
  its square as the square loads, if `WorldItemRemovalList` names it (or, with `ItemRemovalListBlacklistToggle`, if it does
  not); the game's own flag (`IsoWorldInventoryObject.isIgnoreRemoveSandbox`) keeps an item, and the game's placing of an item
  sets it, its plain drop does not. The API keeps as well an item whose mod data has the key `PZExtKeep` (any value), and a
  bag that holds one, at any depth. A mod puts the key on what must stay; nothing else is needed. The question comes in
  `IsoGridSquare.load`, on the thread that loads the chunk, only for an item the removal would take.

## Moodles (mechanism)

A mod defines a moodle of its own, and the game's moodle column draws it as it draws its own: in a slot of the column, at the
player's moodle size, on the game's background tinted by good or bad and by level, with the game's mouse-over text, coming in
and wiggling when its level changes. The mod says the level; the API holds no moodle's meaning. Mods that draw moodles of their
own today (Moodle Framework, workshop 3396446795) put UI elements of their own beside the column instead.
([`Moodles`](../src/api/pzext/api/Moodles.java))

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
`MoodlesUI.render` the column could not draw an API moodle, so none shows (its level is 0) and `PZExtAPI.hooks()` says why.
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

## Loot kinds (mechanism)

A mod defines a kind of loot of its own, and the game rolls the mod's items as it rolls its own kinds: by a modifier a sandbox
option sets. The game's kinds are fixed in its code, so a mod's items today fall into whichever of them the game's tests pick
(most into "other loot") and follow that kind's option, or the mod rolls its items itself. The API holds no kind's meaning: the
mod names its kind, its items and its option. ([`Loot`](../src/api/pzext/api/Loot.java))

### How the game does it

Read from the bytecode of Build 42.21 (`projectzomboid.jar`; PZ Optimize overrides none of these classes):

- **The chance.** `ItemPickerJava.getActualSpawnChance(item, character, container, zombieDensity, corpse)` is
  `(baseChance × 100 × modifier + zombieDensity) × getCurrentLootMultiplier(square)` (the last is the loot's decline over the
  days), and 0 at once when the modifier is 0. The modifier is `getLootModifier(itemName, corpse)`: 1 for a corpse or a forced
  roll when it is above 0.
- **The modifier.** `getLootModifier(itemName)` finds the item's script (`ScriptManager.FindItem`, also without an `Empty`
  suffix), gives 0 to an item on the sandbox's removal list, and otherwise `getLootModifierFromType(getLootType(item))`. Every
  caller in the game goes through it: the containers, corpses and vehicles (`ItemPickerJava`), the zombies' attached weapons,
  `IsoChunk` and the randomized buildings and stories; the admin panel's spawn rate checker (`LootZed/SpawnRateChecker.lua`)
  calls it from Lua.
- **The kind.** `getLootType(Item)` is a chain of tests on the script (its name, full type, tags, type and display category)
  that returns one of the game's kind names: `Generator`, `Memento`, `Medical`, `Mechanics`, ..., `Other`. Besides
  `getLootModifier`, `Item.getLootType()` and `InventoryItem.getLootType()` call it; the admin panel's item list
  (`ISItemsListTable.lua`) shows and filters by `getText("Sandbox_" .. kind .. "LootNew")`.
- **The kind's modifier.** `getLootModifierFromType(name)` compares the name with each kind's and returns a static field that
  `InitSandboxLootSettings` copied from the sandbox (`SandboxOptions.foodLootNew` and the rest, each a `DoubleSandboxOption`
  from 0 to 4, 0.6 by default); `Generator` reads `generatorSpawning` through `doSandboxSettings`; a name it does not know gets
  the modifier of other loot.
- **A mod's options.** `CustomSandboxOptions` reads each mod's `sandbox-options.txt` as the mods load, before their Lua;
  `SandboxOptions.getOptionByName(name)` finds an option by its full name (`Page.Name`) in a map. The custom options are made
  again with the mods (`removeCustomOptions`).

### Calls

| Call | Effect |
| --- | --- |
| `loot.define(handle, id, spec)` | Defines the mod's kind `id` (1 to 64 letters, digits, `_`, `.` or `-`), or changes one it defined, and returns its name, `<handle name>:<id>`. `spec` is `{ option = "MyMod.PartsLoot", items = { "MyMod.Part", ... }, requires = { ... } }`: the full name of a number option of the sandbox (type `double`, as the game's loot options are), up to 1024 full types, and optionally the boolean options of the sandbox the kind requires (below). An item another mod's kind holds is a Lua error; one of the mod's other kinds gives it up to this one. An option the sandbox does not have, an option of another type, an item that is not a full type (`Module.Name`), or a field the spec does not take, is a Lua error. |
| `loot.kindOf(fullType)` | The name of the mod's kind that holds the item, or `nil` (the game's kinds are not told). |

`handle:clear()` takes the mod's kinds back: its items are of the game's kinds again. A mod defines its kinds as its Lua loads:
they belong to the Lua environment, as the moodles' definitions do, so they are there before the first world rolls its loot (the
first squares load before `OnGameStart`), and the mods define them again when the game loads its Lua again. A newer API takes
them over.

`requires` is for the parts of a mod that its world switches off with a sandbox option: up to 16 entries, each the full name of a
boolean option or a list of up to 16 names, and the kind's items are rolled at 0 (as an option at 0 rolls them) unless every
entry is on, a list being on when one of its options is. `{ "MyMod.EnableWater", { "MyMod.EnablePumps", "MyMod.EnableSprinklers" } }`
rolls the items while the water is on and the pumps or the sprinklers are. Like the option, the requirements are read as the game
rolls: a mod's distribution lists cannot leave such items out, since the game merges them and raises `OnInitWorld` before it loads
the world's sandbox options (`IsoWorld.init`: `OnPreDistributionMerge` to `OnPostDistributionMerge`, `OnInitWorld`,
`SandboxOptions.load()`, `ItemPickerJava.Parse()`), and a change of the options in a running world counts from the next roll.

### What a mod provides

- **The option.** In its `sandbox-options.txt`, as the game's loot options are: `type = double, min = 0, max = 4, default = 0.6`,
  so that 0 keeps the items out, 0.6 is the game's default and 4 the game's most.
- **Where the items are.** The mod puts its items into the game's distribution lists (`ProceduralDistributions.list[...]`,
  `VehicleDistributions`, `SuburbsDistributions`) with their weights, as any mod does. The kind's modifier then multiplies them
  where the game rolls them; the API does not place items.
- **Text.** The admin panel's item list names the kind by `Sandbox_<name>LootNew` in the mod's `Sandbox.json`, such as
  `"Sandbox_MyMod:PartsLootNew": "Parts"`.

### Hook sites

| Hook | Where | What it does |
| --- | --- | --- |
| `ItemPickerJava.getLootType` | each return | The name of the mod's kind for an item one lists (by `Item.getFullName()`, a field); the game's answer for any other. |
| `ItemPickerJava.getLootModifierFromType:kind` | the start | For a mod's kind, the value of its option now, returned; for any other name (NaN) the game's comparisons go on. The same method as the formulas' `ammoLootModifier` hook. |

A hook that fails gives the game's answer (the item's own kind; a mod's kind name then gets the modifier of other loot), and so
does a kind whose option the sandbox no longer has. Both hooks are asked for every item rolled, on whatever thread fills the
container: an item no mod lists costs one map lookup; a mod's kind the sandbox's map lookup and the option's value; nothing
allocates.

### Verified

In the synthetic game (the `api` suite, `LootTest`): an item no mod lists is of the game's kind and its chance unchanged; listed,
it is of the mod's kind, its chance goes with the mod's option, the option's value now is read (0 keeps it out), and the game's
items and kinds stay the game's; another mod cannot take the item, the mod's own moves to its other kind, and defined again a
kind holds what it lists now; a kind's requirements roll it at 0 while one is off (every entry on, one of a list), read as the
game rolls, and are kept for a newer API; wrong specs, requirements and handles are Lua errors; a kind whose option is gone rolls as other loot; the hooks
allocated nothing over 100,000 rolls; a newer API takes the kinds over and a function kept from before says the API was updated;
a handler that fails gives the game's answers; `clear` gives the items back to the game's kinds.

Not tried in the game yet: the hooks in the real bytes, a mod's option found as its Lua loads, and the kinds there after the game
loads its Lua again.

## Text (mechanism)

A mod shows text on the screen: a line in a font, a colour and a size, that comes on, stays and goes with an effect; or a
title, a large line in the middle of the screen with a smaller one under it, in one of a few styles, one title after another.
A text can also be typed, a character at a time with pauses and a cursor, carry colours, and be broken to a width
([below](#typing-markup-and-fitting-a-width)). The mod says what and when, from its own events (a quest done, a search done); the API draws it with the game's own text
drawing, once a frame, with no Lua running for it.
([`Texts`](../src/api/pzext/api/Texts.java))

### How the game does it

Read from the bytecode of Build 42 (`projectzomboid.jar`, and PZ Optimize's loose `UIManager`, `IsoCamera` and `IndieGL`,
which override the jar's; it overrides none of the text classes):

- **Drawing.** `TextManager.instance.DrawString(UIFont, x, y, zoom, text, r, g, b, a)` draws a string at a zoom: the font's
  `AngelCodeFont.drawString` puts each character's quad at its size times the zoom (`CharDef.draw`). This is what
  `ISUIElement:drawTextZoomed` calls in the game's Lua. A string has no line breaks of its own here: the API draws each
  line by itself. `MeasureStringX(font, text)` and `getFontHeight(font)` measure at zoom 1.
- **Fonts.** `UIFont` names the fonts. The usual ones (`Small`, `Medium`, `Large`, `Title`, ...) are the language's bitmap
  fonts (`media/fonts/<language>/fonts.txt`; Korean's `Large` is `zomboidLargeKorean`, 11821 characters), of a fixed
  size (`Large` is 26 to 50 pixels high by the font size option, `Small` 16 to 38; [below](#text-at-a-height)), which blur when zoomed. `Massive` is 47 high and has 99 characters, Latin alone. The distance-field fonts
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
| `text.move(handle, key, spec)` | The mod's text (or title, with its line) goes to another place, colour strength or backdrop: `spec` is `x`, `y` (0 to 1, as `show`'s; a title's line goes as far as the title), `alpha` (the colour's, 0 to 1), `backdrop` (0 to 1), `cursor` (a typed text's, on or off: at once) and `time` (0 to 30 s, 0.3 when left out), each but `time` left as it is when left out. It eases out from where it is, on its way too when moved again; one not on the screen yet is there at once. `true` when there was one. For lines that stack, as subtitles do: the earlier ones move up and dim as a new one comes. |
| `text.shown(handle, key)` | Whether it is on the screen or waiting. |
| `text.styles()` | The titles' styles: `{ "stamp", "discovery", "notice", "unveil", "dust", "bleed", "sink", "type", "pulse", "brief" }`. |
| `text.status()` | Whether the hook that draws is in the game: `"applied"`, `"not-loaded"` (the interface's class has not loaded), or why not, worded as `PZExtAPI.hooks()` is. A mod shows the player what is not applied. |
| `text.font(handle, px)` | A key for text a line of `px` pixels high in the mod's own windows, or nil; see [text at a height](#text-at-a-height). |
| `text.fontHeight(handle, key)` | The line's height to lay out with, as `getFontHeight` is for the game's fonts. |
| `text.measure(handle, key, text)` | The text's width in pixels, as `MeasureStringX` is. |
| `text.draw(handle, key, text, x, y, r, g, b, a)` | Draws the text at screen pixels from a window's `prerender` or `render`, as `drawText` would. |
| `text.wrap(handle, font, text, width)` | `lines, widest`: the text broken into lines no wider than `width` pixels in a font; see [wrapping and fitting a width](#wrapping-and-fitting-a-width). |
| `text.fit(handle, font, text, width, ellipsis)` | `fitted, cut`: the text cut to `width` pixels with an ellipsis; the same section. |

`show`'s spec; every field but `text` may be left out:

| Field | Value | Meaning |
| --- | --- | --- |
| `text` | 1 to 512 characters | The text; `\n` breaks it into at most 8 lines (counted after the markup, with `markup`, is read). |
| `font` | a name, or a list of 1 to 8 | One of the game's `UIFont` names (`"Large"` when left out). In a list, the first that has every character of the text is used, the last when none has: `{ "SdfBold", "Large" }` is the sharp font for Latin text and the language's for the rest. A line taller than the language's own fonts are made is drawn in the API's [embedded font](#the-embedded-font) instead of a zoomed game font. |
| `size` | 0.005 to 0.5 | The height of a line as a share of the player's screen's height, whatever the font and the resolution. |
| `scale` | 0.05 to 20 | The zoom of the font instead (1 when left out), when there is no `size`. |
| `color` | `{ r, g, b, a }` or `{ r = , g = , b = , a = }`, 0 to 1 | White when left out; `a` is 1 when left out. |
| `x`, `y` | 0 to 1 | Where on the player's screen, as shares of its width and height (0.5, 0.5: the middle). The text's lines are centred on `y`. |
| `align` | `"left"`, `"center"`, `"right"` | Which side of the text is at `x` (`"center"`). |
| `shadow` | boolean | A dark copy a little below and to the right. |
| `outline` | 0 to 8 pixels | Copies around the text, in `outlineColor` (black). |
| `delay` | 0 to 30 seconds | Before it comes on. |
| `enter`, `enterTime` | `"none"`, `"fade"`, `"pop"`, `"slam"`, `"settle"`, `"rise"`, `"drop"`, `"slide"`, `"type"`, and the looks `"impact"`, `"torch"`, `"signal"`, `"mist"`, `"bleed"`, `"strike"`; 0 to 30 seconds | How it comes on: fades in; pops from half its size past its size and back; slams down from 2.5 times its size; settles, coming down from 0.3 of a line above its place as it fades in (`0.3 (1 - in)^3`, at its size throughout); rises, or drops, three quarters of a line into its place as it fades in; slides up 0.4 of a line into its place as it fades in; or types (see [typing](#typing-markup-and-fitting-a-width)), which takes as long as its text and speed do, so it takes no `enterTime`. The looks are drawn by the API's shader (see [looks](#looks)): it falls and hits, a torch sways in over it, it is tuned in as a radio signal, the mist clears off it, drops bleed into it, or its letters are struck on a typewriter. |
| `hold` | 0 to 3600 seconds | How long it stays once on; left out, until the mod hides it. |
| `leave`, `leaveTime` | `"none"`, `"fade"`, `"rise"`, `"sink"`, `"grow"`, `"shrink"`, `"dust"`, and the looks `"erode"`, `"dim"`, `"lost"`, `"mist"`, `"burn"`, `"flare"`, `"dry"`, `"under"`, `"feed"`, `"exhale"`, `"wash"`; 0 to 30 seconds | How it goes: fades; drifts half a line up, or down; swells by 30%, or shrinks by half; each as it fades. `"dust"` crumbles it like ash that the wind takes a long way, swept across it from one side (see [dust](#dust)). The looks (see [looks](#looks)): it weathers away in place, the torch on it dies down to embers, the signal is lost into the static, it sinks back into the mist, it burns away like paper, it flares away from its foot, its ash drifting a while after, it dries dark and flakes away, it sinks into still water, its paper is fed out, it breathes out after a last heartbeat, or its ink dries away in blotches. `"none"` goes at once. |
| `player` | 0 to 3 | The local player whose screen it is on; left out, every local player's. |
| `queue` | boolean | It waits for the titles and queued texts before it on its screen (see titles). |
| `markup` | boolean | The text has [markup](#typing-markup-and-fitting-a-width): pauses, speed changes and colours (false when left out: braces are braces). |
| `width` | 0.05 to 1 | The longest a line may be, as a share of the player's screen's width: longer lines are broken at spaces. Left out, a line is as long as it is. |
| `speed` | 1 to 1000 | With `enter = "type"`: the characters a second (30 when left out). |
| `cursor` | boolean | With `enter = "type"`: a blinking underscore after the last character typed. |
| `backdrop` | 0 to 1 | A dark backdrop behind the text, this strong in its middle (0, when left out: none), so that it reads over a busy screen: a box over its lines whose edge fades out over 2.6 line heights to the sides and a line up and down as a smooth step: one layer, the box and four rings round it, each ring's quads shaded by the card from the inside's darkness to the outside's (a colour for each corner, at the text's own place, not whole pixels), so that it fades and moves as smoothly as the text (layers stacked each a little smaller rounded together to the screen's levels and stepped as they faded). It is as strong as the text is seen, and comes in over 1.2 s at most as fast (a look's enter is whole from the start); a text that leaves as dust or burns takes it with it over its leave. Under a look it stays at the text's place at rest. |
| `dustSize` | 0.25 to 8 | With `leave = "dust"`, `"burn"` or `"flare"`: the size of the dust's cells, as a share of the usual (1: 4% of the line's height, 4.3 pixels for a line a tenth of a 1080-pixel screen). |
| `dustSweep` | `"right"`, `"left"`, `"up"`, `"down"`, `"upright"`, `"upleft"`, `"downright"`, `"downleft"` | With `leave = "dust"` or `"burn"`: the way the front goes (`"right"` when left out: the text breaks from its left side first; `"downleft"` from its top right corner, the front at 45 degrees in cells). A side's flakes go the front's way; a corner's go back towards the corner, away from what is left. |
| `dustDrift` | 0 to 4 | With `leave = "dust"` or `"burn"`: how far the dust drifts, as a share of the usual (1: about two lines up, and up to four and a half lines to the side; 0: the cells fade where they are). |
| `dustBurn` | a colour `{ r, g, b }` or `{ r, g, b, a }` | With `leave = "dust"`: it burns as charcoal instead of weathering: ahead of the front it scorches, glows in this colour at its edge and goes out to black char that crumbles to dark ash, a few sparks of the colour among it (see [dust](#dust)). Left out, it weathers to grey ash. With `leave = "burn"` or `"flare"`: the colour of its flame's edge and sparks ((1, 0.32, 0.1) when left out). |

`title`'s spec: `text` (the title), `subtitle` (the line under it), `style` (`"dust"` when left out), and to change the style's
`color`, `subtitleColor`, `hold` (seconds), `y`, `player`, `leave` and `leaveTime` (for the title and its line alike: any style
can leave as dust), `backdrop` (0 for none), `scale` (0.4 to 2.5: the style's sizes of the title and its line times this, for a
title that matters more or less than its style says), `dustSize`, `dustSweep`, `dustDrift` and `dustBurn` (with `leave = "dust"`, `"burn"` or `"flare"`, the
style's or the spec's), `sounds` and `subtitleSounds` (below), and `now`. The line under a title takes its look's cues from it (a torch's flicker).

A title sounds at its moments when its spec names the game's sounds for them: `sounds = { enter = ..., land = ..., leave = ... }` for the title,
`subtitleSounds` (with a `subtitle`) for its line, each moment optional, each a sound's name (a vanilla one, or a mod's from its sound scripts:
letters, digits, `_` and `.`). `enter` as it starts to come in, `land` as it has come in (an `"impact"` as its letters hit, 0.16 s in; else at
the end of its enter), `leave` as it starts to leave. Each is played once, on the screen (the game's UI sound), with the first screen's copy
of the title (a split screen's players share the speakers), as the title's clock passes it: a pause holds it, and a moment passed with
nothing to hear (a title hidden before it was in) is passed silently. A newer API goes on from the moments passed. The API knows no sound of
its own: which a style sounds is the mod's. A title's backdrop reaches over its line: one backdrop for both. Every style stays 5 s once all of it is in (the title, and its line when it has one: its hold is
lengthened by as much as the line comes in after the title) and has a backdrop of 0.3, but `"brief"`, a light one for small news. A style is a pair of `show` specs:

| Style | Title | Line under it |
| --- | --- | --- |
| `"stamp"` | Pale (0.9, 0.89, 0.86), `SdfBold` (or `Large`), a line 10% of the screen high at `y` 0.16 (above the player and the words said over their head); falls onto the screen and hits in 0.6 s (`"impact"`), inked as it hits, a gleam passing over it once as it stays 5 s; its ink dries away in blotches over 6 s (`"wash"`). For something done: a quest complete. | Light grey, `SdfRegular` (or `Medium`), 4.5%, a shadow; struck too, 0.15 s after the title and more lightly (`"impact"`, 0.6 s); weathers away over 5.6 s, 0.4 s after it. |
| `"discovery"` | Amber (1, 0.8, 0.38), `SdfBold` (or `Large`), 8% at `y` 0.16, a shadow and a faint dark outline; a torch sways in over it and opens over 2.2 s (`"torch"`), flickers once as it stays 5 s, and dies down to embers over 4.5 s (`"dim"`). For something found: a search complete. | Pale amber, `SdfRegular` (or `Medium`), 4.2%, lit by the torch; slides up over 0.8 s, 1.5 s after the title; dims over 4.3 s, 0.15 s after it. |
| `"notice"` | Cool white (0.88, 0.93, 1), `SdfBold` (or `Medium`), 4% at `y` 0.16, a shadow; tuned in as a radio signal over 0.7 s (`"signal"`), a hiccup as it stays 5 s, lost into the static over 4.5 s (`"lost"`). For news that is not an event of its own. | Grey-blue, `SdfRegular` (or `Small`), 2.8%; tuned in 0.25 s after the title; lost over 4.3 s, 0.1 s after it. |
| `"unveil"` | Soft warm white (0.96, 0.93, 0.86), `SdfRegular` (or `Large`), 7.5% at `y` 0.16, a shadow and a faint dark outline; the mist clears off it over 3.6 s (`"mist"`) and drifts behind it as it stays 5 s; it sinks back into the mist over 5 s. For something that opens: a new chapter, a new path. | Pale grey, `SdfRegular` (or `Medium`), 3.6%; clears over 3 s, 1.2 s after the title; sinks over 4.8 s, 0.3 s after it. |
| `"dust"` | Warm white (0.97, 0.95, 0.9), `SdfRegular` (or `Large`), 8.5% at `y` 0.16, a shadow and a faint dark outline; fades in over 1.2 s, stays 5 s, and burns away like paper from its top right corner over 10 s (`"burn"`), its ash and sparks taken by the wind. For something that ends. | Pale grey, `SdfRegular` (or `Medium`), 4%; fades in over 1.2 s, 0.35 s after the title, and burns 0.3 s after it. |
| `"bleed"` | Dark red (0.72, 0.08, 0.07), `SdfBold` (or `Large`), 8.5% at `y` 0.16, a shadow and a dark outline; drops fall on it one after another and soak it in over 1.9 s (`"bleed"`), a drop running down from it as it stays 5 s; it dries dark and flakes away over 6 s (`"dry"`). For something grave: an infection found. | Pale pinkish grey, `SdfRegular` (or `Medium`), 4%; seeps in over 1.2 s, 1.3 s after the title; dries over 5.6 s, 0.2 s after it. |
| `"sink"` | Cool pale grey (0.86, 0.88, 0.9), `SdfRegular` (or `Large`), 8% at `y` 0.16, a shadow and a faint dark outline; settles in over 1.6 s, stays 5 s; still water shows under it, its mirror coming up swaying, and it sinks into it over 9 s (`"under"`). For something lost. | Grey-blue, `SdfRegular` (or `Medium`), 3.8%; fades in over 1.4 s, 0.8 s after the title; sinks with it into its own water. |
| `"type"` | Paper white (0.92, 0.9, 0.84), `SdfRegular` (or `Large`), 7.5% at `y` 0.16, a shadow and a faint dark outline; its letters struck one by one over 1.3 s (`"strike"`), stays 5 s; its paper fed out a line at a time over 5.5 s (`"feed"`). For a document: a guide, an order. | Grey, `SdfRegular` (or `Medium`), 3.8%; struck over 1.6 s, 1.5 s after the title; fed out with it. |
| `"pulse"` | Warm white (0.96, 0.94, 0.88), `SdfRegular` (or `Large`), 8% at `y` 0.16, a shadow and a faint dark outline; fades in over 0.9 s and beats with a racing heart that calms as it stays 5 s, a warm glow flaring with each beat; one more beat, a stillness, a last weak beat, and it breathes out over 10.7 s in all (`"exhale"`). For relief: a danger passed. | Pale warm grey, `SdfRegular` (or `Medium`), 3.8%; fades in over 0.9 s, 0.6 s after the title; beats and breathes out with it. |
| `"brief"` | Warm white (0.95, 0.93, 0.88), `SdfRegular` (or `Medium`), 3.6% at `y` 0.8 (low, over the hotbar), a shadow and a faint dark outline, a backdrop of 0.22; slides up over 0.45 s, stays 4 s, and flares away over 3.5 s (`"flare"`), its ash drifting 3.5 s more. For small news: a bonus, a part fitted. In a queue of its own (below). | Pale grey, `SdfRegular` (or `Small`), 2.6%; slides up 0.15 s after the title; flares 0.15 s after it. |

Each local player's screen has a queue of titles: one shows at a time (the title and its line), and the next starts when it
has gone (a flare's ash aside: the next starts as it drifts). A title for every player goes into each player's queue. `now` lets a
title go first: the one on that screen leaves within 0.25 s and this one follows, before those waiting. At most 8 wait on a
screen; a ninth makes the oldest waiting go. A text with `queue` waits in the same queue. `"brief"` titles have a queue of their
own on each screen, the same way: low on the screen, they do not wait for the other titles, nor those for them.

A text's time starts when it is first drawn, not when it is shown: one shown while nothing is drawn (a loading screen) comes
on as the screen does. The time is the interface's (`System.nanoTime`), but it does not go on while the game is paused
(`GameTime.isGamePaused`: its speed at 0), when what is shown stays drawn where it is (a typing stops mid-line, an effect
stands) and nothing starts; and it goes on only with the frames the text is drawn in, so that a text is not over before it was seen: none starts
on a player's screen while the player sleeps or the screen is dark (`UIManager.getFadeAlpha(player)` above 0.01: the black the
game fades it to for sleep), though one already on it plays on in real time over the black, as bright as it was (drawn as the
interface's drawing ends, `UIManager.render:textOver`; the game's speed while asleep does not touch it); every screen holds its texts (none starts, and the time of those on it stands) while the game's menu
is over the game (`MainScreen.instance` in game and shown: Escape), which they would be drawn over; one frame counts for at most a quarter of a
second, so a hitch, or a while with no frame drawn, does not run a text out either. A mod has at
most 64 texts shown or waiting, all mods 256; more is a Lua error. `handle:clear()` takes the mod's texts away at once. A text
belongs to the world it was shown in: leaving it takes the text away. A text for a player who is not there waits for them. A
newer API takes what is shown over at the moment it was at, keys included; a function a mod copied out of the table says the
API was updated.

Multiplayer is not blocked: the text is drawn on the machine that shows it, for its local players; nothing is sent.

### Typing, markup and fitting a width

For a text that is read as it comes (a transmission, a terminal): the characters come on one after another, as a typewriter
does, drawn by the API with no Lua running for it. These apply to `show`, not to `title`.

**Typing.** `enter = "type"` shows the characters one at a time, in order, at `speed` characters a second (30 when left out; 1
to 1000). A character is a UTF-16 unit: a Hangul syllable is one, so Korean is typed a syllable at a time. The first comes on
when the text is first drawn (after its `delay`), and the next one every `1 / speed` seconds, spaces too; a `\n` takes no time
of its own. The rows are laid out for the whole text from the start, so nothing moves as it is typed: text centred on a line
stays centred on the whole line. Typing takes as long as the text and its pauses take, and that is the enter effect's time:
`hold` counts from the end of it (the last character's turn, and any pause after it), and `enterTime` is not taken (a Lua error
with `"type"`). A text hidden while it is typed leaves with what had come on. `speed` and `cursor` are Lua errors without
`enter = "type"`. A text may take at most 300 seconds to type.

**Cursor.** `cursor = true` draws an underscore (`_`, in the text's colour and the font's glyph for it; the font list picks a font
that has it) after the last character that has come on, or at the start of the text before the first. It is on while characters
are coming, and blinks while it waits: on for 0.5 s, off for 0.5 s, counted from the time of the last character that came on (a
pause blinks it; so does a text that is done, until it leaves).

**Markup.** With `markup = true` the text may carry tags in braces, read once when the text is shown:

| Markup | Meaning |
| --- | --- |
| `{p:seconds}` | A pause: the next character comes on `seconds` later than it would (0 to 30; digits with an optional fraction of up to 3 digits: `{p:0.6}`, `{p:3}`). At the start of the text it delays the first character; at the end it delays the end of typing, and so the hold. |
| `{s:rate}` | From the next character on, `rate` characters a second (1 to 1000, as `speed`): `{s:8}` is slow, `{s:60}` quick. |
| `{s}` | From the next character on, the text's own `speed` again. |
| `{c:RRGGBB}` ... `{/c}` | The characters between are in this colour: six hexadecimal digits, red, green, blue (`FF8000`, either case, no `#`). The text's alpha, shadow and outline stay. Colours do not nest: another `{c:...}` before the `{/c}` is an error. |
| `{{` and `}}` | One `{` and one `}`. |

Anything else in braces, a `{` with no `}` after it, a `}` with no `{` before it, a malformed number, a `{c:...}` never closed,
a `{/c}` with none open, and a text with no character left once the tags are taken out, are Lua errors that name the tag and
its place in the text (the character's number). The 512 characters include the tags; the 8 lines, the font and the width are of what is
left of them. Outside typing the tags do nothing but colour and the braces: the same translated string can
be shown typed or whole. Without `markup`, braces are the text, as they always were.

Example, three lines of a transmission (speed 30; the pauses add up to 5.3 s):

```lua
PZExtAPI.text.show(handle, { enter = "type", speed = 30, cursor = true, markup = true, width = 0.5, align = "left", x = 0.25, hold = 4,
    text = "Receiving{p:0.6}.{p:0.6}.{p:0.6}.{p:1.2}\n{c:FFD060}Point 0347.{/c}{p:0.8} Passing on the result.{p:1.5}\n{s:8}Destroy the sample." })
```

**Fitting a width.** `width = w` breaks the text so that no row is wider than `w` of the player's screen's width (0.05 to
1), measured with the game's font at the zoom the text has before its effects (so a growing text is not broken again), and
for each local player's screen: in split screen the two halves can break the same text in different places. A line (a `\n`)
breaks:

- before a word that follows spaces (the spaces at the break are dropped; spaces elsewhere stay);
- between two characters of the scripts written without spaces (Han, kana, full-width forms), but not beside a space;
- when a word alone is wider than `w`, after as many of its characters as fit, at least one.

There is no hyphenation and no rule for punctuation at the start of a row. Hangul is written with spaces and breaks at
them. The rows are centred or aligned each by itself as before (`align`, `x`), and the block as a whole on `y`. Without
`width`, the rows are the text's own lines, as before. With it, the limit of 8 lines is on the text's own (`\n`) lines, and
the rows they break into are not limited but by the 512 characters. The rows are made again when the screen's size or the
game's font changes.

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

A text with markup, typing or a width is drawn from its rows, still one `DrawString` for each run of one colour. The
markup is read, and the time of each character worked out (the characters a second, the pauses and speed changes added up),
once, when the text is shown. The rows are made once for each screen's size and font: the text broken at its width, with each
row's width and each colour run's place in it measured with the game's font. Each frame the characters that have come on are
the ones whose time is not after the typing clock (the time since the text was first drawn, less its delay, and no later than
the time it began to leave: a binary search), the runs and rows are cut there, and the cursor is placed after them. The first
`n` characters of a run are made as a string the first time `n` are shown, with their width for the cursor, and kept: a frame
makes no string, once the characters are there. The rows are not changed by the effects' zoom or shift, and a text that is not
typed, with no colour and no width, takes the plain path above, as it always did.

| Hook | Where | What it does |
| --- | --- | --- |
| `UIManager.render:text` | before the first of the method's two calls of `getToolTip()` | Draws the text: over the windows, under the tooltip, the paused message and the fade over the interface. The two calls are counted: a method with another number of them gets no hook. |
| `UIManager.render:textOver` | at the method's returns | Draws, over the black the game fades a player's screen to (sleep), the texts that were on that screen before it went dark and play on. Without it they are drawn under the black, by the hook above. |

The text is drawn as often as the interface is: with the interface drawn at a lower rate, it moves at that rate. A hook that
is not in gives no text and `text.status()` says why; a fault while drawing is reported once in the game's log, and the
interface goes on being drawn (the tooltip and what follows it).

### Looks

A look is an enter or a leave the API draws with a shader of its own over a picture of the text
([`Looks`](../src/api/pzext/api/Looks.java)): the dust's picture ([below](#dust)), made as soon as the text shows (once typed, for a
typed text) at its place and size at rest. Each frame the main thread hands the render queue a frame of the look, a few numbers
(the text's place, scale, squash and move, the shares of its enter and leave, its clocks); the render thread draws it from them
in the queue's order: the game's state saved (`glPushAttrib`, `glPushClientAttrib`, the program bound), the API's program
(GLSL 1.20, compiled once from its source on the render thread), the projection the interface is drawn with now (the game's
matrix stacks, as `ShaderHelper.setModelViewProjection` reads them), the picture's part of its texture, the vertices from an
array of its own; then the state put back as the game's other passes do (the texture cache forgotten, the ring buffer's arrays
set up again, `GLStateRenderThread.restore`). Its numbers are those of `tools/title-lab`, where the looks are made: the page draws
them with the same arithmetic and shader.

| Look | What it draws |
| --- | --- |
| `"impact"` (enter) | The text falls from 1.45 times its size over 0.16 s and hits: it squashes and rings out, shakes, and is white-hot, cooling (its shape in light, and a glow round it), with a streak of light across it widening and a puff of dust kicked out to the sides. As it stays, a gleam passes over its letters once, slowly, from 0.8 s to 0.3 s before it leaves. The line under a title hits at 55% of that (its fall, squash, shake, light and dust). |
| `"torch"` (enter), `"dim"` (leave) | A torch's beam sways in from the left over the text, lighting what it passes, then opens over all of it; its light falls on what is behind the text. It flickers once 1.4 s after the enter, and as the text leaves it stutters three times and dies down to embers (the text warm and dark, then gone over the last 60%). A text that only leaves so (the line under a torch-lit title) is lit all over. |
| `"signal"` (enter), `"lost"` (leave) | The text as a radio signal: as it is weak its rows tear sideways, its colours come apart, grain eats it, scan lines and specks of static show. It is tuned in over its enter (a hiccup on the way), hiccups once 2.6 s after, and as it leaves cuts out twice and sinks into the grain. |
| `"mist"` (enter and leave) | Drifting mist (two layers drifting their own ways) over a band round the text, drawn behind it: the text clears from blurred and faint, its colour grey, as the mist thins to a veil that drifts on as it stays; as it leaves the mist thickens again and the text sinks back into it, the mist then thinning away itself. |
| `"erode"` (leave) | The text weathers away in place: its colour drains, it wears off in pits from its edges (a noise of its grain over how much ink is round each point), and the last of it fades. |
| `"burn"` (leave) | The text burns away like paper, spot by spot: a map of when each pixel burns (the sweep of `dustSweep`, 52% of the leave to cross it, clumps a few cells wide that open holes ahead of the front, fibres that make its edge ragged, a warp that curls it); at each spot a flame's edge (a hot core, then the burn's colour, `dustBurn`), char behind it and scorch ahead of it. The dust's cells leave as their middle burns: half of the rest as shards of ash that tumble on the wind (char greying fast, their rim glowing a moment), a quarter as sparks of the burn's colour cooling to dark ash. |
| `"flare"` (leave) | The text burns as `"burn"` does, but from a spot at its middle's foot (85% down its picture), spreading round, a spot's height counting four times its place across, so that the letters aside burn from their feet up; the burn is done by 90% of the leave, fast at first and slowing (`1 - (1 - u)^1.5` of the way to its last spot). Its ash and sparks are thrown out from that spot as their spots burn, slowing (`1 - e^(-7a)`), and then drift round in the air, a little up, the circle 0.3 lines wide; they fly 3.5 s (from 75% of that), apart from the leave: the text is shown until the last is gone, but the next in its queue starts as soon as its leave is over. |
| `"bleed"` (enter), `"dry"` (leave) | Drops land on the text one after another in a shuffled order across it (a title's fall onto it, flecks flying as each hits; a line's seep in, sooner), and each spreads with a ragged edge, soaking the letters in with a wet front (a title's blots a little past its letters too). As a title stays, a drop runs down from under its first, a bead at its end. As it leaves it dries dark and flakes away in patches. The text's own colour is the blood's. |
| `"under"` (leave) | Still water at the text's foot (the lowest row of its ink): its mirror in it comes up over 3.5 s, swaying in fine streaks letter by letter; 1.5 s after, the text sinks into it, slowly at first and faster and faster (`u^2.5`), fading with it; what has gone under is not seen. The line under a title has its own water at its own foot, and they sink together. In a leave shorter than 9 s these times are shorter alike. |
| `"strike"` (enter), `"feed"` (leave) | Its letters are struck one by one at a typist's uneven pace (a longer pause after a space), all within nine tenths of its enter, each a little off its line, inked a little unevenly and struck a touch big and bright, settling at once. As it leaves its paper is fed up a fifth of the title's line at a time, three quick jerks, fading over the last 60%. |
| `"exhale"` (leave) | A warm glow under the text, a little always, flaring with each beat of a heart that races at first (about 110 a minute) and calms (about 55, weaker) by the time the title leaves, the text swelling a touch with each beat (the title's and its line's alike, on the group's clock). As it leaves: one more beat as calm, a stillness of 1.2 s after it has died down, a last weak beat, a still 1.7 s, and then a breath out: it settles a little and fades, its glow rising a touch and staying on after it, then dimming away. In a leave shorter than 10.7 s these times are shorter alike. |
| `"wash"` (leave) | The text is ink, by a map made once from its picture (how much ink each spot took: more down a stroke's middle, patchy where the paper's grain and fibres held it back; the paper's fibre; blotches of how late it dries and when its colour lifts). The ink lands as the text shows (as it hits, after `"impact"`): wet, lit from the upper left with a gloss, stirring a little, a shadow under it. As it leaves it dries in blotches (from 8% of the leave, over 48% of it each, up to 22% later), its gloss going and its colour turning to a dull wash of its own, then lifting away spot by spot; its pressed shape stays a moment after, faint. Its backdrop fades over the second half. Its ink is made from its letters alone (no shadow or outline); the look draws its own shadow. |

The torch's, the radio's and the mist's looks are the text's whole life when its enter or its leave is that look. Other enters and
leaves go with a look as they do alone: a line's `"slide"` gives its alpha and move, and the impact and erosion are drawn over the
text's picture as it is.

**When it cannot.** Without the game's frame buffers or the API's shader (it does not compile or link, or a draw fails: once in the
game's log), or with a box that moved, a look's text is drawn as it is, its look's enter and `"burn"` or `"flare"` a fade, its other looks' leaves
the fade their backdrop has. While the picture is on its way (a frame or two) the text is drawn so too. A burn's cells and map are
made away from the main thread (some tens of milliseconds for a title, as the title stays); until they are there it is drawn so.

**The cost.** On the main thread a frame of a look is a few numbers: 0.7 us a frame for a torch-lit title and its line in the
synthetic game, nothing allocated over 20,000 frames. On the render thread a few quads and the shader over the text's box; a burn's
shards are a draw of their own (at most one for each of the dust's cells).

### Dust

`leave = "dust"` crumbles the text like ash as it goes: a front crosses it from one side (`dustSweep`), and where it has passed
the text comes apart, as weathering: ahead of the front it greys and wears thin, pitted in patches that open and spread before
the front comes; then its flakes, chips and grains of dust, glow faintly warm as they come loose, sag, and are caught by the wind
and taken ever faster a long way up and to the side, billowing, wearing down and greying as they fade. The part the front has not
reached and that does not wear yet stays as it was. The cells are pieces of the text as it was drawn, shadow, outline and colours with
them, not copies of its letters
([`Dust`](../src/api/pzext/api/Dust.java)).

**How the game draws into a picture.** Read from the bytecode of Build 42 (the jar's classes, and PZ Optimize's loose
`TextureFBO`, `TextureDraw`, `RenderThread` and `SpriteRendererStates`, which keep the same members):

- `new Texture(width, height, 16)` makes a texture on the main thread; its storage is made on the render thread
  (`TextureID` queues it with `RenderThread.queueInvokeOnRenderContext`). `new TextureFBO(texture)` makes a frame buffer over it
  through `RenderThread.invokeOnRenderContext`, which runs at once on the render thread itself. This is how `UIManager.CreateFBO`
  makes the buffer the interface is drawn into.
- `TextureFBO.startDrawing(true, true)` binds the frame buffer and clears it to transparent; `endDrawing()` binds the one bound
  before it (a stack). Both are GL calls: they run on the render thread.
- The main thread does not draw: `SpriteRenderer` keeps what it is given for the render thread, which draws it a frame later.
  `SpriteRenderer.drawGeneric(GenericDrawer)` puts a drawer of one's own in that queue, run on the render thread in order with
  the sprites around it, as the game's atlases and model views do. `render(texture, the four corners, their texture coordinates,
  r, g, b, a)` puts a quad that shows any part of a texture.
- How sprites blend is the style each is queued with, the queue state's `defaultStyle`: `UIFBOStyle` blends the colours as
  usual and adds the alpha (the interface's buffer is drawn in it, its colours premultiplied by their alpha), and
  `AdditiveStyle` (one, one minus the source's alpha) is how the game draws that buffer onto the screen.

**What the API does.** A text that leaves as dust is drawn as before until it stands still: its enter is over, or it began to
leave. Then, a frame or so apart, on each screen it is on:

1. Its box is worked out: its lines' or rows' extent at their place, and a margin of a fifth of a line, the outline and the
   shadow's offset, and 2 pixels, in whole pixels. A box larger than 4096 pixels on a side, or a game without frame buffers
   (`TextureFBO.checkFBOSupport`), fades instead. The texture is made the box's size, and the frame buffer over it on the
   render thread.
2. Once the frame buffer is there, the text is drawn once more in the frame, into it: a drawer of the render queue saves the
   viewport and the scissor test, turns the scissor test off, starts the frame buffer and moves the viewport so that the box's
   top left is its corner (the interface's projection is its pixels, from the top left); then the text is queued as it is drawn
   on the screen (the shader, the shadow, the outline, the colours; no cursor), in `UIFBOStyle`; then another drawer reads the
   box's pixels back (`glReadPixels`, once, with the pack state saved and put back), ends the frame buffer and puts the
   viewport and the scissor test back. The style queued before is put back. The text is also drawn on the screen as usual in
   that frame.
3. The next frame, the main thread cuts the picture into square cells of `4% of the line's height times dustSize` (at least
   1.5 pixels) and keeps those with a texel of an alpha of 10 or more (of 255). With more than 4,500 of them, the cells are
   made larger until there are at most 4,500. The pixels read back are let go.

As it leaves, the text is drawn from the picture, in `AdditiveStyle`, with nothing else of the text drawn: in each lane
across the sweep (a row of cells, or a column for `"up"` and `"down"`), the part from the first cell the front has not reached
to the far side is one quad, the cells before it that have not started are each a quad in place, and the cells on their way are
each a quad at their place on their path. Every quad is a part of the one texture, so the game sends them to the card together.
At the start of the leave the text is a quad for each lane and looks as it did.

**The schedule**, in shares of `leaveTime`, the same for the same text (a seed from its key, screen and lines):

| Part | Value |
| --- | --- |
| The front | Crosses the box in 0.35 of the leave (from a corner: the cells' distance from it across and down, or up, alike, as a share of the box's columns and rows). A cell starts as the front reaches its place (its column, or row, in the box's grid), later by up to 0.25: 75% of that from a clumpy noise over the text (value noise in patches of 6 cells, 70%, and of 2.5 cells, 30%), so that patches go together and holes open and spread, and 25% its own. |
| Wearing | Over the 0.12 of the leave before it starts, a cell wears in place: its colour to 60% and its side to 78% (smoothly), so that the text greys and thins, pitted, ahead of the front. |
| A cell's life | 0.3 to 0.4 of the leave, its own, from its start; every cell has gone by the end of the leave. |
| Its path | At its age `a` (0 to 1): for its first 12% it sags `0.08` line heights (smoothly) as it comes loose; then the wind catches it (`w`, 0 to 1 over the rest), eased in as `w (0.25 + 0.75 w)`: up by `2 x (0.5 to 1.5)` line heights and to the side (the sweep's way, or back towards a corner's; either way for `"up"` and `"down"`) by `4.5 x` (half a gust that changes slowly across the sweep, 0.7 to 1, and half its own, 0.45 to 1) of that ease, times `dustDrift`; and a billow of `0.15 w` line heights to the side and `0.3 w` up and down, 0.5 to 1.1 turns over its life. |
| Its size and alpha | As a flake it is a chip (three in five: 80% to 100% of its worn side) or a grain of dust (40% to 60%), wearing down to 45% of that; it stays whole for a quarter of its life, then fades: `1 - smooth((a - 0.25) / 0.75)`. |
| Its colour | Drawn premultiplied, its colour below its alpha darkens it: it glows warm as it comes loose (green times 0.84 and blue times 0.62 at most, up over 8% of its life and out by a third), and greys to half its worn colour by 70% of its life (smoothly). |
| Burning (`dustBurn`) | In place of the wearing's grey and the flakes' colour, as charcoal. Over the 0.12 before it starts (its wear, smoothed), a cell scorches to (0.34, 0.18, 0.1) times its colour by 40% of it; glows by 62%: the burn's colour, its alpha down to 55% while its colour stays (smoothly), so that the light adds to what is behind it, flickering 9 times over the leave (dimming by up to 30%, each cell at its own phase); goes out to black char, (0.07, 0.055, 0.05), by 85%; and thins as char, by up to 22%. Its flake is char, greying to 0.2 by 70% of its life; one cell in four is a spark instead: it leaves glowing and cools over its first 40% (smoothly) to 30% of the burn's colour, its alpha back to its own. |

**When it cannot.** Dust fades as `"fade"` does when the game has no frame buffers, the box is too large or has no ink, a step
fails (once in the game's log), or the text's box moved after its picture was made (the screen's size changed). While the
picture is on its way (it comes a frame or two after the text stands still), the text is drawn as it was, for at most 15% of
the leave: a text that leaves at once is held whole that long, and fades if the picture has not come by then.

**Letting the picture go.** A piece's picture goes when its text has gone, is hidden or taken away (`hide`, `clear`, the world
left), or gives up the dust: at the start of the next drawing of the interface, a drawer queued after everything drawn before it
lets the frame buffer and its texture go (`TextureFBO.destroy`) on the render thread, so no frame that still draws it is behind
it. Should the queue never run it, it is let go on the render thread's own turn 120 frames later. A newer API lets the pictures
of the one it replaces go from its own drawing, the same way. A picture let go before its frame buffer was made is not made.

**The cost.** Nothing while no text is shown, and nothing more than before while a dust text comes on or holds but the one
frame that draws it into its picture (its strings twice) and the one that cuts it (a pass over the box's texels: about 47,000
for a title a tenth of a 1080-pixel screen high). While it leaves, a frame is a pass over its cells (a few multiplications each,
no sine) and a quad for each lane and each cell on its way, up to 4,500; nothing is allocated. Video memory: a texture the box's
size (rounded up to powers of two), for one text, from when it stands still until it has gone.

### The embedded font

The game's fonts for most languages are bitmaps made at fixed sizes: Korean `Large` is 26 to 45 pixels high by the font size
option, and only the folder of the current option is loaded. Drawn larger, they are zoomed and blur. The distance-field fonts
stay sharp but have no Hangul, kana or Han. So the API carries a font of its own for large text: Noto Sans SemiBold, the
typeface the game's own language fonts are made from, baked into a distance-field atlas that the game's `AngelCodeFont` draws
through the game's distance-field shader
([`EmbeddedFont`](../src/api/pzext/api/EmbeddedFont.java),
[`FontBaker`](../src/api/pzext/api/FontBaker.java)).

**When it draws.** A text is drawn in the embedded font when all of these hold, else in the game's font as before:

| Condition | Why |
| --- | --- |
| The line asked for (`size` times the screen's height, or the game font's line times `scale`) is taller than the line of the game's font the text's list picked (for Korean at the 1x option `Small` 18, `Medium` 24, `Large` 33 pixels) | Above it that font would be zoomed past its size and blur. At or below it, the game's font is drawn at its own size or smaller: hinted, crisp, and it follows a font mod for an unofficial language. A text sized as a share of the screen (`size`: a title and its line, a title's `scale` too) is the exception below: shorter than 97% of that line, the game's picture shrunk would be soft, so the embedded font draws it. The line is measured again when the game makes its fonts again. |
| The game's font the text's list picked is not a distance-field font | Those are sharp at any size already; `{ "SdfBold", "Large" }` keeps `SdfBold` for Latin text. |
| The embedded font has every character of the text, and the cursor's | Otherwise the game's font draws the whole text: no character is left out or drawn as a box, and a line is never in two fonts. |
| Its atlas is in video memory | Until then, and on a failure, the game's font draws. |

The choice is made each frame from the size before the effects, so a slam or a growth does not change fonts on the way; it
allocates nothing (the characters are looked up once a text). The lines, the rows of a width and the place of the cursor are
measured in the font that draws, again when the choice changes. The embedded font's line is the font's Windows ascent and
descent at its base size, as the game's bitmap fonts' are, so a text is the same height in either font. Its edge in the shader
is `0.75 / (2 * spread * zoom)`: a soft edge 1.5 screen pixels wide at any zoom (the game's `0.125 / zoom` is for its fonts'
spread of 4 at 32).

**The packs.** One font file a script, in the version folder's `fonts` folder (`pzext-font-<pack>.ttf`, with `OFL.txt`); only the
current language's is read.

| Pack | Game languages | Characters | File | Base size | Atlas, one channel |
| --- | --- | --- | --- | --- | --- |
| `latin` | All but those below | Latin (to Latin Extended-B), Greek, Cyrillic, punctuation and common signs; 1,030 | 182 KB | 64 | 2048 x 2048, 4 MB |
| `ko` | `KO` | The 2,350 Hangul syllables of KS X 1001, the compatibility jamo, the signs; 3,074 | 549 KB | 64 | 4096 x 4096, 16 MB |
| `ja` | `JP` | Kana, the 2,965 kanji of JIS X 0208's first level, the signs; 3,932 | 1.1 MB | 64 | 4096 x 8192, 32 MB |
| `sc` | `CN` | The 3,755 hanzi of GB 2312's first level, the signs; 4,701 | 1.3 MB | 64 | 4096 x 8192, 32 MB |
| `tc` | `CH` | The 5,401 frequent hanzi of Big5, the signs; 6,111 | 2.0 MB | 60 | 4096 x 8192, 32 MB |
| none | `TH` | The game's font draws Thai at every size | | | |

Each pack also has every character in use (`scripts/fonts/in-use/<pack>.txt`) that its typeface has. The script's `--scan` writes
those lists from the game's translations for the pack's languages, and from those of any mod folders it is given (`--mods`; all
their languages for the Latin pack); the lists in the repository are the game's alone. The Korean translation uses 1,497
syllables, 9 of them outside KS X 1001 (`깄`, `떄`, `쫒` and others). A mod whose text needs characters beyond the fixed sets
and the game's is scanned with `--mods` and the packs built again. Han glyphs differ by region, so the Chinese and Japanese packs are separate fonts. The CJK
packs' Latin is their own typeface's, as in the game's fonts.

[`build-fonts.py`](../tools/build-fonts.py) makes the packs from Google Fonts' variable fonts (not kept in
the repository): it cuts each down to its characters, pins the weight at SemiBold (600; Noto Sans's width at 100), drops the
hinting (a distance field needs none), the vertical metrics, the glyph names, the layout tables and `DSIG`, and keeps the pair
kerning of the non-CJK characters as a `kern` table. The same inputs give the same bytes. `--scan` writes the characters in use
from a game folder and mod folders.

**Baking.** As a Lua environment starts (a loading screen), the API names the bake
`<pack>-<first 16 hex digits of the font file's SHA-256>-v<baker version>-<base size>-<spread>` and looks for it in
`<Zomboid user folder>\PZExt\fonts`. Without it, it starts the bake and draws with the game's font:

1. A process of its own: the game's Java runtime (`javaw`, so no console window), headless, at most 768 MB of heap, with the
   API's jar as its class path, running `FontBaker`. Nothing of AWT runs in the game's process, and the bake's memory and
   garbage are not the game's. One runs at a time; one that runs over 10 minutes is ended. Its output goes to `bake-<pack>.log`
   beside the cache.
2. Every character the font has (the ones it would draw as its missing glyph left out) is drawn 4 times larger than the base
   size without anti-aliasing. An exact Euclidean distance transform of that picture gives each pixel's distance to the
   outline, sampled at each texel's centre and stored as `0.5 - distance / (2 * spread)` in a byte, with a spread of 8 texels.
3. The characters go into rows, tallest first, in an atlas 4096 wide at most, as tall as the next power of two.
4. It writes `font.fnt` (the game's AngelCode text format, with the font's kerning, and a `pztools` line with the sizes, which
   the game's reader passes over) and `atlas.r8` (width times height bytes, the top row first) into a new folder
   `<name>.part-<random>`, and renames that folder into place. A folder of that name is there only once complete; a folder
   without both files is not a bake.
5. It deletes the pack's other bakes (an older font file or baker), and parts more than an hour old.

Measured with the game's runtime on a 12-thread processor (the bake uses half the threads, at most 4): `latin` 1.6 s, `ko` 4.3 s, `ja` 6.6
s, `sc` 8.1 s, `tc` 9.0 s.

**Into video memory.** When the bake is there, at the start of a Lua environment, on the game's thread:

1. `atlas.r8` is read into memory outside the heap (16 MB in about 10 ms).
2. The game makes a texture of that size with one channel (`new Texture(width, height, flags, GL_RED, GL_R8)`, flags
   `0x10 | 0x20`: no copy of the picture kept and no mipmaps, clamped at the edges); its storage is made on the render thread.
3. A job on the render thread after it sends the picture (`glTexSubImage2D`) and sets the texture's swizzle so that red,
   green and blue read 1 and alpha reads the byte: the game's `sdf.frag` reads the distance from alpha, so its shader draws
   the atlas unchanged. Without OpenGL 3.3 or `ARB_texture_swizzle`, the picture is sent as an alpha texture (`GL_ALPHA8`)
   instead. The job puts back the texture binding, the unpack settings and any unpack buffer it found, and logs the time it
   took. The copy in memory is let go.
4. The game's `AngelCodeFont(fnt, texture)` reads the text file (25 ms for the Korean pack's 3,137 characters and kerning,
   130 ms the first time the reader runs) and is marked a distance-field font. Its characters are regions of the one texture.

A newer API takes the font over from the bootstrap's kept objects while the name is the same, so an update does not send it
again. From then on the API calls `AngelCodeFont.drawString(x, y, zoom, ...)` as `TextManager.DrawString` does for the game's
fonts: a quad a character, every character of a text from one texture, and nothing more a frame than the game's own
distance-field text.

**Decisions.**

| Chosen | Rejected, and why |
| --- | --- |
| Bake once in a separate process, cache under the user folder | Baking as needed in the game: AWT in the game's process, and stalls when a new character first shows. Shipping baked atlases: 4 to 32 MB each for every language. |
| One channel with a swizzle | RGBA: four times the video memory (64 MB for the Korean pack). A shader of our own: the game's shader already reads one channel, alpha. |
| The game's `AngelCodeFont` over a texture of the API's | The vanilla path (`fonts.txt` or `AngelCodeFont(fnt, png)`): pages are loaded as RGBA PNGs, which the game may also compress (`TextureID.useCompression`), and compression ruins a distance field; `fonts.txt` is read only from `media` at the game's start. |
| Base size 64 (60 for `tc`), 4 times larger to find the outline | 48: the corners of dense syllables are rounder at 400 pixels. 8 times larger: no difference to see, and twice as slow. `tc` at 64 needs 4096 x 16384 (64 MB). |
| One atlas a pack | Several pages: a texture change between characters of one text. |

**Limits.** `뷁`, `똠` and `쀏` are not in KS X 1001: a text with them is drawn in the game's font. Noto Sans has no arrows or
block elements, so a Latin-language text with `→` or `█` is too. The Traditional Chinese typeface lacks 16 simplified
characters the game's `CH` translation uses. The first start draws with the game's font until a Lua environment starts after
the bake (in practice the next world loaded); a language changed in the game keeps the pack loaded until the game restarts,
as the game's fonts do. Advances are whole texels at the base size, as in the game's fonts.

### Text at a height

A mod that draws its own windows and sizes them by the screen instead of by the font size option (for example, a scale of
the screen's height over 540, in quarters, so 1.25 at 720 lines and 2 at 1080) needs text of a height in pixels, 16, 20 or 24
times its scale, that the fonts the game has loaded are not. The game ships each language's bitmap fonts for every option but
loads only the option's; these calls load the others' as the game loads its own, and draw with the one nearest the height
([`SizedFonts`](../src/api/pzext/api/SizedFonts.java)).

| Call | Effect |
| --- | --- |
| `text.font(handle, px)` | A key (a number) for lines `px` pixels high: 1 to 1024, rounded to a whole pixel. The same height gives the same key for the whole session (the key is the height), through API updates and the game making its fonts again. Nil when the language has no font the API can read. It chooses the font and reads it now (below): ask when the window is made or laid out. |
| `text.fontHeight(handle, key)` | The height of a line to lay the text out with, the same measure as `getTextManager():getFontHeight(UIFont.Small)` is for the game's fonts: the chosen font's own line (19 for 20 pixels in Korean), or the key's height where the font is zoomed to it. Nil without a font. |
| `text.measure(handle, key, text)` | The text's width in pixels, as `getTextManager():MeasureStringX(font, text)` is: the sum of the characters' advances and kerning, the last one's width; a zoomed width rounded up. |
| `text.draw(handle, key, text, x, y, r, g, b, a)` | Draws the text with the top left of its line at `x`, `y` in screen pixels, colour parts 0 to 1. Call it from a window's `prerender` or `render`: it goes through the game's drawing in that order, inside the window's clip, where `self:drawText(text, x, y, ...)` of a game font would be with `x = self:getAbsoluteX() + x` and `y = self:getAbsoluteY() + y` (and the window's scroll, which `drawText` adds). |

Measuring and drawing a text choose the font the same way, within a frame: what `measure` gave is what `draw` covers. A wrong
argument is a Lua error naming it (a key that is not a whole number from 1 to 1024, a text that is not a string, a colour part
outside 0 to 1). The game's font steps a `\n` down by its own line at zoom 1, also when zoomed: a mod draws and measures each
line by itself, `fontHeight` apart.

**How the game names its fonts.** Read from the bytecode of Build 42 (`TextManager.Init`, `getFontFilePath`,
`Core.getOptionFontSizeReal`, `AngelCodeFont`):

- `Init` reads `media/fonts/<language>/fontsDyslexic.txt` when the dyslexic option is on; when that gives nothing,
  `media/fonts/EN/fonts.txt` and then the language's `fonts.txt` over it. Each is found through the game's file system
  (`ZomboidFileSystem.getString`), which gives a mod's file in the place of the game's: a font mod for a language is one that
  ships these files.
- The font size option picks the folder: 1 none, 2 `1x`, 3 `2x`, 4 `3x`, 5 `4x`. Auto (6) is the option
  `floor((screen height - 1080) / 132) + 1` (0 below 0) sorted into options: the smallest below 1080 lines, `1x` from 1080, `2x`
  from 1212 (1440 lines too), `3x` from 1476, `4x` from 1872 (2160 lines).
  A font's file is the first there is of `media/fonts/<language>/<folder>/<file>`, `media/fonts/<language>/<file>`, English's two,
  `media/fonts/<file>`, else `media/<file>`. The game ships the smallest option's fonts in `media/fonts` itself, not in the
  language's folder: so a 1280 x 720 screen on auto has Korean's `Small` 16 pixels high, though `1x`'s is 19.
- `getFontHeight(font)` is the font's `getLineHeight()`: the lowest bottom (`yoffset + height`) of any of its characters but the
  space, found as the text file is read. The file's own `common lineHeight` is not read; in every font the game ships the two are
  the same.

Korean's `Small`, `Medium` and `Large` by option, in pixels (the pages of 512 x 512 in brackets); English's are the same to the
`4x` `Large` (50), Chinese's and Japanese's too:

| Option | Folder | `Small` | `Medium` | `Large` |
| --- | --- | --- | --- | --- |
| 1 | `media/fonts` | 16 (6) | 23 (11) | 26 (14) |
| 2 | `1x` | 19 (8) | 29 (17) | 33 (22) |
| 3 | `2x` | 26 (14) | 33 (22) | 40 (30) |
| 4 | `3x` | 33 (22) | 40 (30) | 45 (37) |
| 5 | `4x` | 38 (28) | 45 (37) | 45 (37) |

**The choice.** The API lists the language's `Small`, `Medium` and `Large` for each of the five options as `Init` would name them
were the option that one (the same `fonts.txt`, folders and fallbacks), a file named twice once, one that is not there left
out; Korean has 13. A font's height is its text file's `common lineHeight` until it is read, then the game's `getLineHeight`.
For a height:

| Height | Drawn with |
| --- | --- |
| Up to an eighth above the tallest font (50 for Korean's 45) | The font whose line is nearest; of two as near, the smaller (it does not overflow what was laid out with it); of fonts of one height, one already read. At its own size, as the game draws its own fonts: crisp. |
| More than that | The height itself: the [embedded font](#the-embedded-font) at the height, in the game's shader, for a text it has every character of, once its atlas is in video memory; any other text in the tallest font zoomed to the height. |

For that example's 16, 20 and 24 times its scale in Korean: 1.25 gives 19, 26 and 29; 1.5 gives 16, 29 and 38 (24 is 23); 2 gives
33, 40 and 45 (48 is 45); 2.5 gives 40, 45 and the embedded font at 60; 4 gives the embedded font at 64, 80 and 96. A font the
game has loaded (the option's) is the game's own object, read no more. A distance-field font that a `fonts.txt` names for these
(`type = sdf`) is drawn zoomed to the height in the shader.

**Reading a font.** `text.font` reads the chosen font at once, on the game's thread, as `Init` reads the game's: `new
AngelCodeFont(fnt, img)` (the text file, parsed by the game), marked a distance-field font when `fonts.txt` says so. Its pages are
the game's shared textures (`Texture.getSharedTexture`), read on the game's file thread and sent by its render thread, as when
`Init` runs again after the option changes (the game draws on while they come; only at its start does it wait). Measured with the
game's runtime and its own reader, a Korean font's text file (1.4 MB, 11,821 characters) takes 23 to 37 ms, 124 ms the first time
(the file from the disk, the reader not compiled yet); English's 2 ms. Decoding the 22 pages of `1x`'s `Large` took 60 ms (190 ms
the first time) off the game's thread. A font is measured from the moment it is read; `draw` draws nothing with it until its
pages are in, a few frames later. The game's log says when each was read and when its pages were in.

| Chosen | Rejected, and why |
| --- | --- |
| Read when `text.font` first asks for a height, on the game's thread | Reading every option's fonts as a Lua environment starts: 13 Korean fonts, 300 ms or more at each load, and the video memory of all of them, for the two or three a mod uses. Reading on another thread: `AngelCodeFont` asks for its pages from the game's texture table and asset manager, which only the game's thread may touch. |
| The pages through the game's shared textures | Pages of the API's own: a page the game also loads (the option changed to that folder) would be in video memory twice. |
| Choosing by the text file's header before reading | Reading 13 files of 1.4 MB to know their heights. |

**Memory.** Only a height asked for reads a font, and only the one it is drawn with (the tallest of a height drawn in the
embedded font only when a text needs it, or at once while the embedded font cannot draw). A font read costs what the game's
own of that option costs: its pages in video memory, as shared textures (Korean: 6 to 37 pages of 512 x 512), and its
characters in the heap. The fonts read are kept in the bootstrap's kept objects, so a new Lua environment (a world loaded, the
main menu) or a newer API reads none again; when the language changes, those it can no longer choose are let go
(`AngelCodeFont.destroy`, as `Init` lets the game's go). The game's own fonts are never let go here.

**When the game makes its fonts again** (the option changed, the language, the dyslexic font or the mods, through
`Core.ResetLua` or leaving a world: the game's `Small` is another object), the next call lists the fonts again and chooses each
height again: the keys stay valid, and `fontHeight` may give another height. A mod lays its windows out again when its own scale
or `fontHeight` changes. The embedded font's choice is made by whether its atlas was in video memory as the frame began; it
changes once, as the atlas arrives just after a Lua environment starts.

**The cost.** `measure` and `draw` look the choice up by the height (an array) and compare the game's `Small` with the one the
list was made for; they allocate nothing beyond what Kahlua's call does. The embedded font's check of the characters is one pass
over the text, as the measuring is.

### Wrapping and fitting a width

Laying out text in a window (a caption in a box, a list of names in a column) needs the same two answers every frame: where a
text breaks into lines of a width, and how much of a line fits with an ellipsis. Asked a character at a time from Lua, each costs a
measure per word; `text.wrap` and `text.fit` do it in Java and keep the answer
([`TextFits`](../src/api/pzext/api/TextFits.java)).

| Call | Returns |
| --- | --- |
| `text.wrap(handle, font, text, width)` | `lines, widest`: a list of the text's lines, none wider than `width` pixels (1 to 100,000), and the width of the widest. |
| `text.fit(handle, font, text, width, ellipsis)` | `fitted, cut`: the text when it fits, else its beginning and the ellipsis (`"..."` when left out; at most 8 characters), the most characters that go with the ellipsis within `width`, and `true` when it was cut. Only the first line of a text with `\n` is taken. When not even the ellipsis fits, `fitted` is empty. |

`font` is what `text.font` returned (a font at a height, from the language's own fonts or the embedded font, measured as
`text.measure` is) or the name of one of the game's `UIFont`s (`"Small"`, `"Large"`), measured as `MeasureStringX` is. A font the API
cannot measure (a key, in a game with no fonts for the language) gives nil. `text` is a string of at most 8192 characters.

The breaking is the one `text.show` uses for its `width`: at `\n` (an empty paragraph is an empty line); before a word that follows spaces
(the spaces at the break are dropped, those inside a row stay); between two characters of the scripts written without spaces (Han,
kana, full-width forms), but not beside a space; and for a word alone wider than a row, after as many of its characters as fit, one at
least (a pair of surrogates is one character). There is no hyphenation. A text that makes more than 512 lines is an error.

The answers are kept for the last 512 calls (the owner, the font, the width, which call, the ellipsis and the text are the key), so a
mod that lays out the same text each frame measures it once. A kept answer is measured again when the game makes its fonts again (the
font size option) or the embedded font becomes ready, since the key then names another font. The list in `lines` is the kept one, the
same table every time: a mod reads it and does not change it. `handle:clear()` drops what the mod's calls kept. A call that is not
kept costs about one measure for each word; one that is, a hash lookup and the arguments.

### A mod's use

```lua
-- A quest mod: a quest done stamps its title, a search done shows what was found, a chapter burns away.
local function textApi()
    local api = PZExtAPI
    return api and api.version == 1 and api.text or nil
end

local function onQuestComplete(questName)
    local text = textApi()
    if not text then return end -- without the API, the mod's own message instead
    text.title(PZExtAPI.client("MyQuests"), {
        text = getText("IGUI_MyQuests_QuestComplete"),
        subtitle = questName,
    })
end

local function onSearchComplete(found)
    local text = textApi()
    if not text then return end
    text.title(PZExtAPI.client("MyQuests"), {
        style = "discovery",
        text = getText("IGUI_MyQuests_SearchComplete"),
        subtitle = getText("IGUI_MyQuests_ItemsFound", found),
    })
end

-- A chapter's end: the quiet style, burning away, in the mod's own colour; or any style, crumbling from the right.
local function onChapterEnd(chapterName)
    local text = textApi()
    if not text then return end
    text.title(PZExtAPI.client("MyQuests"), {
        style = "dust",
        text = chapterName,
        subtitle = getText("IGUI_MyQuests_ChapterEnd"),
        color = { 1, 0.84, 0.45 },
    })
    -- text.title(PZExtAPI.client("MyQuests"), { text = chapterName, style = "notice", leave = "dust", leaveTime = 2, dustSweep = "left" })
end

-- A text of its own: a counter at the top right that stays until the mod hides it.
local key = PZExtAPI.text.show(PZExtAPI.client("MyQuests"), {
    text = "Credits: 120", font = { "SdfBold", "Medium" }, size = 0.03, x = 0.97, y = 0.06, align = "right",
    color = { 1, 0.9, 0.6 }, shadow = true, enter = "fade", enterTime = 0.3, leave = "fade", leaveTime = 0.3,
})
-- later: PZExtAPI.text.hide(PZExtAPI.client("MyQuests"), key)
```

In Korean, `getText` gives Hangul: the styles' lists fall back to the language's fonts (`Large`, `Medium`), which have it.
The title (10% of the screen) and its line (4.5%) are taller than those fonts, so the [embedded font](#the-embedded-font) draws
them, sharp; so does a notice (3.6%, in `Medium`) and its line (2.6%, in `Small`): each is taller than the font its list falls
back to.

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
placed under one another (drawn as they are: the render thread does not run there), its backdrop come in by 1.2 s, go together
after 11.6 s, and the discovery after it waits, then shows amber in its font; `now` has the
title on the screen leave within 0.25 s and the new one follow; a Hangul title takes `Large`; a ninth waiting title makes the
oldest go; in split screen a text for every player is on both players' parts, one for a player on theirs alone, and titles queue
on each; without a player the window is used; `clear` takes one mod's texts, a world left takes its texts and a new world's stay;
wrong arguments and a 65th text are Lua errors; a drawing that fails leaves the windows, the tooltip and what follows drawn, and
draws again once it can; a newer API takes a text over at the alpha it was at, with its key, and the old functions refuse; a typed
text goes on typing from where it was under a newer API, and what the API before typing kept is shown as it was. Typing: the
characters come on at their times (the first at once, one every 0.1 s at 10 a second, the default 30), the hold starts when the
typing has ended, including a pause at the end, a hidden text leaves with what had come on, a pause holds the text back and
`{s}` returns to its speed; the cursor sits after the last character, stays on while they come, blinks 0.5 s on and 0.5 s off
while it waits and is at the start before the first; colours cut the row in runs placed by the whole row, also while they are
typed; a text is broken at spaces, at lines of its own, in a word wider than the width, between Han characters, for the zoom of
its size, for each of two screens of different widths, and again for a font made again; the typing does not move the rows;
bad markup, a speed or cursor without `"type"`, an `enterTime` with it, and a text that takes over 300 s to type are Lua errors;
a typed text with colours and rows allocates nothing once its characters are there (100,000 frames). A
frame with a stamp title and its line (12 strings) took about 0.4 us to place in the synthetic game and allocated nothing over
100,000 frames.

The embedded font (`TextsTest` with a font put in its place, and `FontsTest`): a line of 90 pixels in a list of `SdfBold` and
`Large` is drawn in it, centred, inside the shader with its edge, and so is a line of 28.8 in `Medium` (24); lines of 27 and 33
pixels in `Large` and of 21.6 in `Medium`, a text with a character it lacks,
Latin that `SdfBold` has, and a font not yet in video memory are drawn in the game's font, and the embedded font takes over
once it is; a zoom of 1.1 on `Large` (36.3 pixels) switches to it at the zoom for its own line; rows fitted to a width are
broken by its widths; drawing it allocates nothing over 100,000 frames and costs what the game's font does (193 and 216 ns a
frame to place two rows); a Korean stamp title's first frame took 65 us to place and the next 10 us. The Korean pack has all
2,350 KS X 1001 syllables and every character of `in-use/ko.txt`; each pack has the printable ASCII, Cyrillic and accented
Latin; the cache's name follows the file's bytes; the real bake, in its own process, writes a whole folder (the atlas width times
height bytes, `A` with texels inside and outside its outline, no page line, kerning), leaves no part, deletes the pack's older
bake and a dead bake's old part but not a recent part or another pack's, refuses a second bake while one runs, and a bake of a
name already there leaves it as it was. The Latin pack baked in 1.7 s.

Text at a height (`TextsTest`, Korean's fonts as the game ships them in a synthetic file system): 20 pixels is the game's own
`Small` (19) at the option 2, read no more, drawn as `DrawText` draws it where it was asked; 25 is the smallest option's `Large`
(26) from `media/fonts`, read once and not again; 30 and 31 are the game's `Medium` (29); 48 is `3x`'s `Large` (45) at its size;
60 is 60 high, the tallest zoomed to it without the embedded font, the embedded font in the shader with its edge with it, the
tallest for a character it lacks, and the switch waits for the next frame; a font loading its pages is measured but not drawn,
and drawn once they are in; when the game makes its fonts again the keys stay, 20 is read from `1x` and 33 is the game's new
`Medium`; English with the dyslexic font has its three, and Korean's fonts read are let go but not the game's; a language with
fonts in `media/fonts` alone has the closest of its two, 40 pixels the taller zoomed; without fonts there is no key, height,
width or drawing; wrong arguments are Lua errors; measuring and drawing allocate nothing over 100,000 rounds, and a measure
with its draw took about 80 ns in the synthetic game.

Dust: against the installed game (11 October 2026, Build 42, PZ Optimize's loose classes before the jar), every member `Dust`
reads was found with the types it uses, and its drawer class was defined beside `TextureDraw.GenericDrawer` in the game's class
loader, made and run (a second API finds it there and does not define it again). In the synthetic game (`DustTest`, with a
sprite renderer, frame buffers, a render thread and a picture read back of its own): the schedule is bounded, ordered along the
sweep by the sweep's share alone, the same twice and another for another seed; every cell has gone by the end of the leave; the
alpha, size, ease, glow, grey and path are as computed, the cells rise and go their sweep's way, and the swirl's wave is within 3% of a sine;
a picture is cut into the cells with ink, by lanes in the sweep's order for each of the four ways, with the starts' suffix
ordered, larger cells for a picture that would have more than the most, and none without ink. The `"dust"` title left as dust fades in (at
alpha 0.5 after 0.6 s), its picture is made once it stands still (the frame buffer on the render thread), drawn into from the
render queue in `UIFBOStyle` with the style put back, in a box of 382 by 122 pixels with the viewport moved to its corner and
put back, and read back; it holds as itself, then turns into strips of its picture that show the parts of it where they are
(their texture coordinates checked corner by corner), and at 0.4 of the leave what is whole is past the front and cells fade,
rise and glow warm (their colour at most their alpha, warm or grey); the line under it stays text until 0.3 s after the title and then crumbles from its own picture; each picture is let go
from the render queue the frame after its text has gone. A sweep from the right keeps the left whole, and with no drift no cell
leaves its place. Without the dust's drawing, and without frame buffers, the text fades (alpha 0.5 halfway) and nothing is made;
a picture that is late holds the text whole for 15% of the leave and then fades it, and one hidden before its frame buffer was made
is not made; a text hidden or cleared as it crumbles, and one whose screen changed size, lets its picture go (the last fades);
wrong dust fields are Lua errors, and a stamp title takes `leave = "dust"`; a newer API takes the fields over and lets the older
one's picture go. A title and its line crumbling (3,426 quads) took about 160 us a frame to place in the synthetic game (the game's own work for each quad
comes on top) and allocated nothing over 20,000 frames. (The `"dust"` title's own leave burns now; these are with `leave = "dust"`.)

Looks: in the synthetic game (`LooksTest`, its GL recording the arrays drawn and the program's mode): the arithmetic is the title
lab's, to the digit where it is integers (the hash) and to a millionth elsewhere (the noise, the burn map, the torch, the signal,
the impact), the numbers its own functions give in node for the same inputs; the torch flickers and dies down, the mist clears,
stays thin, thickens and goes. Each title style is drawn by the shader in the page's modes and order: the stamp's hit as its
picture, heat, streak and dust, a gleam as it stays over its picture and its line's, both weathering; the torch's light behind
the title and the title and its line lit, also as it dies down; the notice's title and line as signals; the mist behind each text
and the text through it; the burn's title and line as their picture while they stay, then burning with their ash, their maps
given to the card at the leave and let go with their pictures (the default style); the bleed's drops spreading and falling on the
title, it dripping as it stays and both drying; the sink's title and line as their picture, then sinking, the title's foot found
in its pixels; the typewriter's letters struck in turn (a longer pause after a space) and fed up; the pulse's glow and text for the
title and its line, beating and breathing out. The bleed's drops, the sink's curve, the typewriter's keys and feed, the heartbeat
and the breath out are the page's numbers too. The picture's middle is the title's place; after a draw the
attributes are popped, the program put back, the texture cache forgotten, the ring buffer's arrays set up again and the state
restored. A shader that does not compile stops the looks and the text is drawn as it is.

Not tried in the game yet: how text at a height looks (the fonts of other options next to the game's, the embedded font's
lines beside the bitmap fonts' in one window, the switch at 51 pixels), the times in the game's log for reading a font and its
pages, a font option or language changed with a window open, and a font mod's files. Also not tried: how typed text looks (the cursor's underscore in each font, the width of the rows and the places of
colour runs as the game's fonts measure them, with kerning if they have it, the Korean fonts' widths); how the titles look (the sizes, the colours, the effects' timing, a zoomed `SdfBold` and
`SdfRobertoSans` through the shader, and the copies of the outline at that zoom); the embedded font (the bake on the first start, its
log and `console.txt`'s lines for the read and the send to video memory, the swizzle in the game's OpenGL context, how sharp a
Hangul title is at 1080p and 4K, the switch at 33 pixels, the frame time when a title first shows, the video memory); split
screen; the interface's lower frame rate option; whether hiding the interface (the key that hides the HUD) hides
the text too; and the text over the main menu. Dust has not been seen in the game yet: the picture drawn and read back on a real
card (its blending, the viewport moved, with the interface drawn into its own buffer and without), how fine the cells look at 1080p
and 4K, the frame time while 4,500 cells go, a window resized or the game left while a text crumbles, and a newer API taking over
then.

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

The boot layer ([`Hooks`](../src/boot/pzext/boot/Hooks.java))
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
game's log names each missing hook and why; `PZExtAPI.hooks()` gives the same to mods, and the game
writes it to the install folder (`api.tsv`), for whoever installed the API.

The answers come from a snapshot the API makes again when something changes
([`PowerGrid`](../src/api/pzext/api/PowerGrid.java)).
A definition that changes marks it out of date: the next frame makes it again, or the first question
the game asks before then on its own thread, the one the mods' calls come on (a world's generators
make up for the hours away as they first update, which can come before the next frame). So a mod that
defines many objects in a row costs one snapshot, and a call that changes nothing costs none. The work
once a second makes it again only when what it holds changed: a definition, the area of a member
building, a network's supply. A network's load is added up with its children's once a frame, each
network once, through an index of children by parent. It holds,
for each supplied network, one bit per square of its buildings, and the same for their shell (worked
out as the network's buildings are resolved, not per question), kept in blocks of 8 by 8 squares of a
level only where a room reaches, so that buildings far apart cost no more than buildings side by side;
and the networks' object rules by square. The areas of all the networks are merged into one index
([`AreaIndex`](../src/api/pzext/api/AreaIndex.java)): the same blocks of 8 by 8 squares, each holding the networks that reach
it in the order they were defined. `haveElectricity()` is called very often (lighting, food,
sounds), so it costs a box test and a hash probe whatever the number of networks, never a walk over buildings or over networks.
An object question the game answers yes ends at once while no network has a rule for an object. With
rules, the object's square, and those of its other parts for one that covers several, are looked up
among the squares that have rules, and its sprite is read only on such a square. One the game answers
no while a network has supply is asked also whether a supplied network lights its room (a light
switch: a search of the supplied rooms' sorted ids) and whether it hangs on a wall of a supplied
building, which its sprite says (kept per sprite). For an object that no rule names, none of this
allocates. For an excluded object the API asks the game again with the networks silenced on that
thread. The water questions have their own snapshot
([`WaterGrid`](../src/api/pzext/api/WaterGrid.java)):
the areas of the networks that have water, their producers' squares and their object rules. A question
about an object that takes no pipes, which its sprite says, ends there; one about a fixture costs the
lookups of an object question. The container a fixture's water comes from is picked by going through the
producers its network draws from; within a frame the last pick holds while its container holds the same
(a draw or fill by a mod starts a new one), so a fixture the game asks about many times a frame costs one
such pass.

### What the grids go through

The networks' work once a second is done for the networks something happened to, and for no other
([`PowerGrid`](../src/api/pzext/api/PowerGrid.java), [`WaterGrid`](../src/api/pzext/api/WaterGrid.java)).
A network is worked out at a pass when its definition changed (or one it follows from: its parents, the
networks that draw from it), a hook said something happened where its consumers are, a chunk it waited
for loaded, the buildings it names were described anew, the region data was swapped and it names what
players built (or a square with no building yet), a square of its producers is loaded (the game
changes a loaded generator or container at any time, so these are read every pass), or it runs a
generator on a square that is not loaded and the world's hour changed. A network with none of these
is left alone: it costs nothing until a chunk it waits for loads, which one lookup of a flat list of
the distinct chunks every network waits for tells (at most 1024 chunks a pass). A producer's square
that is not loaded in a chunk that is, may be loaded at any time (a generator put on it), so the
network stays among those gone through and looks at it each pass. What the pass worked out is kept
(the producers' state, the supply, the loads added up over each tree of power networks and checked
only for the trees something happened in), and the snapshot the hooks read is made again only when
it holds something else. With 1000 buildings and a power and a water network each, none loaded, a
pass costs about 0.15 ms once the networks are settled, 0.4 ms a second with the frames' own noise
(the test `networks at scale` prints it; before, 12 ms a second).

## What vanilla does that mods need to know

- Player-built enclosed spaces with at least half a roof become buildings
  (`WorldRegionToMetaGrid`, user-defined `BuildingDef`), with touching levels combined into one. A
  player-built room touching or overlapping a map building is discarded, so an extension of an
  existing house belongs to no building. The overlap ignores the level: a room built on a map
  building's roof is discarded too. Its squares are still "in a room" (`IsoGridSquare.isInARoom()`
  asks the region, which is a player room) while `getRoom()` is null. The API mends the one place the
  game reads the room of such a square without asking (`IsoTree.isPlayerInsideARoom`, a
  `NullPointerException` for each tree drawn near, each frame; see the hook sites).
- Room and building ids are numbered in the order of the cell's lists (`RoomID.makeID(cell x, cell y,
  index)`, `BuildingID.makeID`), and each time a player-built building appears, changes or goes, every
  room and building of that cell is numbered again (`WorldRegionToMetaGrid.recalculateBuildingAndRoomIDs`).
  The map's own come first in the lists and keep theirs; a player-built room's id changes when a wall of
  it is mended, and when another player-built building of the cell changes. So a mod that remembers a
  player-built room remembers one of its squares, not its id, as the networks do.
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
- Rain collectors fill through their fluid container's rain catcher
  (`FluidContainerUpdateSystem.updateEntity`, each tick while it rains outside: TaintedWater, or Water
  into a container filled with clean water). While the square is not loaded the container goes on in
  a meta entity at the object's position (see [draw and fill](#draw-and-fill)). The Lua global object
  system `SRainBarrelSystem` takes none of them in Build 42 (`isValidIsoObject` is always false).

### One item of a vanilla type

A mod that hands out a vanilla item made its own (a team's blowtorch, a marked tool) keeps the vanilla type: the
game's own code asks for an item by its type (`getType() == "BlowTorch"`), its full type (`Base.BlowTorch` in a vehicle's
menu, `isPrimaryEquipped`, the build recipes' `use:Base.BlowTorch`) or its tag, and an item of another type answers
none of them. What makes it the mod's goes in its `modData`, which the game saves with the item and sends with it.
The item's sides, and what carries each:

| Side | How |
| --- | --- |
| What it is to the game | Its vanilla type, unchanged. |
| Its icon | The game's own: a string under `customInventoryIcon` in its `modData` is a texture name (`Texture.getSharedTexture`, a path such as `media/textures/Item_X.png` or a packed texture's name), and `getTexture`, which `getTex` and `getIcon` ask, answers it instead of the type's icon; one the game cannot find leaves the type's. Every place the game draws an item asks one of the three. No hook. |
| Its name | `item.nameKey`: a translation key under a declared key. Without the API a mod names it with `setName` and `setCustomName(true)`, in the language of the moment, as if a player had. |
| What it holds of the mod's | Its own keys (`uses.modDataKey`, `carry.efficiencyKey`, ...). |
| A recipe that remakes it (a refill) | `craft.carryKeys`, which has to list every key above the mod uses (the icon's and the name's too). |
| Its model on the floor and in the hands | The type's. |

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

On 7 October 2026 the built `buildings` area was called from the debug Lua console of a game with the API loaded
(then still by PZ Tools' startup loader):

| Check | Result |
| --- | --- |
| The gas station (map building), standing in its shop | Key `3570,10891,0`, not player-built. `objects`: 47, all squares loaded: fridges (0.13, a fridge and a freezer), stoves, radios, a television, a washer (power and water), a dryer, sinks, bathroom fixtures and light switches, each in the room it lights. Appliances that are off report 0; one switch that was on reported 0.002. `near` (5 squares): 9. |
| The player-built shack | Key `3578,10907,0`, player-built, its one room unnamed (`""`). No objects; `near` (5 squares): 2. |
| A square's object list | `PZArrayList` has no iterator (`UnsupportedOperationException`); it is read by index. |

On 7 October 2026 a power network was defined from the debug Lua console of a game with the API loaded
(sandbox generator fuel rate 0.1, no grid power): the gas station as its building, one
generator outside it as its producer.

| Check | Result |
| --- | --- |
| The hooks going in | No `[PZExt]` report in the game's log: every power hook found its method. |
| The generator switched on | The network supplied; load 0.652 (five fridges at 0.13, one lamp at 0.002 on the upper level); the generator's consumption 0.672, which the game shows as 0.0672 after its sandbox fuel rate. The square beside the generator had no power. |
| One fridge excluded | Load 0.522; that fridge unpowered, the others powered on both levels. |
| One part of a two-square fridge excluded | Both parts unpowered; load 0.262. |
| The generator switched off | The building's lights and fridges went off. |
| The room light and food hooks (game started again) | No `[PZExt]` report: both found their question in `LightingJNI.checkLights` and `Food.updateAge`. |
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
throwaway Lua script loaded from the debug console. No `[PZExt]` report: the water hooks found
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
and `PZExtAPI.hooks()` in the debug console gave 15 of 15 applied. With one hook's line changed to a
failure by hand, PZ Tools' next round logged a warning naming `IsoGenerator.update`.

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
- Whether `buildings.at` should report an extension room that vanilla discards, and as what
  (`buildings.attached` reports them beside it, without changing `at`).
- The name of an event that says the API appeared or went away.

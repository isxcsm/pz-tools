# Building Utilities

A Project Zomboid Build 42 mod. A utility panel put inside a building powers and waters the whole building (or the
rooms it is zoned to) from supplies outside it: generators run one after another, rain barrels and tanks used as one
store, solar panels, battery racks of car batteries, and water pumps, sprinklers and filters. Water runs down from
the stores to the floors below them; booster pumps lift it up to ten floors above their own, and chain. Panels in other
buildings, or on other floors of a tall one, can take their supply from a main panel, and a supply wired to such a
sub-panel is its main panel's through it. A panel's zone reaches a few floors up and down from its own. A panel has
four tiers; each carries more load, reaches farther (and more floors) and adds something (timers and sub-panels, a
charge controller, shedding devices before the breaker trips).
A room the player builds against a map building (an extension, which the game gives to no building) counts as part of
that building: its devices are inside, connected by default, with no line to lay.

The design, in Korean, is [DESIGN.md](DESIGN.md).

## Requirements

- PZ Extension API installed. The mod runs its networks through it (`PZExtAPI`). Without it a panel cannot be installed and the panels already placed do
  nothing; their menus say why.
- Water needs the API's plumbing hooks in the game, and the "pipes do not purify" risk option also its purification
  hooks. When they are missing the panel's window says water is unavailable, or the filter says why it rests.
- Multiplayer is not supported or tested.

## Options

Sandbox options. The "Building Utilities: Features" page turns parts of the mod on or off, each on by default: power,
water, and within them solar panels, battery racks, the charge controller, water pumps, sprinklers, water filters and
booster pumps (a part needs the one it belongs to; a pump needs both water and power). A part that is off cannot be made or put
down, its menus and window rows are hidden, and what of it is already placed does nothing (a utility that is off gives
its generators and tanks back to the game) but can still be taken down; its saved setup comes back when it is on
again. The "Building Utilities" page: ranges for supplies, outside devices and sub-panels, the floors a zone
reaches, the floors a booster pump lifts, and how much each tier adds; whether lines cost materials, the tiles per wire or pipe, the tiles of line a
floor up or down adds and the share given back; overload and the
load each tier carries; line loss per wire; the low fuel warning; Electricity experience; solar output, snow on
panels, battery capacity, charge efficiency, wear, the cold lock and the drain of worn batteries; water only from
above. Risk options (`Risk...`: pipes freeze, pipes do not purify) are off by default. Each option's tooltip in the
game says what it does.

The game's own "Generator Working in Exterior" option (`AllowExteriorGenerator`) is followed: with it off, a panel gives
no power to devices outside the building (an extension counts as inside), and the connect menu says why.

The plan's supply lines (flowing dots, lines alone, or none) are each player's own choice, switched on the plan and
kept in the game's mod options. Supply from another floor shows on the plan: on the producers' floor their lines run
to a riser that names the box's floor, by the box a badge per floor tells how many come from there, and the floor
strip marks floors with producers.

## Repository

- `BuildingUtilities/`: the mod (`42/media/lua/{shared,client,server}/BuildingUtilities`, scripts, sandbox options,
  translations in EN and KO).
- `tests/ingame/`: checks run from the game's debug console ([README](tests/ingame/README.md)).
- `tests/unit/`: Lua unit tests on the game's Kahlua, the game and the PZ Extension API stubbed (`harness.lua`). From the
  repository root: `java -cp <ProjectZomboid>/projectzomboid.jar tools/LuaTest.java [file name filter]` (a JDK, not the
  game's runtime).
- `tools/`: `LuaTest.java` (runs `tests/unit`), `check_translations.py` (texts against the code, the options and the scripts), `room_names.py` (room
  names of the game's maps against the translations), `tile_art.py` (the mod's own sprite sheet: water units, the utility panel console and snow on panels).

The solar panel and battery rack art comes from Immersive Solar Arrays (Apache-2.0); see
`BuildingUtilities/common/licenses/ImmersiveSolarArrays/`.

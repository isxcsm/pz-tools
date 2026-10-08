# Building Utilities

A Project Zomboid Build 42 mod. A utility panel put inside a building powers and waters the whole building (or the
rooms it is zoned to) from supplies outside it: generators run one after another, rain barrels and tanks used as one
store, solar panels, battery racks of car batteries, and water pumps, sprinklers and filters. Panels in other
buildings, or on other floors of a tall one, can take their supply from a main panel, and a supply wired to such a
sub-panel is its main panel's through it. A panel's zone reaches a few floors up and down from its own. A panel has
four tiers; each carries more load, reaches farther (and more floors) and adds something (timers and sub-panels, a
charge controller, shedding devices before the breaker trips).

The design, in Korean, is [DESIGN.md](DESIGN.md).

## Requirements

- PZ Tools installed, with the game started by its startup loader. The mod runs its networks through
  the PZ Tools extension API (`PZToolsAPI`). Without it a panel cannot be installed and the panels already placed do
  nothing; their menus say why.
- Water needs the API's plumbing hooks in the game, and the "pipes do not purify" risk option also its purification
  hooks. When they are missing the panel's window says water is unavailable, or the filter says why it rests.
- Multiplayer is not supported or tested.

## Options

Sandbox options. The "Building Utilities: Features" page turns parts of the mod on or off, each on by default: power,
water, and within them solar panels, battery racks, the charge controller, water pumps, sprinklers and water filters
(a part needs the one it belongs to; a pump needs both water and power). A part that is off cannot be made or put
down, its menus and window rows are hidden, and what of it is already placed does nothing (a utility that is off gives
its generators and tanks back to the game) but can still be taken down; its saved setup comes back when it is on
again. The "Building Utilities" page: ranges for supplies, outside devices and sub-panels, the floors a zone
reaches, and how much each tier adds; whether lines cost materials, the tiles per wire or pipe, the tiles of line a
floor up or down adds and the share given back; overload and the
load each tier carries; line loss per wire; the low fuel warning; Electricity experience; solar output, snow on
panels, battery capacity, charge efficiency, wear, the cold lock and the drain of worn batteries; water only from
above. Risk options (`Risk...`: pipes freeze, pipes do not purify) are off by default. Each option's tooltip in the
game says what it does.

The plan's supply lines (flowing dots, lines alone, or none) are each player's own choice, switched on the plan and
kept in the game's mod options. Supply from another floor shows on the plan: on the producers' floor their lines run
to a riser that names the box's floor, by the box a badge per floor tells how many come from there, and the floor
strip marks floors with producers.

## Repository

- `BuildingUtilities/`: the mod (`42/media/lua/{shared,client,server}/BuildingUtilities`, scripts, sandbox options,
  translations in EN and KO).
- `tests/ingame/`: checks run from the game's debug console ([README](tests/ingame/README.md)).
- `tools/`: `check_translations.py` (texts against the code, the options and the scripts), `room_names.py` (room
  names of the game's maps against the translations), `tile_art.py` (the mod's own sprite sheet: water units, the utility panel console and snow on panels).

The solar panel and battery rack art comes from Immersive Solar Arrays (Apache-2.0); see
`BuildingUtilities/common/licenses/ImmersiveSolarArrays/`.

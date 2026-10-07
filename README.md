# Building Utilities

A Project Zomboid Build 42 mod. A utility panel put inside a building powers and waters the whole building (or the
rooms it is zoned to) from supplies outside it: generators run one after another, rain barrels and tanks used as one
store, solar panels, battery racks of car batteries, and water pumps, sprinklers and filters. Panels in other
buildings can take their supply from a main panel. A panel has four tiers; each carries more load, reaches farther
and adds something (timers and sub-panels, a charge controller, shedding devices before the breaker trips).

The design, in Korean, is [DESIGN.md](DESIGN.md).

## Requirements

- PZ Tools installed, with the game started by its startup loader. The mod runs its networks through
  the PZ Tools extension API (`PZToolsAPI`). Without it a panel cannot be installed and the panels already placed do
  nothing; their menus say why.
- Water needs the API's plumbing hooks in the game, and the "pipes do not purify" risk option also its purification
  hooks. When they are missing the panel's window says water is unavailable, or the filter says why it rests.
- Multiplayer is not supported or tested.

## Options

Sandbox options, on the "Building Utilities" page: ranges for supplies, outside devices and sub-panels and how much
each tier adds; whether lines cost materials, the tiles per wire or pipe and the share given back; overload and the
load each tier carries; line loss per wire; the low fuel warning; Electricity experience; solar output, snow on
panels, battery capacity, charge efficiency, wear, the cold lock and the drain of worn batteries; water only from
above. Risk options (`Risk...`: pipes freeze, pipes do not purify) are off by default. Each option's tooltip in the
game says what it does.

## Repository

- `BuildingUtilities/`: the mod (`42/media/lua/{shared,client,server}/BuildingUtilities`, scripts, sandbox options,
  translations in EN and KO).
- `tests/ingame/`: checks run from the game's debug console ([README](tests/ingame/README.md)).
- `tools/`: `check_translations.py` (texts against the code, the options and the scripts), `room_names.py` (room
  names of the game's maps against the translations), `water_art.py` (the water units' sprite sheet).

The solar panel and battery rack art comes from Immersive Solar Arrays (Apache-2.0); see
`BuildingUtilities/common/licenses/ImmersiveSolarArrays/`.

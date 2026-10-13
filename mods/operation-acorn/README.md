# Operation Acorn

A Project Zomboid Build 42 mod for players who know the map by heart. A research team on the radio trades with you for
what you gather: you send it out by helicopter, earn credits and the team's trust, buy supplies and upgrade serums, and
grow three upgrade trees. Gathering the city into your base keeps paying long after you have everything you need.

The design, in Korean, is [DESIGN.md](DESIGN.md); how the code is split, [ARCHITECTURE.md](ARCHITECTURE.md).

## Requirements

- [PZ Extension API](../../extension-api) installed.
- PZ UI Kit (`PZUIKit`, [pz-ui-kit](../pz-ui-kit)), which its windows are drawn with.
- Multiplayer is not supported or tested.

## Folders

- `OperationAcorn/`: the mod.
- `OperationAcornDev/`: its developer tools, a section of the PZ Extension API Dev window (F8) and a command channel
  for test saves. Never published; works only in debug mode.
- `tools/`: the art, data and check scripts; `tests/`: the unit tests.

# Mods

Project Zomboid Build 42 mods made alongside PZ Tools. Each folder keeps its own README, design notes, tools and tests;
none of them needs PZ Tools.

| Folder | Mod | Needs |
| --- | --- | --- |
| [pz-ui-kit](pz-ui-kit) | PZ UI Kit (`PZUIKit`): what the other mods draw their windows with | - |
| [building-utilities](building-utilities) | Building Utilities (`BuildingUtilities`): a utility panel powers and waters a whole building | PZ UI Kit, PZ Extension API |
| [operation-acorn](operation-acorn) | Operation Acorn (`OperationAcorn`): a research team on the radio trades for what you gather | PZ UI Kit, PZ Extension API |

The [PZ Extension API](../extension-api) they run on has its own folder at the top, with its own build and installer.

## Developer mods

Each mod with developer tools keeps them beside it as a mod of its own, never published and working only in debug
mode. They all add a section to one window (F8) that PZ Extension API Dev opens:

- `PZExtDev` in [extension-api/dev](../extension-api/dev): the window, and the game's environment (time, weather, the
  character, zombies).
- `BuildingUtilitiesDev` in [building-utilities](building-utilities).
- `OperationAcornDev` in [operation-acorn](operation-acorn).

To play or test a mod from here, link its folder (and its developer mod's, if wanted) into `Zomboid\mods` with a
junction, e.g. `mklink /J "%USERPROFILE%\Zomboid\mods\BuildingUtilities" mods\building-utilities\BuildingUtilities`.

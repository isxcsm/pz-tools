# Mods

Project Zomboid Build 42 mods made alongside PZ Tools. Each folder keeps its own README, design notes, tools and tests
(the tools they share are in [tools](#shared-tools)); none of them needs PZ Tools.

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

## Shared tools

[tools](tools) holds what every mod (and the PZ Extension API's in-game checks) runs with, each run from a mod's
folder; the Java ones with the JDK in `artifacts/toolchains` (25), LuaTest and LuaCheck with the game's jar
(`java -cp <ProjectZomboid>/projectzomboid.jar ../tools/LuaTest.java`):

- `LuaTest.java`: the mod's `tests/unit` (and `tests/bench` with `"" bench`) on the game's own Kahlua.
- `LuaCheck.java`: compiles the mod's Lua as the game does in debug mode, and flags a local used before its
  declaration and a Lua base name the game lacks.
- `PzJar.java`: looks things up in the game's classes without the game (`java ../tools/PzJar.java callers
  'UIManager\.getFadeAlpha'`): members, who calls a method or uses a field, what a method calls, which methods hold a
  string (where a log line comes from), a class through javap. Its index is built once per game version (seconds).
- `pzdev.py`: drives the running game (started with `-debug` and a test save) through Operation Acorn Dev's command
  channel: runs Lua and in-game checks, takes pictures, reloads, restarts; also records it with Flight Recorder
  (`profile`) and reads the game's logs (`log gaps`, `log compare`). `python ../tools/pzdev.py` for its commands.

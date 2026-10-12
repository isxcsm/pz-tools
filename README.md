# PZ Extension API

Java hooks for Project Zomboid (Build 42) that Lua mods use through one global table, `PZExtAPI`: facts the game knows
(buildings, rooms, containers, zombies near a point, the helicopter), mechanisms too slow or too far-reaching for Lua
(power and water networks, formula points on the game's own numbers, moodles, large sharp text, timers, chunk
watches), all without game content of its own. A mod that uses it states what it wants; the API answers the game's
questions in Java.

- [Design](docs/design.md): every area, its calls and the game facts behind it.
- [Loader and install](docs/loader.md): how the game loads the API without a changed game file.

It stands alone: it needs no other program running and no launch option. Tools that help players install mods may
install it by running its installer.

## Build and test

Needs a Java 25 JDK and Visual Studio's x64 C++ tools (for the loader's native library).

```
./build.ps1 -JdkPath <jdk>     # out/release: pzext-install.jar, pzext-boot.jar, pzext-api.jar, pzext-loader.dll, fonts
./test.ps1 -JdkPath <jdk>      # the API against a synthetic game, and the install and loader
```

## Install

```
"<game>\jre64\bin\java.exe" -jar out/release/pzext-install.jar install "<game>"
```

See [loader and install](docs/loader.md#installing) for status, uninstall and what is written where.

## For mod authors

```lua
Events.OnGameStart.Add(function()
    local api = PZExtAPI
    if type(api) ~= "table" or api.version ~= 1 then
        -- not installed, or a version this mod was not written for: change nothing, say why
        return
    end
    local handle = api.client("MyMod")
    -- api.buildings, api.networks, api.formulas, api.text, api.moodles, ...
end)
```

`dev/PZExtDev` is a dev mod, never published, that works only in debug mode: a debug window (F8) with the game's
environment (time, weather, the character, zombies) and pages that read and try each area of the API. A mod's own dev
mod adds its section to the same window with `PZExtDev.section(...)` (see `dev/PZExtDev/42/media/lua/client/PZExtDev/Panel.lua`).
Its texts come from `dev/tools/strings.py`.

## License

MIT; the embedded fonts are Noto Sans under the SIL Open Font License (fonts/OFL.txt).

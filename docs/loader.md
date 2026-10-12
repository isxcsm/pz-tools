# PZ Extension API: loader and install

[Back to the README](../README.md)

The API runs inside the game's own Java process. Nothing of the game is changed: the install adds files of its own to
the game's folder and keeps everything else in an install folder of its own. The API needs no other program, no app
running beside the game and no launch option.

## How the game loads it

1. **The install** ([`Install`](../src/install/pzext/install/Install.java)) writes, in the game's folder (which the
   game's launcher puts first on the class path):
   - `pzext/loader/Loader.class` and `pzext/loader/BootProvider.class`;
   - `pzext/loader/install.properties`, the install folder's path;
   - a line `pzext.loader.BootProvider` in `META-INF/services/java.nio.file.spi.FileSystemProvider`, beside any lines
     of other tools.

   The rest goes into the install folder, `%ProgramData%\PZExtAPI\s-<account>` (one per Windows account, open to
   that account and the administrators alone): a version folder `api-<digest>` with the boot layer, the API, the
   native library and the fonts, and `current`, which names the version folder the next game start loads with the
   SHA-256 of its boot jar.
2. **At game start** the JDK lists the installed file system providers the first time anything asks for one, and
   creates each provider named in a services file on the class path. The game asks early in
   `MainScreenState.main`, when it zips its last logs. Creating
   [`BootProvider`](../src/loader/pzext/loader/BootProvider.java) starts the
   [`Loader`](../src/loader/pzext/loader/Loader.java). The provider serves no files; its scheme, `pzext-loader`, is its
   own.
3. **The loader** checks the install (the version folder named by `current`, its files there, the boot jar's
   digest), loads the native library [`pzext-loader.dll`](../src/native/loader.cpp), which loads the game JRE's
   `instrument.dll` and calls its `Agent_OnAttach` on the current thread with the boot jar: in-process what an agent
   attach does, so the game needs no `-javaagent` option and no attach from outside. It writes one line to
   `loader.log` in the install folder.
4. **The boot layer** ([`Boot`](../src/boot/pzext/boot/Boot.java)) gets an `Instrumentation`. It puts the API's hooks
   into the game's classes as they load ([`Hooks`](../src/boot/pzext/boot/Hooks.java)) and one call at the start of
   `GameWindow.logic()` for the API's per-frame work ([`FrameHook`](../src/boot/pzext/boot/FrameHook.java)). When the
   game loads `GameWindow`, a thread of its own loads the API from `pzext-api.jar`
   ([`Host`](../src/boot/pzext/boot/Host.java)), which hands the hooks their handlers; the hook at the end of
   `LuaManager.init()` sets `PZExtAPI` into each Lua environment. About once a second the host looks at the jar again
   (a changed one loads and takes over in the running game) and writes `api.tsv` in the install folder: which hooks
   this game has.

The boot layer is loaded once per process and never replaced; a change to it waits for the game's next start. The API's
jar names the boot layer it was built for (`PZExt-Boot-Api` in its manifest); one built for another is not loaded.

## What must not break the game

The JDK creates the providers inside its own lock, with a flag that marks the list as loading. A provider that cannot
be created leaves the flag set, and every later request for a provider (the game's log zip among them) fails for the
rest of the run. So:

- `BootProvider` and `Loader` use `java.base` alone and catch everything. A missing or broken loader class is a
  `NoClassDefFoundError` inside that `try`.
- The install writes the classes before the service line, and uninstall removes the line before the classes, so the
  line never names a class that is not there.
- Neither the loader nor the boot layer asks for a file system provider while it runs, and neither waits for another
  thread that might.
- The loader runs once per process, however many times something lists the providers.
- A broken install (a missing file, a digest that does not match) leaves one line in `loader.log` and a vanilla game.
- A hook that does not fit the game's method (another mod changed it, a game update did) is left out on its own, and
  that question gets the game's answer ([design](design.md#how-the-game-is-answered)).

## Installing

From a release folder (what `build.ps1` makes), with a Java 25 runtime (the game's own `jre64` will do), while the game
is closed, with the rights to write the game's folder:

```
"<game>\jre64\bin\java.exe" -jar pzext-install.jar install "<game>"
"<game>\jre64\bin\java.exe" -jar pzext-install.jar status "<game>"
"<game>\jre64\bin\java.exe" -jar pzext-install.jar uninstall "<game>"
```

Each prints one line: `PZEXT-INSTALL` and `installed <version folder> <install folder>`, `not-installed`, `reverted`
(installed, but the game's folder lost part of the entry; install again) or `uninstalled`; or `PZEXT-INSTALL-FAILED`,
a code and a message, with exit code 1. Installing a newer release is installing again: it copies a new version folder
and points `current` at it; a game that runs keeps the old one until it exits. Another program (a mod manager, a
launcher) installs the API by running the same commands; `PZEXT_GAME_ACCOUNT` names the account the game runs as when
the install runs as another (elevated by another administrator).

## Other tools in the same game

Other tools that hook the game the same way (their own provider line, their own agent) live beside the API: each has
its own line in the services file and its own transformers, and a class two tools change gets both changes (each
transformer stays registered, so a later retransformation by one runs the other's again). Two tools must not hook the
same game method for the same purpose; the API owns the questions it answers.

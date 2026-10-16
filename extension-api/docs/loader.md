# PZ Extension API: loader and install

[Back to the README](../README.md)

The API runs inside the game's own Java process. Nothing of the game is changed but one entry in its launcher file's
class path (below): the install adds files of its own to the game's folder and keeps everything else in an install folder of
its own. The API needs no other program, no app running beside the game and no launch option.

## How the game loads it

1. **The install** ([`Install`](../src/install/pzext/install/Install.java)) writes, in the game's folder (which the
   game's launcher puts first on the class path):
   - `pzext/loader/Loader.class`, `Launcher.class`, `Trust.class` and `BootProvider.class`;
   - `pzext/loader/install.properties`, the loader's settings: the install folder's path, the version folder to load and
     the SHA-256 of every file in it (below);
   - a line `pzext.loader.BootProvider` in `META-INF/services/java.nio.file.spi.FileSystemProvider`, beside any lines
     of other tools;
   - `pzext/pzext-launch.jar`, the same loader again under another package name (`pzext.launch`), with a services list
     of its own and settings of its own, and
   - one entry in the class path list of the launcher file, `ProjectZomboid64.json`: `"pzext/pzext-launch.jar"`, after
     the game's jar. The file is edited as text, that one element added (or removed) and every other byte left as it
     was, and written whole or not at all (a temporary file moved over it). Other tools' entries stay.

   The jar is there because tools that rewrite the launcher file do not keep the game's folder on the class path. PZ
   Optimization's AOT step makes the list `pzopt/aot/pzopt.jar`, then the entries after the game's own: it drops `.`, so
   the loose files above are no longer found, and copies the loose class files of other installs into its own jar without
   their services lists. An entry after the game's jar is kept, and its jar has the services list the JDK looks for, so
   the loader starts from it. The classes it carries have another package name so that the copies pzopt baked can never
   shadow them. Both copies may be created in one process (a launcher file with `.` and our entry); the first to find its
   settings boots, and a property of the process, `pzext.loader.started`, keeps the other from booting again.

   The rest goes into the install folder, `%ProgramData%\PZExtAPI\s-<account>` (one per Windows account): a version
   folder `api-<digest>` with the boot layer, the API, the native library and the fonts, and the two files the game
   writes there, `loader.log` and `api.tsv`.

   **What the loader trusts.** The game's folder is the trust root: the install wrote the settings (loose, and again
   in the launch jar) there, and they say which version folder to load (`version=`) and the SHA-256 of each file in it
   (`sha256.<file>=`). The loader loads nothing from the install folder that the settings do not vouch for, and it
   does not trust the install folder itself:
   - The install folder, its parent `PZExtAPI` and the version folder must be owned by the machine's administrators
     and writable by no one else ([`Trust`](../src/loader/pzext/loader/Trust.java)). The administrators are not
     named (the names depend on the language of Windows): they are the owner of `%SystemRoot%` and the accounts its
     access list lets write there (the system, the administrators, the installer service). Whoever may change the
     Windows folder can already run code as anyone. A folder that is a link (symbolic or junction) is no install
     folder. (ProgramData itself is not checked: its list lets every user create folders, and the folders made there
     are what the check is for.)
   - Each file the settings list is read whole and hashed; a file that is missing or differs (the boot jar, the API's
     jar, the native library, a font) is a refusal. The boot layer checks the API's jar against its digest again when
     it loads it, from the bytes it loads, so the file is not swapped between the loader's look and the load.
   - A refusal is one line in `loader.log` (it never writes through a link) and a vanilla game.

   The install makes the folders so: `PZExtAPI` and the install folder are created with an access list of the
   administrators (full control) and the player's account (and the Users group, for `PZExtAPI`: read and run), which
   is why the install runs elevated. A pre-existing folder is not trusted by name. One an administrator made whose
   list lets others write gets the right list again; one another account made (any user can create a folder in
   ProgramData, and then owns it), a link, or a file in its place is moved aside as `<name>.untrusted-<time>` (never
   entered, never deleted) and made again, and when it cannot be moved the install is refused (`unsafe-folder`). An
   install that would make files its owner could not be trusted with (the process is not elevated) is refused
   (`not-administrator`). `loader.log` and `api.tsv` are made by the install and writable by the player's account
   alone; the game updates them in place, since the folder itself is not writable by the player.
2. **At game start** the JDK lists the installed file system providers the first time anything asks for one, and
   creates each provider named in a services file on the class path. The game asks early in
   `MainScreenState.main`, when it zips its last logs. Creating
   [`BootProvider`](../src/loader/pzext/loader/BootProvider.java) starts the
   [`Loader`](../src/loader/pzext/loader/Loader.java). The provider serves no files; its scheme, `pzext-loader`, is its
   own.
3. **The loader** (whichever copy starts first) checks the install (the folders and each file's digest against its settings, above), loads the native library [`pzext-loader.dll`](../src/native/loader.cpp), which loads the game JRE's
   `instrument.dll` and calls its `Agent_OnAttach` on the current thread with the boot jar: in-process what an agent
   attach does, so the game needs no `-javaagent` option and no attach from outside. It writes one line to
   `loader.log` in the install folder. Last, it looks at the launcher file: when the jar is there and the file's class path
   list lacks the jar's entry (Steam verified the game's files, or an update brought the plain file back, and pzopt has not
   rewritten it since), the entry is added again, for the next start, and a line in the log says so. A launcher file it cannot
   read (no class path list of plain strings) is left alone and logged. Nothing in this step can stop the game.
4. **The boot layer** ([`Boot`](../src/boot/pzext/boot/Boot.java)) gets an `Instrumentation`. It puts the API's hooks
   into the game's classes as they load ([`Hooks`](../src/boot/pzext/boot/Hooks.java)) and one call at the start of
   `GameWindow.logic()` for the API's per-frame work ([`FrameHook`](../src/boot/pzext/boot/FrameHook.java)). When the
   game loads `GameWindow`, a thread of its own loads the API from `pzext-api.jar`
   ([`Host`](../src/boot/pzext/boot/Host.java)), which hands the hooks their handlers; the hook at the end of
   `LuaManager.init()` sets `PZExtAPI` into each Lua environment. The jar's bytes must have the digest the install gave the loader. About once
   a second the host writes `api.tsv` in the install folder: which hooks this game has. The jar is loaded once and not
   looked at again; a developer building the API sets `PZEXT_DEV_RELOAD=1` in the game's environment, and the host then
   looks at the jar every second and a changed one loads without the digest check and takes over in the running game
   (the next game start refuses it again, unless it was installed).

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
- A broken or changed install (a missing file, a digest that does not match, a folder another account may write) leaves
  one line in `loader.log` and a vanilla game.
- The launcher file is read and written as text with `java.base` alone, only to add the one entry when it is missing, and a
  fault in doing so (a file that is read-only, in use, or not what it expects) is logged once and ignored.
- A hook that does not fit the game's method (another mod changed it, a game update did) is left out on its own, and
  that question gets the game's answer ([design](design.md#how-the-game-is-answered)).

## Installing

From a release folder (what `build.ps1` makes), with a Java 25 runtime (the game's own `jre64` will do), while the game
is closed, with the rights to write the game's folder, and elevated (an administrator's process: the install folder is
the administrators' alone):

```
"<game>\jre64\bin\java.exe" -jar pzext-install.jar install "<game>"
"<game>\jre64\bin\java.exe" -jar pzext-install.jar status "<game>"
"<game>\jre64\bin\java.exe" -jar pzext-install.jar uninstall "<game>"
```

Each prints one line: `PZEXT-INSTALL` and `installed <version folder> <install folder> launcher=<state>`, `not-installed`,
`reverted` (installed, but the game's folder lost part of the entry; install again) or `uninstalled`; or
`PZEXT-INSTALL-FAILED`, a code and a message, with exit code 1. `<state>` says what the launcher file holds: `listed` (the
jar's entry is in its class path list), `absent` (it is not: the loader adds it at the next game start, or install again),
`none` (no launcher file) or `unreadable` (a file whose class path list this cannot edit; the loose files serve where the
game's folder is still on the class path). Installing a newer release is installing again: it copies a new version folder, writes the settings that name it and
give its digests, and removes the older version folders. The settings change with the version, so the install waits for
a game that runs (`game-running`: the launch jar is open).

Uninstalling removes the jar first (a game that runs has it open, so the uninstall stops there with `game-running` before
anything else changes), then the launcher file's entry, the service line and the loose files; other tools' entries and
lines stay. Another program (a mod manager, a
launcher) installs the API by running the same commands; `PZEXT_GAME_ACCOUNT` names the account the game runs as when
the install runs as another (elevated by another administrator).

## Other tools in the same game

Other tools that hook the game the same way (their own provider line, their own agent) live beside the API: each has
its own line in the services file and its own transformers, and a class two tools change gets both changes (each
transformer stays registered, so a later retransformation by one runs the other's again). Two tools must not hook the
same game method for the same purpose; the API owns the questions it answers.

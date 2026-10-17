# PZ Extension API: loader and install

[Back to the README](../README.md)

The API runs inside the game's own Java process. Nothing of the game is changed but one entry in its launcher file's
class path (below): the install adds files of its own to the game's folder and keeps everything else in an install folder of
its own. The API needs no other program, no app running beside the game and no launch option.

## How the game loads it

1. **The install** ([`Install`](../src/install/pzext/install/Install.java)) writes, in the game's folder (which the
   game's launcher puts first on the class path):
   - `pzext/pzext-launch.jar`, the loader ([`Loader`](../src/loader/pzext/launch/Loader.java),
     [`Launcher`](../src/loader/pzext/launch/Launcher.java), [`Trust`](../src/loader/pzext/launch/Trust.java) and a
     provider, package `pzext.launch`) with a services list of its own and the settings of the install: the install
     folder's path, the version folder to load and the SHA-256 of every file in it (below);
   - one entry in the class path list of the launcher file, `ProjectZomboid64.json`: `"pzext/pzext-launch.jar"`, after
     the game's jar. The file is edited as text, that one element added (or removed) and every other byte left as it
     was, and written whole or not at all (a temporary file moved over it). Other tools' entries stay;
   - the shim, the only loose class files: `pzext/loader/BootProvider.class` and `BootProvider$Jar.class` ([source](../src/shim/pzext/loader/BootProvider.java)),
     with `pzext/loader/install.properties` (the install folder's path, for one log line, and the SHA-256 of the jar) and a
     line `pzext.loader.BootProvider` in `META-INF/services/java.nio.file.spi.FileSystemProvider`, beside any lines of
     other tools. Install and uninstall also remove the loose `Loader`, `Launcher` and `Trust` classes that installs
     before the shim put there.

   **The jar is where the loader lives, and the shim is frozen.** Tools that rewrite the launcher file do not keep the
   game's folder on the class path. PZ Optimization's AOT step makes the list `pzopt/aot/pzopt.jar`, then the entries
   after the game's own: it drops `.`, so loose files are no longer found, and copies the loose class files of other
   installs into its own jar (without their services lists) and rebuilds that jar whenever the set or the bytes of those
   files differ. That rebuild cannot happen while a game runs (the JVM holds the jar open), so a loose loader that changed
   with every release left PZ Optimization failing at every launch, stuck in its recording phase. Hence:
   - **Nothing but the shim is loose, and the shim never changes.** Its two classes are byte-identical in every release
     (the build compiles them with fixed flags, `--release 25 -g:none`, no debug information; a test pins the SHA-256 of
     each, so changing the shim, or how it is built, is a deliberate decision with a new pin). The install writes a file
     only when its bytes differ and leaves the rest untouched, modification time included, so after the first install
     the loose set that PZ Optimization sees is fixed. Everything that changes between releases is in the jar, which
     PZ Optimization does not copy.
   - **The jar is found by the class path.** The launcher file lists it, and its services list names its provider. PZ
     Optimization's list keeps an entry after the game's jar, so the jar's provider starts the loader there; the shim is
     not involved (a copy of the shim baked into PZ Optimization's jar is not in the game's folder, so it does nothing).
   - **The shim is the fallback.** Where the game's folder is still on the class path and the jar is not listed (Steam
     verified the game's files and brought the plain launcher file back), the JDK creates the shim from the folder's
     services list. It reads the jar (`pzext/pzext-launch.jar`, located from its own class file), checks its SHA-256 against
     the `sha256` the install wrote beside it, and only then defines the jar's classes, from the bytes it hashed, in a class
     loader of its own and calls `pzext.launch.Loader.start()`. That keeps the one boot a process, does the checks of the
     install folder below and lists the jar in the launcher file again. A missing jar, a jar that is not the installed one,
     missing settings or anything thrown leave a vanilla game and one line in `loader.log` (when the install folder is
     known); nothing is ever thrown out of the provider. When the jar is on the class path too, its own provider starts
     the loader and the shim does nothing.
   - **One boot a process.** A property of the process, `pzext.loader.started`, set by the loader, keeps a second
     provider (two are created when the folder and the jar are both on the class path) from booting again. Each tool
     has a guard of its own, so PZ Tools' startup loader and this one both boot.

   The rest goes into the install folder, `%ProgramData%\PZExtAPI\s-<account>` (one per Windows account): a version
   folder `api-<digest>` with the boot layer, the API, the native library and the fonts, and the two files the game
   writes there, `loader.log` and `api.tsv`.

   **What the loader trusts.** The game's folder is the trust root, as before the shim: what the install wrote there is
   believed, and nothing the shim or the loader reads outside it is. The shim runs the jar only if its bytes have the
   SHA-256 the install wrote in the loose settings (`sha256=`), the same trust as running loose classes there, plus a
   jar that is damaged, half written or not the installed one never runs (an attacker who can write the game's folder
   could change the shim and its settings as well, as before; on the class path the JVM loads the jar without the check,
   and the shim stands aside). The settings inside the jar say which version folder to load (`version=`) and the SHA-256
   of each file in it (`sha256.<file>=`). The loader loads nothing from the install folder that the settings do not vouch
   for, and it does not trust the install folder itself:
   - The install folder, its parent `PZExtAPI` and the version folder must be owned by the machine's administrators
     and writable by no one else ([`Trust`](../src/loader/pzext/launch/Trust.java)). The administrators are not
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
   `MainScreenState.main`, when it zips its last logs. Creating the jar's
   [`BootProvider`](../src/loader/pzext/launch/BootProvider.java) (or the shim, above) starts the
   [`Loader`](../src/loader/pzext/launch/Loader.java). The providers serve no files; their scheme, `pzext-loader`, is
   their own.
3. **The loader** checks the install (the folders and each file's digest against its settings, above), loads the native library [`pzext-loader.dll`](../src/native/loader.cpp), which loads the game JRE's
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
   looked at again; a developer building the API sets `PZEXT_DEV_RELOAD=1` (or the full path of a built jar, which is then read
   instead of the installed one) in the game's environment, and the host then
   looks at the jar every second and a changed one loads without the digest check and takes over in the running game
   (the next game start refuses it again, unless it was installed).

The boot layer is loaded once per process and never replaced; a change to it waits for the game's next start. The API's
jar names the boot layer it was built for (`PZExt-Boot-Api` in its manifest); one built for another is not loaded.

## What must not break the game

The JDK creates the providers inside its own lock, with a flag that marks the list as loading. A provider that cannot
be created leaves the flag set, and every later request for a provider (the game's log zip among them) fails for the
rest of the run. So:

- The shim, `BootProvider` and `Loader` use `java.base` alone and catch everything. A missing or broken loader class is a
  `NoClassDefFoundError` inside that `try`.
- The install writes the jar and the shim before the service line, and uninstall removes the line before the shim, so the
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
`none` (no launcher file) or `unreadable` (a file whose class path list this cannot edit; the shim serves where the
game's folder is still on the class path). Installing a newer release is installing again: it copies a new version
folder, writes the jar whose settings name it and give its digests (and the shim's settings with the jar's digest), and
removes the older version folders. The shim, its service line and the other loose files are written only when their bytes
differ, so a newer release leaves them as they were. The jar changes with the version, so the install waits for a game
that runs (`game-running`: the launch jar is open).

The first install over an install from before the shim replaces the loose `BootProvider` and removes the loose `Loader`,
`Launcher` and `Trust` classes. A tool that copies the game folder's loose classes (PZ Optimization) sees that change once.
If it is already stuck from an earlier change (its own jar `pzopt/aot/pzopt.jar` held open by the game, a rebuild that
failed with `AccessDeniedException`), it needs one launch in which it can rebuild; delete its stale jar and temporary file
while the game is closed.

Uninstalling removes the jar first (a game that runs has it open, so the uninstall stops there with `game-running` before
anything else changes), then the launcher file's entry, the service line and the shim; other tools' entries and
lines stay. Another program (a mod manager, a
launcher) installs the API by running the same commands; `PZEXT_GAME_ACCOUNT` names the account the game runs as when
the install runs as another (elevated by another administrator).

## Other tools in the same game

Other tools that hook the game the same way (their own provider line, their own agent) live beside the API: each has
its own line in the services file and its own transformers, and a class two tools change gets both changes (each
transformer stays registered, so a later retransformation by one runs the other's again). Two tools must not hook the
same game method for the same purpose; the API owns the questions it answers.

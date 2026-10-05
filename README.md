# PZ Tools

Backups, character revival, performance recording and a few in-game extras for Project Zomboid
Build 42 single player, on Windows. PZ Tools is unofficial and not affiliated with The Indie
Stone.

![A manual backup: the progress card, then the new backup at the top of the save's history](docs/media/backup.webp)

<a id="features"></a>
## What it does

- Backs up the save you're playing every few minutes, and has the game save first. Only what
  changed since the last backup is stored.
- Puts a save back the way it was in any backup, or moves it to another PC as a ZIP.
- Heals a character, or revives a dead one with their skills, and can take their belongings
  back from their zombie.
- Records the game while it stutters and shows which mod took the time.
- Gives the game more memory without editing its files by hand.
- Optional: better vehicle acceleration, reversing and keyboard steering, and a light around
  your car at night.

Nothing is installed into the game, and no Workshop mod is needed. The app speaks 18
languages.

<a id="getting-started"></a>
## Get started

You need Windows x64 and the [.NET 10 runtime](https://dotnet.microsoft.com/en-us/download/dotnet/10.0).

1. Download `PzTools-v<version>-win-x64.zip` from [Releases](https://github.com/isxcsm/pz-tools/releases)
   and extract all of it into a folder of its own. GitHub's "Source code" ZIP is not the app.
2. Run `PzTools.App.exe` and allow the administrator prompt.
3. Check the save and backup folders in **Settings**, then press **Back up now** in **Save
   manager**.

The [getting started guide](docs/guides/getting-started.md) walks through it.

To update, close PZ Tools and extract the new version into a new folder beside the old one.
Your settings, saves and backups carry over. Update while the game is closed, or restart the
game once afterwards. If you still use 0.1.0, read the [release notes](https://github.com/isxcsm/pz-tools/releases)
first: a backup folder opened by a newer version can't go back to 0.1.0.

PZ Tools asks GitHub for a newer version about once an hour and shows it in the sidebar. It
downloads nothing by itself. Turn the check off in **Settings → Version**.

<a id="backups-and-retention"></a>
## Backups

Automatic backups run every 5 minutes of play and keep the 20 newest. That limit never removes
manual backups. The countdown waits while the game is paused or your character is asleep.
After a death, automatic backups wait until you play on, so the backups from your last life
stay in the list.

When a save is gone, its backups go too, manual ones included. That happens when you delete
the save in PZ Tools, and also when its folder is deleted, renamed or moved outside PZ Tools,
for example from the game's menu. Export anything you want to keep first. See
[Backups](docs/reference/backups.md) for the details.

<a id="game-saving"></a>
## Saving the game first

Before an automatic backup, a countdown appears above your character and the game saves, so
the backup has your latest progress. The game may hitch for about half a second.

![The in-game countdown above the character before an automatic backup saves the game](docs/media/countdown.webp)

If PZ Tools can't reach the game, for example right after a game update, backups go on with
what the game last saved itself, and the sidebar says so.

<a id="restore-and-archives"></a>
## Restoring and moving saves

Restoring replaces the save with a backup, and everything played after that backup is lost.
Quit to the main menu first. See [Go back to an earlier backup](docs/guides/restore-a-save.md).

**Export ZIP** packs a save or one backup into a ZIP, and **Import archive** adds it to the save
list on another PC. See [Move a save to another PC](docs/guides/move-a-save.md).

<a id="character-recovery"></a>
## Reviving a character

PZ Tools heals your character in a save you're not playing, or brings them back from the dead
with their traits and skills. It can take their belongings back from their zombie or corpse.
It changes the save directly, so back up first.

![Reviving a character: the confirmation offers the zombie carrying their belongings, and the card reports what came back](docs/media/revive-app.webp)

![The character dies to a zombie; after recovery the same character is back on their feet in the same place](docs/media/revive-game.webp)

See [Bring back a dead character](docs/guides/revive-a-character.md).

<a id="performance-recording"></a>
## Finding a laggy mod

The **Performance** page records the running game. Select the stutter in the frame graph, and
it shows how much of that time went to each mod's scripts, the game's own code and running out
of memory. **Copy for AI** turns it into a report to paste into an AI chat or send to a mod's
author.

![A performance recording: a stretch of frames is selected, and the mods' shares of its time open into each mod's call tree](docs/media/profiler.webp)

See [Find a laggy mod](docs/guides/find-a-laggy-mod.md) and the [Performance page reference](docs/reference/performance-page.md).

<a id="game-memory"></a>
## Game memory

The game starts with 3 GB of memory, which a big mod list runs out of. **Settings → Game →
Game memory** gives it more. See [Give the game more memory](docs/guides/more-game-memory.md).

<a id="vehicle-controls"></a>
## Vehicle controls

The optional **Vehicle driving improvements** extension changes acceleration, shifting,
reversing and keyboard steering, and lights the ground around your car while its headlights
are on. It starts off. See [Better vehicle controls](docs/guides/vehicle-controls.md).

![The same road driven with the vehicle extension off and on](docs/media/steering.webp)

![At night, the headlights switched off and on; the light around the truck comes and goes with them](docs/media/lights.webp)

<a id="compatibility-and-limits"></a>
## Compatibility and limits

- Made for Project Zomboid Build 42 single player.
- A backup is copied while the game runs. Files are checked as they're copied, but a backup is
  not an instant snapshot of the whole world. Keep a copy of saves that matter on another
  drive.
- PZ Tools isn't code-signed. Windows Smart App Control may block parts of it; the app tells
  you when it does. [Security](SECURITY.md) explains what PZ Tools does and how to check a
  download.
- A newer PZ Tools may upgrade a backup folder so older versions can't open it. A version that
  can't read a backup folder leaves it alone and asks for a new one.

<a id="troubleshooting"></a>
## Problems

[Troubleshooting](docs/guides/troubleshooting.md) covers the messages and cards you may see.
The **Logs** page usually says what went wrong. If PZ Tools closes on an error, it writes a
report to `%LOCALAPPDATA%\PzTools\crash`.

Report a bug on [GitHub issues](https://github.com/isxcsm/pz-tools/issues) with the app and game
versions, what you did, and the log details or crash report.

<a id="building"></a>
## Build from source

You need Windows, the .NET SDK named in `global.json`, PowerShell 7.2 or later, a Java 25 JDK and the
Visual Studio C++ and WinUI build tools.

```powershell
$jdk = 'C:\path\to\jdk-25'
dotnet build PzTools.sln -c Release -p:Platform=x64 -p:JdkPath="$jdk"
dotnet test tests/PzTools.Backup.Tests -c Release
pwsh scripts/publish-app.ps1 -JdkPath $jdk -Output artifacts/app-local
```

Publish into a new or empty folder and hand out the whole folder. See [Development](docs/contributing/development.md)
for tests and checks.

<a id="technical-documentation"></a>
## Documentation

The [documentation index](docs/README.md) lists the guides, the reference pages for settings,
backups, files and the command line, and the design pages for anyone changing the code.

<a id="license"></a>
## License

PZ Tools is released under the [MIT License](LICENSE). Bundled and adapted third-party
components keep their own licenses; see the [third-party notices](THIRD_PARTY_NOTICES.md).
Project Zomboid is a trademark of The Indie Stone; no game code or assets are included.

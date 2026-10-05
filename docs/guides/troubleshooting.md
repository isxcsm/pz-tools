# Troubleshooting

Find what you see below. If it isn't here, the **Logs** page usually says what went wrong.

## PZ Tools doesn't start

**Windows asks for .NET.** Install the [.NET 10 Runtime](https://dotnet.microsoft.com/en-us/download/dotnet/10.0)
for x64, then start PZ Tools again. The Desktop Runtime works too.

**You declined the administrator prompt.** PZ Tools can't run without it, because it reads
which files in a save changed. Start it again and allow the prompt.

**Some PZ Tools files are missing. Extract the downloaded package again.** Part of the ZIP
didn't come out. Extract the whole ZIP again into an empty folder.

## Cards in the sidebar

| Card | What it means | What to do |
| --- | --- | --- |
| **PZ Tools files are not intact** | A file in the PZ Tools folder is missing or from another version, usually because a new version was extracted over an old one | Press **Open download page**, then extract the ZIP into a new, empty folder |
| **Blocked by Windows Security** | Windows Smart App Control stopped part of PZ Tools from running | Press **Open settings** to go to Smart App Control |
| **Not connected to the game** with **Backups continue on a timer. If the game cannot save first, the files are backed up as they are.** | PZ Tools couldn't read the game for a while. Each backup still asks the game to save first; if it can't, the backup holds what the game last saved itself. | Restart the game. If that doesn't help, the game may have updated past what this version of PZ Tools knows, so update PZ Tools |
| **Not connected to the game** with **A game launch option is blocking the connection.** | The game was started with `-XX:+DisableAttachMechanism` | Remove it from the game's Steam launch options or from `ProjectZomboid64.json`, then restart the game |
| **PZ Tools was updated** with **Restart the game.** | The game still runs the link from the previous PZ Tools version. Automatic backups wait. | Restart the game once. Updating PZ Tools while the game is closed avoids this |
| **Game memory back to 3 GB** | A game update reset the memory setting | See [Give the game more memory](more-game-memory.md#after-a-game-update) |
| **Could not load the save list** | PZ Tools keeps trying again by itself | If it stays, check the **Save folder** in **Settings → Folders** |

## Backups aren't happening

Look at the line under the next backup in the sidebar.

| It says | Why | What to do |
| --- | --- | --- |
| **Automatic backups off** | They were turned off, maybe by the hotkey | Turn on **Settings → Backup → Automatic backups** |
| **Game paused** or **Character sleeping** | The countdown waits while you're not playing | Nothing. Turn off **Delay scheduled backups while paused or asleep** if you'd rather it didn't wait |
| **Character dead – backups waiting** | Your last backups stay as they were until you play on | Start a new character, or [revive this one](revive-a-character.md) |
| **Game is not running**, **Game at main menu** or **Game is loading** | There's no save open yet | Load a save |
| **Run only one instance of Project Zomboid** | Two copies of the game are running | Close one |
| **Skipping this backup** | PZ Tools couldn't tell whether the last game save worked | Nothing. The next one runs as usual |
| **Automatic backups after a game restart** | PZ Tools was updated while the game ran | Restart the game |

## Messages after you press a button

| Message | What to do |
| --- | --- |
| **Backups cannot be restored while playing. Stop playing and try again.** | Quit to the main menu or close the game |
| **Cannot export while playing. Quit to the main menu.** | Quit to the main menu or close the game |
| **The save kept changing, so it was not backed up. Try again in a moment.** | Try again in a moment |
| **The game or other work is using the file. Try again in a moment.** | Wait for the running backup or other work to finish |
| **Not enough disk space.** | Free up space, or move backups to another drive in **Settings → Folders** |
| **This backup is damaged. Choose another backup.** | Pick another backup. Your save wasn't changed |
| **This file cannot be imported. Check that PZ Tools exported it.** | Only ZIPs exported by PZ Tools can be imported |

## Still stuck

PZ Tools writes a crash report to `%LOCALAPPDATA%\PzTools\crash` when it closes on an error.
Open an issue with **Report an issue** on the **Home** page. Add what you did, and the details
from the **Logs** page (**Copy details**) or the crash report.

For a security problem, see [Security](../../SECURITY.md) instead of opening a public issue.

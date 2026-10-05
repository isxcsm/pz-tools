# Getting started

## What you need

- Windows 10 or 11, 64-bit
- The [.NET 10 runtime](https://dotnet.microsoft.com/en-us/download/dotnet/10.0)
- Project Zomboid Build 42, single player

PZ Tools doesn't install anything into the game.

## 1. Install

1. Download `PzTools-v<version>-win-x64.zip` from [Releases](https://github.com/isxcsm/pz-tools/releases).
2. Extract the whole ZIP into a folder of your own, such as `Documents\PzTools`.
3. Run `PzTools.App.exe` and allow the administrator prompt. PZ Tools needs administrator
   rights to see which files in a save changed.

If you want to check the download first, see [Security](../../SECURITY.md#checking-a-download).

## 2. Folders

Open **Settings** in the sidebar and check **Folders**. The **Save folder** is your `Zomboid\Saves` folder, and backups go to
`Zomboid\Backups` unless you pick another **Backup folder**. If you have a second drive, putting
backups there keeps them safe when the first one fails.

[Screenshot: Settings, the Folders section with the save and backup folders filled in]

## 3. Automatic backups

Automatic backups are on from the start. Look over **Settings → Backup** if you want to change them.

| Setting | Default | What it does |
| --- | --- | --- |
| **Automatic backups** | On | Backs up the save you're playing |
| **Backup interval** | 5 minutes | Counts play time, so pausing doesn't use it up |
| **Automatic backups to keep** | 20 | Removes the oldest automatic backups. Manual ones are kept. |
| **Save game before backup** | On | Has the game save first, so the backup includes your latest progress |

Leave **Save game before backup** on. Without it, anything the game hasn't saved yet is
missing from the backup.

## 4. Your first backup

Open **Save manager**, select your save and press **Back up now**. The backup shows up at the
top of the list on the right.

![A manual backup: the progress card, then the new backup at the top of the list](../media/backup.webp)

## 5. Play

Start the game and load your save. The sidebar shows when the next backup is due.

Just before a backup, a countdown appears above your character and the game saves. It may
hitch for about half a second.

![The countdown above the character before an automatic backup](../media/countdown.webp)

The countdown waits while the game is paused or your character is asleep. If your character
dies, automatic backups stop until you start a new one or [revive them](revive-a-character.md), so the backups from your last life
stay in the list.

Closing the window quits PZ Tools, and backups stop with it. Turn on **Settings → Appearance
and behavior → System tray** if you want it to keep running in the background.

## Next

- [Go back to an earlier backup](restore-a-save.md)
- [Move a save to another PC](move-a-save.md)
- [Bring back a dead character](revive-a-character.md)
- [Find a laggy mod](find-a-laggy-mod.md)
- [Give the game more memory](more-game-memory.md)
- [Better vehicle controls](vehicle-controls.md)
- [Troubleshooting](troubleshooting.md)

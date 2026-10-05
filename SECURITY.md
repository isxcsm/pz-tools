# Security

[User guide](README.md) · [Documentation index](docs/README.md)

PZ Tools runs with administrator rights and connects to the running game, so it is fair
to ask what it does there. This page says what it does, what it does not, how to check a
download, and where its limits are.

## Reporting a problem

Report a security problem privately through GitHub: the repository's **Security and quality**
tab → **Report a vulnerability**. Please do not put the details in a public issue. Anything
else goes in [issues](https://github.com/isxcsm/pz-tools/issues).

## What PZ Tools does to the game

- **It attaches to the game that is already running**, through Java's own attach
  mechanism (the one debuggers and profilers use). It does not inject threads, patch the
  game's files, or change how the game is started. See [the game bridge](docs/design/game-bridge.md).
- **It loads only its own code into the game:** the jars shipped in its own folder
  (`game-bridge\`): the bridge, its bootstrap, and the vehicle extension. It never loads
  code from mods, the Workshop, saves, or anything downloaded. A small native file in the
  same folder only loads the game's own Java launcher library.
- **The game listens only on the local machine** (`127.0.0.1`), for PZ Tools, with a
  random secret per game run. It accepts a fixed set of commands: save, report its
  state, record performance, switch its own extensions. It does not run Lua or Java code
  sent to it.
- **It changes a game file only when you ask:** *Settings → Game → Game memory* edits
  the memory options in `ProjectZomboid64.json` and keeps a copy of the file as the game
  shipped it. See [game memory](docs/design/game-memory.md).

## Network

One request: about once an hour, the app asks GitHub's API whether a newer release is out
(`api.github.com`, with the app's version in the request). Nothing is downloaded or
installed by the app; an update is a ZIP you download and extract yourself. *Settings →
Version* turns the check off. Logs, statistics and crash reports stay on your PC
(`%LOCALAPPDATA%\PzTools`); nothing is uploaded.

## Why administrator rights

Backups find what changed in a save through NTFS's change journal, which only an
administrator can read. Folders, files, VS Code and web links opened from the app go
through Explorer, so they run with your own rights, not the app's.

## Checking a download

PZ Tools is not code-signed: a certificate costs money every year, and this is a free
tool. Each release has a `.sha256` file beside its ZIP. In PowerShell, in the folder you
downloaded to:

```powershell
Get-FileHash .\PzTools-v0.2.4-win-x64.zip -Algorithm SHA256
```

The hash must equal the one in the `.sha256` file. This shows the file arrived whole;
since both come from the same release page, it cannot show who built it. Download only
from [the releases page](https://github.com/isxcsm/pz-tools/releases).

From 0.2.4, releases are built by GitHub Actions from the tagged commit, not on the
author's PC, and carry a build provenance attestation. With the
[GitHub CLI](https://cli.github.com/):

```powershell
gh attestation verify .\PzTools-v0.2.4-win-x64.zip --repo isxcsm/pz-tools
```

This checks that the ZIP was built by the repository's own workflow, from a commit in it
you can read.

Once extracted, the app checks its own files against the list built with it
(`pztools-files.txt`) and says if any differ, which catches a package extracted over
another. It is not a tamper check: the list is in the same folder.

## Limits

- **Unsigned.** Windows Smart App Control may block some parts; see the
  [user guide](README.md).
- **The whole app runs as administrator,** not only the part that reads the change
  journal. Its settings and databases are in `%LOCALAPPDATA%\PzTools`, which any
  program running under your account can write. A program already running as you could
  therefore influence what the app backs up or where. Keep the app in a folder only you
  and administrators can change (your user folder or `C:\Program Files`, not a shared
  folder), and do not run programs you do not trust.

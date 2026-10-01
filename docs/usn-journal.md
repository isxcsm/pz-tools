# Windows USN journal

[Documentation index](README.md) · [User guide](../README.md) · [Glossary](glossary.md)

NTFS keeps a change journal on each volume, the [USN journal](glossary.md#usn-journal),
that records which files were created, changed, renamed or deleted. The backup worker
reads it to find the save files that changed since the last backup without reading
every file. This page is for people working on the Windows change-tracking code.

## When it is used

The backup worker keeps a checkpoint from the last backup and reads the journal from
there. When the journal cannot be used, the backup falls back to a full scan with the
configured [content comparison](configuration.md#which-files-are-captured).

The most common reason is that the journal has moved on: it has a fixed size, and when
a busy drive fills it between two backups, the records after the checkpoint are gone.
On one development machine this was about one backup in ten.

A file kept open and written again does not get a new journal record until it is
closed or a different kind of change happens (it grows, for example): the journal notes
the first change of each kind per open. A backup taken in between does not see those
later writes. The databases the game keeps open, `players.db` and `vehicles.db`, are
therefore captured every time (`always_include`), and the backup asks the game to save
first. Whether the game keeps any other save file open between saves has not been
observed.

Drives formatted FAT32 or exFAT, such as most USB sticks, have no journal, so every
backup of a save there is a full scan with content comparison. FAT32 also refuses the
128-bit file-ID query; the file-information reader then uses the older 64-bit file
index in the same identity format. FAT32 keeps no change time, steps last-write times
in two seconds, and does not move them for a write that is still being buffered.

The checkpoint is the triple `(volume serial, journal ID, next USN)`. All three are
checked against the volume before reading.

## Limits

- **Administrator rights.** Reading the journal on the development machine needs an
  elevated process, and running a worker directly may need the same. There is no
  separate elevation helper; if one is added, it would be a deployment option and
  must not own repository or telemetry state.
- **Record versions.** Only journal records of versions 2 and 3 are read.

## How it works inside

**Volume query.** The change-tracking layer reads the volume's NTFS serial number,
journal ID, first readable USN, next USN and lowest valid USN.

**Reading.** Records are read with a fixed 1 MiB buffer. Reading stops at an upper
bound captured at the start, even if the journal grows meanwhile; records at or beyond
that bound are ignored.

**Parsing.** Before producing typed records, the parser checks record lengths,
versions, file-name ranges and USN boundaries. Version 2 uses 64-bit file and parent
references and version 3 uses 128-bit ones; both are normalised to `UInt128`.

**Planning.** The delta planner works through bounded batches instead of holding the
whole journal interval in memory. Rename state carries over between batches, and every
hard-link path belonging to a file reference stays tracked.

## Verification

- The binary-parser tests need no elevated rights.
- The live volume-query and bounded-read tests run only with `PZTOOLS_TEST_USN=1`.
  Without it they report as skipped.
- The range test also checks file references against `FILE_ID_INFO`.
- The FAT test runs only when `PZTOOLS_TEST_FAT_DIR` names a folder on a FAT32 or exFAT
  drive. It backs up a file there and checks that a same-size rewrite with its old time
  restored is still captured.

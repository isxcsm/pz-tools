# User-facing localization review

Base: `dev` at `6ab613238081946b9d9fccd67d01c0719b11340f`.
Branch: `i18n/user-friendly-messages`. This work is independent of the pending
path-normalization PR. No backup/storage format, deletion policy, persisted language
identifier, game-save protocol, or worker outcome code is changed.

## Scope and terminology

Reviewed app-owned resource strings in all 18 existing locales, settings/error
presentation, progress labels, and shared game notifications. This does not add
new supported languages or change existing backup names stored on disk.

- Distinguish game saving from creating a backup. The automatic-backup badge agrees
  with the shared language catalog, and game notices explicitly describe a game save.
- Prefer folders and operation numbers to internal directories, run indices, commits
  and worker terminology in everyday controls. Keep exact paths, event identifiers
  and original exceptions in diagnostic records rather than ordinary notifications.
- Restore confirmation identifies the overwritten save/backup, warns that later
  progress will be lost, and asks the user to reopen PZ Tools before loading the save
  after interruption. It does not guarantee automatic rollback in an uncertain state.
- An unstable-file failure asks the user to wait for game saving and retry the backup.
  It does not promise a retry that a manual backup may never receive.
- Settings and file errors distinguish permissions, missing files, files in use, full
  disks, incomplete app distributions, incompatible backup repositories and settings
  restart/rollback failures. An incompatible repository message asks for a new empty
  backup folder and specifically avoids suggesting deletion of the game's saves.
- "Game save finished" does not claim that the backup is complete. A degraded result
  asks the user to check Logs before repeating an operation with possible partial effects.
- Reusing identical backup data has a localized progress phase. Its byte-based progress
  is recognized by the same display rules as capture. Copy/hash/archive diagnostic
  phases use localized descriptions without changing their underlying event codes.
- All four switches have localized On/Off labels, refreshed with the selected app
  language. Page Language also follows the app setting, not just the Windows language.
  Stale XAML initialization text promising indefinite manual-backup retention is removed.

`UserFacingErrorCatalog` is a UI-independent resource-key classifier. It recognizes
Windows I/O failure codes without parsing translated OS messages, preserves pending
save-edit warnings, and does not pick one inner failure from an aggregate operation.
Known worker diagnostic codes are prefixes, not substrings of user-chosen file paths.
Archive access failures and cancellation are not labeled as corrupt ZIP files.
Original inner diagnostics are retained when settings messages are wrapped. Supported
legacy language identifiers (`Korean`, `English`, `ko`, `en`) remain readable.

## Checks

`python scripts/check-localization.py` checks every locale's duplicate/empty keys,
placeholder and line-break parity, literal UI references, emitted error keys, backup
naming and the shared countdown contract. Existing C# localization tests also parse
and format every value with .NET CompositeFormat and round-trip all language settings.

`UserFacingMessageTests` cover diagnostic boundaries, translated I/O exceptions,
archive errors, cancellation, nested/aggregate failures, resource selection, restore
safety copy and the language-switch wiring. Play-restriction tooltip checks now cover
all 18 locales. Byte-progress tests include deduplication.

The synthetic JVM tests retain their timing/attach/detach/real backup-and-restore
assertions. Expected notice text and the equal-byte-length hot-reload fixture are
updated to the new wording. They still read the same shared UTF-8 language catalog.

Record actual Windows build, targeted C# and synthetic JVM results in the PR after
execution. Static checks are not evidence of rendered WinUI layout or native-speaker
review. Existing diagnostic details remain technical by design; operating-system
file pickers are not translated by this app. User saves/repositories are not accessed
by this review. Manual screenshots at narrow widths and proofreading by native
speakers remain useful release checks, particularly for long translated warnings.

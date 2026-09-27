# User-facing localization review

[Documentation index](README.md) · [User guide](../README.md)

Historical review of `i18n/user-friendly-messages`, based on dev
`6ab613238081946b9d9fccd67d01c0719b11340f`. It changed UI wording and presentation,
without changing storage, deletion policy, persisted language IDs or worker protocols.
See [localization](localization.md) for the maintained UI language contract.

## Scope and terminology

The review covered app resources, settings/errors, progress and game notifications in
18 existing locales. It added no languages and did not rename stored backups.

- Game-save notices distinguished saving from backup completion and used the shared
  language catalog consistently.
- Everyday controls used folders and operation numbers; logs retained paths, event
  identifiers and original exceptions.
- Restore and partial-failure messages explained lost progress and the next action
  without promising automatic rollback or retries. Obsolete permanent-retention
  wording was removed.
- File/settings errors distinguished actionable causes. Incompatible-repository
  messages requested a new backup folder without suggesting deletion of game saves.
- Deduplication received localized byte progress, and copy/hash/archive labels retained
  their event codes. All four switches and Page Language followed the app setting.

`UserFacingErrorCatalog` classified Windows I/O codes without parsing translated OS
messages. It preserved pending-edit warnings and aggregate failures, matched worker
codes only as prefixes, and kept access/cancellation errors distinct from ZIP corruption.
Wrapped settings errors retained inner diagnostics. Legacy language IDs (`Korean`,
`English`, `ko`, `en`) remained readable.

## Checks

Coverage combined `python scripts/check-localization.py` for resource consistency,
C# formatting/settings and `UserFacingMessageTests` for error and language-switch
behavior, and synthetic JVM notice/hot-reload tests using the shared UTF-8 catalog.

This record contains no final Windows/JVM result counts or rendered-layout/native-
speaker review evidence. Operating-system file pickers remained outside app translation.

# User-facing localization review

[Documentation index](../README.md) · [User guide](../../README.md)

> **Historical record.** This page describes the code and measurements at the time it was written. It is kept for reference and is not updated; for current behaviour start at the [documentation index](../README.md).

The original review below covers `i18n/user-friendly-messages`, based on dev
`6ab613238081946b9d9fccd67d01c0719b11340f`. It changed UI wording and presentation,
without changing storage, deletion policy, persisted language IDs or worker protocols.
See [localization](../localization.md) for the maintained UI language contract.

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
  their event codes. All four switches and the page language followed the app setting.

`UserFacingErrorCatalog` classified Windows I/O codes without parsing translated OS
messages. It preserved pending-edit warnings and aggregate failures, matched worker
codes only as prefixes, and kept access/cancellation errors distinct from ZIP corruption.
Wrapped settings errors retained inner diagnostics. Legacy language IDs (`Korean`,
`English`, `ko`, `en`) remained readable.

## Checks

Coverage combined `python scripts/check-localization.py` for resource consistency,
C# formatting/settings and `UserFacingMessageTests` for error and language-switch
behavior, and synthetic JVM notice/hot-reload tests using the shared UTF-8 catalog.

This record contains no final Windows/JVM result counts or evidence of rendered-layout
checks or native-speaker review. Operating-system file pickers remained outside app translation.

## 2026-09-27 — full wording review

This review covered all 18 app resource files, the shared backup-name and game-notice
catalog, the root README, all Markdown under `docs/`, and the tooltip smoke-test README.
Third-party notices were read without changing license text. Repository documentation
remained English-only.

The revisions clarified game saving versus backup completion, manual-backup retention
and deletion, progress lost during restore, and the absence of an automatic extra backup
before character recovery. They also clarified that a saved death marker alone does not
trigger a death backup, and that ignoring a supported version range neither enables an
extension nor bypasses its mandatory checks. User instructions use direct actions;
technical references retain required identifiers and historical measurements.

Resource keys, placeholders, locale IDs and command contracts were preserved. This was
a wording and consistency review, without app execution, rendered-layout checks,
real-game acceptance or independent native-speaker certification. Automated checks
cannot establish those outcomes.

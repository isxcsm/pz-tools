# Localization

[Documentation index](../README.md) · [User guide](../../README.md) · [Glossary](../design/glossary.md)

The PZ Tools app, and the notices it shows inside the game, can be used in 18 languages.
All of them ship with the app: switching language does not call an online translation
service or download a language pack. This page is for anyone translating the interface,
reviewing wording or adding a language. The supported language tags and their native
names come from the
[shared language catalog](../../src/PzTools.Process.Contracts/Localization/languages.tsv).

## What is translated

| Translated | Not translated |
| --- | --- |
| The interface and settings | Raw diagnostic details |
| Progress, dialogs and log summaries | File paths |
| Failure explanations | Game modes |
| New default backup names | Mod-defined names |
| Game-save notices shown in the game | Names the user typed |

Every locale must supply the complete set of resource keys. Do not keep a separate
hard-coded count of keys in this document.

## Choosing a language

- A fresh installation starts in the Windows display language where the app has it (the nearest variant of Spanish, Chinese or Portuguese), and in English otherwise.
- Settings store the locale tag. Older identifiers that are still supported, such as
  `Korean`, `English`, `ko` and `en`, can still be read. Unsupported tags are rejected.
- Changing the language does not rewrite the names of existing backups.
- The *Latin American Spanish* option uses the `es-MX` Windows culture. Its wording is
  shared neutral Spanish on purpose; see [limits](#limits).

## Writing and reviewing translations

Review labels and instructions in context, where they appear. In every language:

- Keep *saving the game* and *creating a backup* distinct.
- Keep operations on the current save apart from operations on historical backups.
- Keep the warnings on destructive operations.
- Never promise that an interrupted operation will recover on its own.
- Keep placeholder arguments, numeric formats, conditions and paragraph boundaries.
- Build a sentence from one resource with placeholders, never by joining two in code: word
  order and punctuation differ by language (*Expand {0}*, *{0} aufklappen*).
- Sizes and times use the language's own unit symbols, the ones Windows uses in it
  (`Unit.*`: *Ko* and *Mo* in French, *КБ* and *мс* in Russian), after the number and a
  space; numbers use the language's format. *FPS* is not translated.

Review wording and rendered layout separately from the structural checks under
[verification](#verification).

## Adding a language

1. Add the language to the enum and to the
   [catalog](../../src/PzTools.Process.Contracts/Localization/languages.tsv).
2. Add all UI resources under [App Strings](../../src/PzTools.App/Strings).
3. Run the relevant [checks](#verification).

Do not add another README edition for the new language; see
[repository documentation](#repository-documentation).

## Limits

- **Game fonts and layout are not tested automatically.** Synthetic JVM tests check that
  the in-game messages are delivered. Whether the game's fonts cover the characters, and
  how the text looks on screen, needs separate checks.
- **Spanish is not per country.** The `es-MX` option is shared neutral Spanish. It does
  not claim a separate translation for every country.
- **The copy review is not a certification.** The
  [user-facing copy review](../history/localization-review.md) records an earlier set of changes; it is not an independent native-speaker review.

## Repository documentation

The app's languages and the documentation are independent. Maintain the
[README](../../README.md) and the [reference documents](../README.md) in English only. Do not
add per-language copies, and do not tie documentation coverage to the app's language
catalog. [Documentation maintenance](documentation-maintenance.md) describes the checks.

## How it works inside

| Source | Responsibility |
| --- | --- |
| [languages.tsv](../../src/PzTools.Process.Contracts/Localization/languages.tsv) | Enum ID, locale tag, native name, three backup-name prefixes and four game-notice templates (countdown, completion, failure, in progress) |
| [App Strings](../../src/PzTools.App/Strings) | Complete UI resources for each locale |
| [LanguageCatalog](../../src/PzTools.Process.Contracts/LanguageCatalog.cs) | Supported IDs, validation and parsing of older names |
| [Localizer](../../src/PzTools.App/Localizer.cs) | Resource context and date/number culture; falls back to English |

The game side and the .NET workers read the same UTF-8 catalog. The Java payload
receives it at build time, so there is no second set of game-notice strings to edit.

## Verification

The static resource and documentation checks do not open a user save:

```powershell
python scripts/check-localization.py
python scripts/check-documentation.py
```

On a configured Windows build machine, run the resource, message and setting regressions:

```powershell
dotnet test tests/PzTools.Backup.Tests -c Release --filter "FullyQualifiedName~LocalizationTests|FullyQualifiedName~UserFacingMessageTests|FullyQualifiedName~BackupKindTests|FullyQualifiedName~BackupConfigurationTests"
```

The [localization smoke project](../../tests/PzTools.LocalizationSmoke) runs the real WinUI
resource-loading and language-switching pipeline. It has no `AppHost`, scheduler or game
connection, and does not read or modify user saves. Build and run it on Windows:

```powershell
dotnet build tests/PzTools.LocalizationSmoke -c Debug
$smoke = (Resolve-Path tests/PzTools.LocalizationSmoke/bin/Debug/net10.0-windows10.0.19041.0/win-x64/PzTools.LocalizationSmoke.exe).Path
$strings = (Resolve-Path src/PzTools.App/Strings).Path
New-Item artifacts -ItemType Directory -Force | Out-Null
$result = Join-Path (Resolve-Path artifacts) 'localization-smoke.txt'
Start-Process -FilePath $smoke -ArgumentList @("`"$strings`"", "`"$result`"") -WindowStyle Hidden -Wait
Get-Content -LiteralPath $result
```

The [bridge test script](../../scripts/test-game-bridge.ps1) runs an isolated synthetic JVM.
Its tests cover the shared in-game notices as well as timing, game-thread execution,
failure and [payload](../design/glossary.md#payload) replacement. They do not replace opt-in tests
in the real game.

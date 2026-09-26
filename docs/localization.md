# Localization

[Documentation index / 문서 목차](README.md) · [User guide / 사용 안내](../README.md)

PZ Tools bundles 18 locales. Changing the app language does not call an online
translation service or download a language pack. The supported tags and native names
come from the [shared language catalog](../src/PzTools.Process.Contracts/Localization/languages.tsv).
The [documentation index](README.md#user-guides--언어별-사용-안내) links to the guide for each language.

## Translation scope

Translations cover the interface, settings, progress, dialogs, log summaries, failure
explanations, new default backup names and game-save notices. Raw diagnostic details,
file paths, game modes, mod-defined names and user-entered names are not translated.
All locales must supply the complete resource-key set; do not maintain a separate
hard-coded key count in this document.

Changing the language does not rewrite existing backup names. The game and .NET workers
use the same UTF-8 catalog. Synthetic JVM tests verify message delivery, but actual
game font coverage and on-screen layout require separate checks. `es-MX` supplies the
Windows culture for the Latin American Spanish option; shared neutral Spanish wording
is intentional, not a claim of a separate translation for every country.

Review labels and instructions in context. Distinguish game saving from backup creation,
keep current-save and historical-backup operations separate, and preserve destructive
operation warnings. An interrupted operation must not promise successful automatic
recovery. The [user-facing copy review](localization-review.md) records an earlier set
of changes; it is not independent native-speaker certification.

## Repository documentation

The root [README](../README.md) is the English guide. `docs/<locale>/README.md` provides
the other 17 entry points. Each has the same user topics, build commands, safety
information and direct references, with an explicit language selector. GitHub does not
choose a README by browser language; there is no Pages redirect or automatic selection.

Technical documents retain their original English or Korean. Link labels identify that
language, and the [index](README.md) separates references from dated measurements and
plans. Follow the [documentation maintenance rules](documentation-maintenance.md) when
adding or editing a guide. The translated guides have not received independent review
from native speakers of all supported languages.

## Sources of truth

| Source | Responsibility |
| --- | --- |
| [languages.tsv](../src/PzTools.Process.Contracts/Localization/languages.tsv) | Enum ID, locale tag, native name, three backup-name prefixes and four game-notice templates (countdown, completion, failure, in progress) |
| [App Strings](../src/PzTools.App/Strings) | Complete UI resources for each locale |
| [LanguageCatalog](../src/PzTools.Process.Contracts/LanguageCatalog.cs) | Supported IDs, validation and legacy-name parsing |
| [Localizer](../src/PzTools.App/Localizer.cs) | Resource context and date/number culture; English fallback |

Settings persist locale tags. Supported legacy identifiers such as `Korean`, `English`,
`ko` and `en` remain readable; unsupported tags are rejected. A fresh app defaults to
Korean. The Java payload receives the same catalog at build time, so do not edit a
second independent set of game-notice strings.

## Verification

Static resource and documentation checks do not open a user save:

```powershell
python scripts/check-localization.py
python scripts/check-documentation.py
```

On a configured Windows build machine, run the resource, message and setting regressions:

```powershell
dotnet test tests/PzTools.Backup.Tests -c Release --filter "FullyQualifiedName~LocalizationTests|FullyQualifiedName~UserFacingMessageTests|FullyQualifiedName~SaveActionTooltipTests|FullyQualifiedName~BackupKindTests|FullyQualifiedName~BackupConfigurationTests"
```

The [localization smoke project](../tests/PzTools.LocalizationSmoke) exercises the real
WinUI resource-loading and language-switching pipeline. It has no AppHost, scheduler or
game connection and does not read or modify user saves. Build and run it on Windows:

```powershell
dotnet build tests/PzTools.LocalizationSmoke -c Debug
$smoke = (Resolve-Path tests/PzTools.LocalizationSmoke/bin/Debug/net10.0-windows10.0.19041.0/win-x64/PzTools.LocalizationSmoke.exe).Path
$strings = (Resolve-Path src/PzTools.App/Strings).Path
New-Item artifacts -ItemType Directory -Force | Out-Null
$result = Join-Path (Resolve-Path artifacts) 'localization-smoke.txt'
Start-Process -FilePath $smoke -ArgumentList @("`"$strings`"", "`"$result`"") -WindowStyle Hidden -Wait
Get-Content -LiteralPath $result
```

[The bridge test script](../scripts/test-save-bridge.ps1) runs an isolated synthetic JVM.
Its tests cover the shared notices as well as timing, game-thread execution, failure and
payload replacement. They are not a substitute for real-game opt-in tests.

When adding a language, update the enum and catalog, add all UI resources and the
README entry point, update the documentation index and language navigation, and run
all relevant checks. Preserve placeholder arguments, numeric formats, conditions and
paragraph boundaries. Report automated results separately from native-speaker and
rendered-layout review.

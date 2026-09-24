# Localization

The app ships 18 locales. Translations are bundled; switching language never calls
an online translation service or downloads a language pack.

| Locale | Display name |
| --- | --- |
| ko-KR | 한국어 |
| en-US | English |
| zh-CN | 简体中文 |
| zh-TW | 繁體中文 |
| ja-JP | 日本語 |
| ru-RU | Русский |
| pt-BR | Português (Brasil) |
| es-ES | Español (España) |
| fr-FR | Français |
| de-DE | Deutsch |
| pl-PL | Polski |
| tr-TR | Türkçe |
| uk-UA | Українська |
| it-IT | Italiano |
| th-TH | ไทย |
| id-ID | Bahasa Indonesia |
| cs-CZ | Čeština |
| es-MX | Español (Latinoamérica) |

`es-MX` supplies the Windows culture for the Latin American Spanish option. Shared
neutral Spanish wording is intentional; this is not a claim of separate translations
for every Latin American country.

## Scope and review

The 16 added locale resources were rewritten directly by the coding assistant from
the English source after an initial machine-translated draft was rejected. They were
reviewed for save/backup terminology, action labels, destructive-operation warnings,
character recovery limits, placeholders and line breaks. This is **not independent
native-speaker certification**. The initial translation helper is not retained.

Each locale has all 369 app resource keys, including settings, progress, dialogs,
log summaries and failure explanations. Character recovery explicitly preserves
all traits, including negative traits. Technical raw logs, exception messages,
file paths, game modes, mod-defined names and user-entered names are not translated.

New default backup names follow the selected language. Existing persisted names
and user names are not rewritten when the language changes. Game notices use the
same locale catalog as the app and workers. The JVM fixture verifies Unicode message
delivery; actual in-game glyph rendering still depends on the game's fonts.

## Repository documentation

The root README is the English feature guide. `docs/<locale>/README.md` provides
the other 17 entry points, all connected by a native-language selector. Korean
retains the original full guide; the other 16 guides cover features, getting
started, recovery limits, and backup safety. These guides were authored directly
by the coding assistant, without an external translation service. They have not
been independently reviewed by native speakers.

GitHub does not select a README based on browser language. The selector is explicit;
no Pages site or automatic redirect is deployed. Technical reference documents
remain in their original languages and are labeled accordingly in the guides.

Run `pwsh scripts/test-readme-links.ps1` to check catalog coverage, language links,
and local README link targets. The same check runs on pushes and pull requests.

## Sources of truth

- `src/PzTools.Process.Contracts/Localization/languages.tsv`: enum ID, BCP 47 tag,
  native display name, three backup-name prefixes and three game-notice templates.
  The UTF-8 file is embedded in the .NET assembly and compiled into a generated
  Java payload class. The existing bootstrap loads classes only, so it needs no
  resource-loader change or game restart for the new catalog.
- `src/PzTools.App/Strings/<tag>/Resources.resw`: full UI resources.
- `LanguageCatalog`: supported IDs, validation and legacy-name parsing.
- `Localizer`: MRT resource context and date/number formatting culture. English is
  the fallback resource language; a fresh app still defaults to Korean.

Settings now persist locale tags. Existing `Korean` and `English` settings and CLI
arguments remain readable without forcing a rewrite. Unsupported tags are rejected.

## Verification

Run resource, settings and persisted-name checks:

```powershell
dotnet test tests/PzTools.Backup.Tests --filter "FullyQualifiedName~LocalizationTests|FullyQualifiedName~BackupKindTests|FullyQualifiedName~BackupConfigurationTests"
```

`tests/PzTools.LocalizationSmoke` links the production `Localizer` and resources.
It exercises the real WinUI/MRT pipeline in both language-switching directions and
compares every resolved string and formatted value with its source. It has no
AppHost, scheduler or game connection and does not read or modify user saves.

```powershell
dotnet build tests/PzTools.LocalizationSmoke -c Debug
$smoke = (Resolve-Path tests/PzTools.LocalizationSmoke/bin/Debug/net10.0-windows10.0.19041.0/win-x64/PzTools.LocalizationSmoke.exe).Path
$strings = (Resolve-Path src/PzTools.App/Strings).Path
$result = Join-Path (Resolve-Path artifacts) 'localization-smoke.txt'
Start-Process -FilePath $smoke -ArgumentList @("`"$strings`"", "`"$result`"") -WindowStyle Hidden -Wait
Get-Content -LiteralPath $result
```

`scripts/test-save-bridge.ps1` uses an isolated synthetic JVM, not the running game.
Its catalog test checks all 18 completion messages, alongside existing countdown,
game-thread, failure, timing and changed-payload tests.

When adding a language, update the enum and catalog, provide the complete resource
key set, then run all three layers. Keep formatting placeholders (including numeric
formats), warning conditions and paragraph boundaries intact.

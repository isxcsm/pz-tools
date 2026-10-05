# Localization

[Documentation index](../README.md)

The app and the notes it shows inside the game come in 18 languages. English (`en-US`) is the
source text; every other language is a translation of it and has the same standing. All
languages ship with the app; nothing is downloaded or translated online.

## Where the text lives

| File | Holds |
| --- | --- |
| [`src/PzTools.App/Strings/<tag>/Resources.resw`](../../src/PzTools.App/Strings) | Every UI string, one folder per language tag |
| [`languages.tsv`](../../src/PzTools.Process.Contracts/Localization/languages.tsv) | One row per language: enum name, tag, native name, the three default backup names (generic, manual, automatic) and the four game-save notes (countdown, saved, failed, saving) |
| [`notices.tsv`](../../src/PzTools.GameBridge.Agent/notices.tsv) | The other notes shown over the character in the game (hotkeys, performance recording, next backup): a key column, then one column per language tag |
| [`LanguageCatalog.cs`](../../src/PzTools.Process.Contracts/LanguageCatalog.cs) | The `SupportedLanguage` enum, reading `languages.tsv`, parsing stored names, the Windows display language mapping |
| [`Localizer.cs`](../../src/PzTools.App/Localizer.cs) | Reads strings for the current language, falls back to English, sets the culture for dates and numbers |

The 18 tags: `cs-CZ`, `de-DE`, `en-US`, `es-ES`, `es-MX`, `fr-FR`, `id-ID`, `it-IT`, `ja-JP`,
`ko-KR`, `pl-PL`, `pt-BR`, `ru-RU`, `th-TH`, `tr-TR`, `uk-UA`, `zh-CN`, `zh-TW`.

## How the app picks a language

- `settings.toml` (in `%LOCALAPPDATA%\PzTools`) stores the choice as a tag under
  `[ui] language`. **Settings → Language** writes it.
- While the file has no language, the app uses the Windows display language: the same
  language if the app has it, otherwise the nearest variant (Spanish of Spain or of Latin
  America, Simplified or Traditional Chinese, Brazilian Portuguese), otherwise English.
- Stored values also accept the enum names (`French`) and `ko` and `en`. Anything else is
  rejected as invalid settings.
- `Localizer.SetLanguage` asks Windows' resource system for the language with English as
  the fallback, so a missing string shows in English. It also sets the .NET culture, so
  dates and numbers follow the language. Text built into WinUI controls follows Windows, not
  the app, because the app does not set `PrimaryLanguageOverride`.
- Log entries keep the text they were written with. When a stored entry is a whole string
  of any language, the **Logs** page shows it in today's language
  (`Localizer.Translate`).

## Text the workers and the game produce

| Text | Comes from | Language |
| --- | --- | --- |
| Default backup names (`Manual backup 12`) | `languages.tsv`, written by the backup worker into the repository | `ui.language` from `settings.toml`; without it `[naming] language` in the backup worker's configuration; without that the Windows display language. The CLI takes `--name-language`. |
| Game-save countdown and result notes | `languages.tsv`, compiled into the bridge at build time | The backup worker's, as for the backup names |
| Hotkey, recording and next-backup notes | `notices.tsv`, compiled into the bridge at build time | The app's language, sent with each request |

A stored backup name is never rewritten. The backup list shows a name nobody edited (a default
name in any language, with its number) in today's language.

Both TSV files are UTF-8 and compiled into the Java payload by
[`generate-bridge-languages.ps1`](../../scripts/generate-bridge-languages.ps1), so the game
and the .NET side read the same text. The game refuses a note in a language that has no
column in `notices.tsv`.

## Adding or changing a string

1. Write the English text in `en-US/Resources.resw`.
2. Add the same key, translated, to the other 17 `Resources.resw` files. Every file must
   have exactly the English key set, and no value may be empty.
3. Use it. A key named `Name.Property` sets that property on the XAML element with
   `x:Uid="Name"`. Code reads a key with `Localizer.Get("Key")` or
   `Localizer.Format("Key", ...)`.
4. Run the [checks](#checks).

When you change the meaning of an English string, update every translation in the same
change. The checks cannot tell a stale translation from a current one.

A note shown in the game is a row in `notices.tsv` with a value in every language column.
The key must match what the app sends (`GameNoticeCatalogTests` checks the keys the hotkeys
use). A number goes in as `{0}`, or `{0:time}` for seconds shown as minutes and seconds.

The default backup names are in two places: the columns of `languages.tsv`, and
`ManualBackupNameFormat`, `AutomaticBackupNameFormat` and `AutomaticSaveLabel` in each
`Resources.resw`. `check-localization.py` fails when they disagree.

### Rules for every language

- Keep the placeholders (`{0}`, `{1:N0}`) of the English text. Word order may change.
- Build a sentence from one string with placeholders, never by joining two strings in code.
  Word order and punctuation differ by language (*Expand {0}*, *{0} aufklappen*).
- Sizes and durations use the language's own unit symbols, the ones Windows uses (`Unit.*`:
  *Ko* and *Mo* in French, *КБ* and *мс* in Russian), after the number and a space. *FPS*
  stays as is.
- Keep *saving the game* and *creating a backup* distinct, and the current save apart from
  its backups.
- Keep the warnings on destructive actions, and never promise that an interrupted
  operation recovers by itself.
- File paths, mod names, game modes, names the player typed and raw diagnostic details are
  not translated.

## Adding a language

1. Add a member at the end of `SupportedLanguage` in `LanguageCatalog.cs`.
2. Add a row to `languages.tsv`: ten tab-separated fields, the enum name first, then the tag.
3. Add a column for the tag to `notices.tsv`, with every row filled in. No automated check
   covers this file's columns; without the column the game refuses the app's notes in
   that language.
4. Add `Strings/<tag>/Resources.resw` with every key.
5. If Windows has regional variants the app should map to it, extend
   `LanguageCatalog.ForCulture`.
6. Run the checks.

The language appears in **Settings → Language** by its native name; the list comes from the
catalogue. The documentation stays in English only.

## Checks

| Command | Checks |
| --- | --- |
| `python scripts/check-localization.py` | Every catalogue tag has a `Resources.resw` and every folder a tag; identical key sets; no duplicate keys or empty values; the same placeholders as English; every literal `Localizer.Get`/`Format` key and every error message key exists; backup names and game-save notes agree with `languages.tsv` |
| `dotnet test tests/PzTools.Backup.Tests -c Release --filter "FullyQualifiedName~LocalizationTests\|FullyQualifiedName~UserFacingMessageTests\|FullyQualifiedName~GameNoticeCatalogTests"` | The enum matches the catalogue, .NET can parse every format string, a language round-trips through the app settings and the backup worker, old stored names still read, every error message exists and formats in every language, every note the hotkeys send is in `notices.tsv` |
| `pwsh scripts/test-ui-smoke.ps1` | Includes the localization smoke ([`PzTools.LocalizationSmoke`](../../tests/PzTools.LocalizationSmoke)): loads every string of every language through the real WinUI resource system, switching languages forward and back, and compares it with the `.resw` file |

The localization smoke runs on its own with the `Strings` folder and a result file as its
arguments. It writes `PASS` or `FAIL` with the reason into that file:

```powershell
dotnet build tests/PzTools.LocalizationSmoke -c Debug
& tests/PzTools.LocalizationSmoke/bin/Debug/net10.0-windows10.0.19041.0/win-x64/PzTools.LocalizationSmoke.exe `
    (Resolve-Path src/PzTools.App/Strings).Path "$PWD/artifacts/localization-smoke.txt"
```

None of these check the wording, the layout, or whether the game's font has the
characters. Read new text in the running app, in context, and look at the in-game notes
in the game.

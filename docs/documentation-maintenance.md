# Documentation maintenance / 문서 유지보수

[Documentation index / 문서 목차](README.md) · [User guide / 사용 안내](../README.md)

## Content rules / 작성 기준

Describe what the tool does, the supported conditions and the next action. Do not
use survival slogans, anthropomorphism or claims that the tool guarantees a safe
return. A shorter introduction is useful only if operating instructions and warnings
remain available in every supported language.

도구의 기능·지원 조건·사용자가 할 일을 설명하세요. 생존을 대신 책임진다는 식의
홍보 문구나 안전을 보장하는 표현은 쓰지 않습니다. 소개를 줄여도 사용 절차와
경고를 특정 언어에서만 생략하지 않습니다.

All 18 README entry points have the same stable section anchors and direct reference
links: features, installation, retention/deletion, game saving, restore/ZIP, character
recovery, storage/compatibility, troubleshooting, building and documentation. English
and Korean are not substitutes for the other guides. Shared neutral Spanish phrasing
is appropriate where Spain and Latin American usage does not differ.

Preserve these distinctions in every language:

- A game save finishing is not a backup finishing. Per-file verification is not a
  single-instant snapshot of the whole world.
- Manual backups are exempt from automatic-count trimming, not from explicit deletion
  or cleanup after the original save disappears.
- Restoration replaces current files and loses later progress. After interruption,
  check PZ Tools before loading the save; do not promise automatic rollback.
- Character recovery edits the current inactive save and creates no extra user backup.
  Preserve the supported build/world/player limits and inventory-recovery restrictions.
- Incompatible backup data is not automatically converted or erased. A new empty backup
  folder is different from deleting the game save or deleting only `repository.db`.
- Source archives, SDK/build requirements, runtime requirements and runnable packages
  are different. Do not invent a release asset, installer, signature or download URL.

## References and history / 링크와 과거 기록

Use relative links to files inside this repository so forks, branches and local clones
keep working. Prefer direct reference pages over sending every reader through the
English README. Label the target's actual language. The [index](README.md) lists every
technical document and every language guide; technical pages link back to it.

Use explicit section IDs for translated guides. Keep the old English and Korean public
README anchors when rewriting headings. Historical plans, verification reports and
benchmarks retain their original values and scope; label them rather than presenting
old measurements as current claims.

Current facts should be checked against their source, not copied from an old README:

| Claim | Source |
| --- | --- |
| Supported languages and default name prefixes | [Language catalog](../src/PzTools.Process.Contracts/Localization/languages.tsv) |
| Runtime requirement and publishing behavior | [Publish script](../scripts/publish-app.ps1) |
| Administrator request | [App manifest](../src/PzTools.App/app.manifest) |
| Backup defaults | [App settings](../src/PzTools.App.Core/AppSettings.cs) |
| Game and recovery limits | [Save bridge](save-bridge.md), [character recovery](character-recovery.md) |
| Storage compatibility | [Repository format](repository-format.md) and [schema](../src/PzTools.Backup.Storage/Repository/RepositorySchema.cs) |

## Automated checks / 자동 검사

Run from the repository root with Python 3.10 or later:

```powershell
python scripts/test-documentation-checker.py
python scripts/check-documentation.py
```

The [CI workflow](../.github/workflows/windows.yml) runs these checks once on Linux. The existing `pwsh scripts/test-readme-links.ps1` entry point calls the same
checker. Tests include injected missing pages/anchors, incomplete guides, broken language
navigation and invalid local paths; a validator must fail on broken input, not just pass
on the current repository.

The checker uses the standard library, reads repository files only, and does not make
network requests. It covers the Markdown used here: inline and reference links, HTML
`href`/`src`, explicit anchors and ATX/Setext heading anchors, including duplicate headings
and escaped/nested parentheses in link destinations. Fenced and inline code examples are
not treated as live links. External URLs are reported but not fetched. The parser is not
a complete implementation of every GitHub-Flavored Markdown extension.

Topic and link parity establish structure, not translation accuracy. Automated checks
cannot prove that a warning means the same thing in every language, that a translated
sentence sounds natural to every native speaker, or that layout is good on every screen.
Native-speaker review remains separate. Do not add word-count thresholds as a substitute
for the operating and safety information listed above.

구조 검사나 글자 수만으로 번역의 정확성을 증명할 수는 없습니다. 원어민 감수와
실제 화면 확인 여부를 자동 검사 결과와 구분해 기록하세요.

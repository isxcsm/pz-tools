# Documentation maintenance

[Documentation index](README.md) · [User guide](../README.md)

## Writing and scope

Keep one English user guide in the root `README.md` and write its linked documentation
in English. Do not add translated guides or parallel language sections. The app's
multilingual interface, backup names and game-save notices remain independent; preserve
their catalog and resources.

Lead with what the user needs to do. Keep the README concise, with installation,
everyday operations and essential warnings. Put implementation details and precise
compatibility limits in their reference pages. Link to those pages where needed and
use the documentation index for the full reference list. Avoid repeated warnings,
promotional slogans and claims that the tool guarantees a safe return.

Preserve these operating distinctions in the guide and its references:

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

## Links and recorded facts

Use relative links to files inside this repository so forks, branches and local clones
keep working. The [index](README.md) lists the root guide, every technical document and
third-party notices; technical pages link back to it. Keep explicit section IDs stable
and update heading links when renaming sections. Historical plans, verification reports
and benchmarks retain their original values and scope. Edit their explanatory prose
without changing measurements, identifiers, commands or source paths, and label dated
results rather than presenting them as current claims.

Current facts should be checked against their source, not copied from an old README:

| Claim | Source |
| --- | --- |
| UI languages and default name prefixes | [Language catalog](../src/PzTools.Process.Contracts/Localization/languages.tsv) |
| Runtime requirement and publishing behavior | [Publish script](../scripts/publish-app.ps1) |
| Administrator request | [App manifest](../src/PzTools.App/app.manifest) |
| Backup defaults | [App settings](../src/PzTools.App.Core/AppSettings.cs) |
| Game and recovery limits | [Save bridge](save-bridge.md), [character recovery](character-recovery.md) |
| Storage compatibility | [Repository format](repository-format.md) and [schema](../src/PzTools.Backup.Storage/Repository/RepositorySchema.cs) |

## Automated checks

Run from the repository root with Python 3.10 or later:

```powershell
python scripts/test-documentation-checker.py
python scripts/check-documentation.py
```

The [CI workflow](../.github/workflows/windows.yml) runs these checks once on Linux.
`pwsh scripts/test-readme-links.ps1` calls the same checker. It validates the single root
guide's ten topic sections, essential references, runtime requirements and build commands;
checks local links, index coverage and backlinks; and rejects parallel
`docs/*/README.md` guides. It does not read or interpret the UI language catalog.
Regression tests cover invalid input and a valid English documentation tree with no UI
catalog or resources. Authored links to UI source files still require valid targets.

The checker uses the standard library, reads repository files only, and does not make
network requests. It covers the Markdown used here: inline and reference links, HTML
`href`/`src`, explicit anchors and ATX/Setext heading anchors, including duplicate headings
and escaped/nested parentheses in link destinations. Fenced and inline code examples are
not treated as live links. External URLs are counted but not fetched. The parser is not
a complete implementation of every GitHub-Flavored Markdown extension.

Review English explanations and warnings manually: structural checks cannot establish
clarity or accuracy. Unicode identifiers, file paths and quoted UI values can be valid,
so keep Unicode parser tests and do not use ASCII-only or word-count thresholds to
enforce the documentation policy.

# Documentation maintenance

[Documentation index](../README.md) · [User guide](../../README.md)

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

## Where a page goes

Decide first who the page is for. There are three kinds, and one page should be one kind.

| Kind | Reader and question | Where |
| --- | --- | --- |
| Use | Someone running the app: what does this do, how do I use it, what should I watch out for? | `docs/`, listed under *Using PZ Tools* in the [index](../README.md) |
| Design | Someone reading or changing the code: how does this part work and why is it built this way? | `docs/`, listed under *How it works* |
| History | Someone looking back: what was measured, reviewed or planned at the time? | `docs/history/`, listed under *History and measurements* |

A topic with both a use side and a design side gets the use side first, and the design
side under a later heading or on its own page. A result that is only true of one build
or one measurement run is history, even when it is recent. History pages are not
updated when the code changes; they carry the banner that says so. The folder has no
`README.md` of its own: the checker below rejects `docs/*/README.md` as a parallel guide.

New terms go into the [glossary](../design/glossary.md) when they are first used on a second page.
A new part of the system gets a line in the [overview](../design/overview.md).

## Writing for the reader

- **Start with what it is.** The first paragraph says what the feature or part does and
  for whom, in words a newcomer knows. Contract numbers, class names and protocol fields
  come later, if at all.
- **Say what happens before what does not.** Collect limits, non-goals and "does not"
  statements in one section per page instead of spreading them through every paragraph.
- **Define or link every project term** on its first use on a page: link the
  [glossary](../design/glossary.md) entry or explain it in a clause. Do not coin a new name for
  something that already has one.
- **Keep paragraphs short.** One idea per paragraph, a few sentences each. Use a table
  or a numbered list for steps, states and options. Wrap source lines at about 90
  characters so diffs stay readable.
- **Keep volatile numbers in one place.** Protocol and schema versions, counts of files
  or settings, and defaults belong on the page that owns them. Other pages link there
  instead of repeating the number.
- **Write about the software, not about the change.** "Backups skip paused time" rather
  than "the change removed…" or "this now…". How it used to be belongs in history.
- **Use a common page order**: what it is, everyday behaviour, when it does not work
  or is limited, how it works inside, how it is verified. Leave out sections that would
  be empty.

## Writing a guide

Guides in `docs/guides/` walk a player through one task. Write them the way you would
explain the task to a friend sitting next to you, and test every sentence:

1. **Would the reader wonder about this here?** If not, cut it. Answering a question
   nobody asked raises a new worry ("Java is included" makes people wonder whether they
   need Java).
2. **Does it change what the reader does or expects?** If not, cut it.
3. **Is it something the reader can't see?** Internals (the change journal, the garbage
   collector) go in only when the screen shows them or the reader must decide something,
   and then in plain words.
4. **One fact per sentence.** Don't join unrelated facts with "and".
5. **Would you say it out loud like that?** No summary openers that repeat the headings,
   no colon-chopped lines ("Mode: on."), no reason tacked onto every sentence.

Give the reasons a reader would ask for (why administrator rights, why backups stopped),
and leave out the ones nobody would. Name UI elements exactly as the English interface
shows them, in bold. Mark a needed picture as `[Screenshot: what it must show]` until one
is taken.

## Links and recorded facts

Use relative links to files inside this repository so forks, branches and local clones
keep working. The [index](../README.md) lists the root guide, every technical document and
third-party notices; technical pages link back to it. Keep explicit section IDs stable
and update heading links when renaming sections. Pages under `docs/history/` are also
listed in the index and link back to it. Historical plans, verification reports
and benchmarks retain their original values and scope. Edit their explanatory prose
without changing measurements, identifiers, commands or source paths, and label dated
results rather than presenting them as current claims.

Current facts should be checked against their source, not copied from an old README:

| Claim | Source |
| --- | --- |
| UI languages and default name prefixes | [Language catalog](../../src/PzTools.Process.Contracts/Localization/languages.tsv) |
| Runtime requirement and publishing behavior | [Publish script](../../scripts/publish-app.ps1) |
| Administrator request | [App manifest](../../src/PzTools.App/app.manifest) |
| Backup interval and retention defaults | [App settings](../../src/PzTools.App.Core/AppSettings.cs) |
| Backup worker defaults | [Backup worker template](../../config/defaults/backup-worker/default.toml) |
| Version shown in the app | [Home page](../../src/PzTools.App/HomePage.xaml) footer |
| Game and recovery limits | [Game bridge](../design/game-bridge.md), [character recovery](../design/character-recovery.md) |
| Storage compatibility | [Repository format](../design/repository-format.md) and [schema](../../src/PzTools.Backup.Storage/Repository/RepositorySchema.cs) |

## Automated checks

Run from the repository root with Python 3.10 or later:

```powershell
python scripts/test-documentation-checker.py
python scripts/check-documentation.py
```

The [CI workflow](../../.github/workflows/windows.yml) runs these checks once on Linux.
`pwsh scripts/test-readme-links.ps1` calls the same checker. It validates that the single
root guide keeps its required topic sections (more may be added; every section must explain
something), its essential references and its runtime requirements and download links;
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

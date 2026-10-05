# Documentation

[Documentation index](../README.md)

The documentation is English only. The app's interface, backup names and in-game notices have
their own languages; see [Localization](localization.md). Don't add translated pages.

## Where a page goes

Decide first who reads the page. One page serves one reader.

| Folder | Reader | What goes in |
| --- | --- | --- |
| `README.md` (root) | Anyone landing on the repository | What PZ Tools does, how to install and update it, its limits, building, license. Short; each topic links on. |
| `docs/guides/` | A player doing one task | Steps from start to finish, what they'll see, what to do when it fails |
| `docs/reference/` | A player who wants the detail | What each setting, screen, state, file or command is. Tables first. |
| `docs/design/` | Someone changing the code, person or AI agent | How a part works and why: data, invariants, failure handling, decisions and the alternatives rejected |
| `docs/contributing/` | A contributor | Building, testing, publishing, documentation and translation |
| `docs/history/` | Someone looking back | Measurements, reviews and plans of their time. Never updated. |

A fact lives in one place. A guide links to the reference page for the detail, and a reference
page links to the design page for how it works. A result true of one build or one measurement
run is history, even when it's recent. How something used to be belongs in the release notes
or in history, not in a current page.

New terms go into the [glossary](../design/glossary.md) when a second page uses them. A new part
of the system gets a line in the [overview](../design/overview.md).

## Writing

These hold for every page.

- **Say what happens, plainly.** Write the way you'd explain it to a colleague. One fact per
  sentence. Don't join unrelated facts with "and".
- **No padding.** No openers that repeat the headings, no "this document describes", no
  colon-chopped fragments ("Mode: on."), no reason tacked onto every sentence. Words like
  robust, seamless, comprehensive, leverage and ensure usually stand in for saying what
  happens; say it instead.
- **Give the reasons a reader would ask for**, and leave out the ones nobody would.
- **Name UI elements exactly as the English interface shows them**, in bold. The strings are
  in [Resources.resw](../../src/PzTools.App/Strings/en-US/Resources.resw).
- **Keep volatile numbers on the page that owns them**: defaults, limits, versions, counts.
  Other pages link there.
- **Use tables** for settings, states, messages, files and commands, and numbered lists for
  steps. Wrap lines at about 95 characters so diffs stay readable.
- **Check every fact against the code** before writing it, and again when the code changes.

### Guides

Write a guide the way you'd walk a friend through the task, and test every sentence:

1. **Would the reader wonder about this here?** If not, cut it. Answering a question nobody
   asked raises a new worry ("Java is included" makes people wonder whether they need Java).
2. **Does it change what the reader does or expects?** If not, cut it.
3. **Is it something the reader can't see?** Internals go in only when the screen shows them
   or the reader must decide something, and then in plain words.
4. **One fact per sentence.**
5. **Would you say it out loud like that?**

Open with the situation the reader is in, not with the feature. Players resent being told they
made a mistake; open on what the game did to them (a crash, a bug, a broken mod) rather than on
undoing their own choices.

Mark a picture that is still to be taken as `[Screenshot: what it must show]`. Pictures and
clips live in `docs/media/`.

### Reference pages

Start each section with what the thing is, then a table. Name what the player sees, not
classes or files in the code. Link the guide for step-by-step instructions and the design page
for how it works.

### Design pages

Write for someone about to change that part of the code. Cover what it does, the data it
keeps, the invariants that must hold, how failures and interruptions are handled, and the
decisions with the alternatives that were rejected. Link source files where they help find the
code; don't paste code. Collect limits and non-goals in one section.

## Links

Use relative links inside the repository so forks, branches and clones keep working. Every page
outside `docs/guides/` starts with a link back to the [index](../README.md), and the index lists
every page. Keep explicit `<a id="...">` anchors stable, and fix the links into a heading when you
rename it.

History pages keep their original values. Edit their prose if needed, but not their
measurements, identifiers, commands or source paths.

Where to check a fact:

| Claim | Source |
| --- | --- |
| UI text | [Resources.resw](../../src/PzTools.App/Strings/en-US/Resources.resw) |
| UI languages and default backup names | [Language catalog](../../src/PzTools.Process.Contracts/Localization/languages.tsv) |
| Settings and their defaults | [App settings](../../src/PzTools.App.Core/AppSettings.cs) |
| Backup worker defaults | [Backup worker template](../../config/defaults/backup-worker/default.toml) |
| Runtime requirement and what is published | [Publish script](../../scripts/publish-app.ps1) |
| Administrator request | [App manifest](../../src/PzTools.App/app.manifest) |
| Storage compatibility | [Repository format](../design/repository-format.md) and [schema](../../src/PzTools.Backup.Storage/Repository/RepositorySchema.cs) |

## Automated checks

Run from the repository root with Python 3.10 or later:

```powershell
python scripts/test-documentation-checker.py
python scripts/check-documentation.py
```

The [CI workflow](../../.github/workflows/windows.yml) runs both on Linux, and
`pwsh scripts/test-readme-links.ps1` calls the same checker. The checker:

- checks every local link and anchor in `README.md`, `THIRD_PARTY_NOTICES.md` and `docs/`,
  including the case of file names;
- requires the root README to keep its topic sections (each with some explanation, not only a
  link), its links to the main guides and reference pages, its runtime requirement and its
  download and issue links;
- requires the index to list every page under `docs/`, and every page outside `docs/guides/`
  to link back to the index;
- rejects a `README.md` inside a `docs/` subfolder, so no second guide grows beside the root
  one.

It uses the standard library only, reads repository files only and fetches no URLs. It covers
the Markdown used here: inline and reference links, HTML `href` and `src`, explicit anchors,
and ATX and Setext heading anchors. Code blocks and inline code are not treated as links.

Structure is all it checks. Read your page again for accuracy and clarity; no script can.

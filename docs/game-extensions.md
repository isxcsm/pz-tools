# Game extensions — staged implementation

[Documentation index / 문서 목차](README.md) · [User guide / 사용 안내](../README.md)

## Status: foundation, not a completed seamless-save adapter

This branch adds the Game Extensions page and its first card, **Seamless Saving**
(`pztools.seamless-save`). The toggle persists a desired preference. It does **not**
activate an unvalidated game patch. The card and its settings dialog explicitly say
that no real-game save adapter has been qualified yet. Standard `save(true)` remains
in use according to the existing pre-backup-save setting; this extension never
silently enables or disables that setting. Do not publish this as a stutter fix.

## Ownership

- `PzTools.GameExtensions` targets plain `net10.0`: identifiers, curated catalog,
  independent preference storage and the save-provider capability/router. No WinUI,
  SQLite, game classes or platform process discovery dependencies.
- `PzTools.App.Core.GameExtensionController` publishes committed preferences through
  the existing revisioned view store. `GameExtensionsPage` only presents cards and
  sends commands; it never attaches to the game or runs a save.
- `PzTools.Zomboid.Backup` selects the standard provider when the optional provider
  is disabled, unavailable or its settings cannot be read. A failure after save
  admission is propagated, never retried with the standard provider.
- `PzTools.GameExtensions.Java` contains the game-class-free Java API and a bounded,
  single-owner checkpoint runtime. `PzTools.GameExtensions.SeamlessSave` is a separate
  module/build unit containing the version-adapter boundary. Its shipped adapter
  list is intentionally empty. No replacement game classes are distributed.

## Implemented checkpoint contract

A provider must capture mutable state on the designated game thread and return an
owned, detached snapshot. Only its commit and cleanup run on the writer. One operation
owns the runtime until both finish; a dequeued item is not a completion signal.
A write already in progress is not interrupted when the client cancels. Admission,
request/session/world identity, capture memory budget, failures and cleanup are explicit.
Capture itself is still synchronous: this foundation does not promise zero frame stalls.

The Java module/API JARs are built and staged by the existing worker graph but are
**not loaded into the game by this release**. The existing resident bootstrap and
wire protocol are unchanged. Dynamic package discovery, compatibility negotiation and
runtime SaveProvider invocation are follow-up work, not implemented capabilities.
The C# fallback gate deliberately reports `adapter-validation-required`.

## Preferences and UI

The independent `extensions/settings.json` lives beneath the existing data root.
Schema validation, a stable cross-process lock, atomic replacement and an expected
revision prevent silent overwrites. Unknown module preferences are preserved.
Corrupt optional preferences do not rewrite the file or suppress standard saving.
Desired enabled state is distinct from actual application; there is no Applied badge
without a qualified adapter. The current modal edits only this implemented preference,
not placeholder performance settings. Existing pre-backup-save off takes precedence.
The page uses the existing 18-locale RESW mechanism and does no periodic game polling.

## Validation

Run the focused C# `GameExtensionTests` and adjacent save-policy/resource tests.
`test-game-extensions.ps1` builds the standalone Java module and runs a small isolated
checkpoint harness; the normal bridge test setup calls it without a second managed test run.

The harness checks detached bytes, off-thread commit, exclusive ownership while a
writer is working, error propagation, disposal and rejection of an oversized capture.
It is not a real-game test or a frame-time measurement. No source-text/UI-layout
assertions, full-suite duplication or new CI workflow are added.

## Work still required before this mode can actually activate

1. Attribute drag cancellation and save stalls in a separate test world; do not assume
   skipping a thumbnail fixes them. Keep mandatory in-memory player/vehicle data.
2. Implement and qualify a Build 42.20 adapter: coherent capture of containers,
   players, discovered-but-undriven and virtual vehicles, Lua OnSave semantics,
   native save synchronization and explicit per-request write/error completion.
3. Connect the optional module loader and version/capability negotiation to the
   existing authenticated bridge without sharing the save-session slot with future
   long-lived mods. Unsupported optional code must not affect the standard provider.
4. Integrate an owned immutable backup input/lease if the adapter requires one;
   temporary snapshot file IDs/USN must never become the source save's checkpoint.
5. Verify restored content, toggle/failure/world-exit behavior and real frame times.
   Only then replace the validation gate with the qualified adapter capability.

No live game attach, save, user preference reset or repository migration is part of
this foundation change. General package discovery and hot code replacement are not
implemented merely to make the first card appear functional.

## Foundation verification on Windows

The Release solution including WinUI, native bootstrap and both Java JARs built with
zero warnings/errors. Focused C# extension, save-policy and localization tests passed
69/69 (no skips); ten cases cover the new management/router/projection behavior.
The Java 25 checkpoint harness passed. Both JARs in the app's staged worker directory
match their build-output SHA-256 hashes. These are local Windows build/test results,
not a published-distribution run or an interactive UI/game test. No real-game adapter,
restored-world equivalence, drag preservation or frame-time improvement is claimed.

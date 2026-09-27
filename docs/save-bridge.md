# Saving the game before a backup

[Documentation index](README.md) · [User guide](../README.md)

The bridge requests the original `GameWindow.save(true)` on the game thread before file capture. It uses Java Attach and a runtime hook; no Workshop mod, `-debug` launch option or game installation edit is required. Saving remains synchronous and can briefly pause gameplay. No seamless-save replacement is shipped.

## Settings and timing

**Save game before backup** is on by default. Turning it off captures on-disk data only; recent changes still in game memory may be missing. This does not disable independent runtime observation or vehicle controls.

**In-game save countdown** controls the overhead notices. For manual backups, it adds a five-second countdown. For periodic backups, preparation starts ahead of the deadline and shows only its final five seconds; a late connection skips elapsed numbers rather than adding another delay. The saving message appears at admission, followed by completion or failure. Other game notifications can replace the shared halo-note text.

The scheduler preparation lead defaults to eight seconds. Paused frames, attach latency and disk contention can delay execution: the deadline is not a hard real-time guarantee. Disabling notices removes the manual delay, but does not make a periodic backup run early.

**Game-save completion means the game call returned.** Capture and compression happen afterward; the app's progress card reports backup completion. Neither that return nor per-file verification guarantees an atomic world snapshot or hardware flush.

Settings apply to the next backup, not an in-flight request. Precedence is built-in defaults, worker TOML, app preferences, then explicit CLI overrides. Direct CLI game backups use `--save-game`; the generic engine remains usable without JVM integration.

## Admission and failures

Preparation holds the repository writer lease and runs before the scan/USN capture boundary.

- Manual preparation checks the selected save's current activity. A confirmed inactive save skips attachment; unknown activity still requires game-side validation. Explicit no-game, no-world and save-mismatch responses allow disk-only capture when active play is not required.
- Automatic wall-clock backups require active play. Those same inactive or mismatched-world responses skip the backup instead of authorizing disk-only capture.
- Pause-aware periodic work instead uses a runtime ticket and rechecks world identity, pause/sleep state, scheduling generation and the active-time deadline on the game thread. With saving disabled, a guarded probe still enforces admission without saving.
- A pre-save deferral preserves the periodic slot and creates no revision. Unsupported interfaces, ambiguous targets and failed or unknown save completion do not authorize capture or automatic replay.

A queued request has a configurable deadline (15 seconds by default). Cancellation or disconnect can cancel queued/countdown work, not a save that already started. The game call must return before ownership is released. Notice or recovery-stamp failures can be reported separately without skipping an otherwise valid save.

See [runtime scheduling](runtime-pause-backups.md) for active-time and recovery rules, and [character recovery](character-recovery.md) for the optional identity stamp written before saving.

## Compatibility and lifecycle

The adapter targets the inspected Build 42 / Java 25 single-player structure. Multiplayer, no-save modes, unsupported signatures and mismatched worlds are rejected. Game updates, manually modified binaries and other agents can affect compatibility.

Current integration uses **bootstrap API 10, extension host ABI 3 and save protocol 6**. An incompatible resident bootstrap requires a complete game restart. Compatible payload/module updates reload at an idle boundary, including when the app moves to another installation folder. App and worker files must come from one build. See [component reload](module-reload.md).

The bootstrap keeps one authenticated loopback listener and a minimal game-loop dispatcher for the JVM lifetime. It is reused, not reinstalled for every backup. Runtime observation, saving and extension control share that infrastructure while retaining separate ownership. The endpoint accepts bounded protocol commands, not arbitrary Lua or Java code.

The Windows native bootstrap loads the target JVM's own `jli.dll` before Java instrumentation. The bundled helper runtime is not loaded into the game. There is no remote-thread injection or fallback that edits game files.

## Code ownership

| Component | Responsibility |
| --- | --- |
| `PzTools.SaveBridge` | Discovery, authenticated requests, deadlines and result decoding |
| `PzTools.Zomboid.Backup` | Backup admission and preparation policy |
| `PzTools.SaveBridge.Agent` | Attach entry point, game adapter and in-JVM execution |
| `PzTools.SaveBridge.Native` | Windows JVMTI bootstrap |
| `build/SaveBridgePayload.targets` | Build and deployment integration |

The general backup engine receives a preparation callback; it has no JVM dependency. [Vehicle Drivetrain](game-extensions.md) uses a separate continuous control session and does not replace the save call.

## Building and publishing

Use a Windows x64 Java 25 JDK and Visual Studio x64 C++ tools. The game's trimmed Java runtime is not a build JDK.

```powershell
$jdk = 'C:\path\to\jdk-25'
dotnet build src/PzTools.Backup.Cli/PzTools.Backup.Cli.csproj -p:JdkPath="$jdk"
pwsh scripts/test-save-bridge.ps1 -JdkPath $jdk
pwsh scripts/publish-app.ps1 -JdkPath $jdk -Output artifacts/app-local
```

`JdkPath` takes precedence over `JAVA_HOME`; otherwise exactly one Java 25 JDK under `artifacts/toolchains` is selected. The regular worker build produces the Java/native payload and reduced Attach runtime. Game JARs are neither build dependencies nor distributed assets.

Bridge build output defaults to `artifacts/save-bridge/<Configuration>`. Use `SaveBridgeDirectory` in MSBuild, or `SaveBridgeOutput` in publishing scripts, when a running game still holds an older native DLL. Keep build output separate from an installed app.

The bridge test script uses a synthetic JVM. `GameSaveClient.RequestAsync(pid, savePath, save: false)` performs connection/world checks without saving. Real-game save tests require a disposable world and remain separate from automated fixtures.

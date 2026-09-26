#!/usr/bin/env python3
"""Small offline CI selector. Unknown changes run Windows tests, never skip silently."""
import json
import os
import subprocess


def plan(paths, *, full=False, manual=False, benchmarks=False):
    paths = set(paths)
    # Only these known non-code files may skip Windows. Be conservative for new paths.
    def docs_only(path):
        return (path.startswith("docs/") or path.endswith(".md")
                or path in {".gitignore", ".gitattributes"})

    infrastructure = any(path.startswith((".github/", "build/"))
                         or path.endswith((".csproj", ".props", ".targets", ".proj", ".sln"))
                         or path in {"global.json", "NuGet.config", "nuget.config"}
                         for path in paths)
    publish = full or infrastructure or any(
        path.startswith(("config/defaults/", "config/game-extensions/", "scripts/publish-"))
        or (path.startswith("src/") and any(part in path for part in (".Cli/", ".Runner/", ".Scheduler/")))
        or (path.startswith("tests/") and any(part in path for part in ("IntegrationTests", "Distribution", "StateStartup")))
        for path in paths)
    bridge = full or publish or any(
        path.startswith(("src/PzTools.SaveBridge", "tests/save-bridge/",
                         "src/PzTools.GameExtensions", "config/game-extensions/", "tests/game-extensions", "scripts/test-game-extensions",
                         "src/PzTools.Backup.Engine/", "src/PzTools.Zomboid.Backup/",
                         "src/PzTools.Scheduling/", "src/PzTools.Process.Hosting/",
                         "src/PzTools.Process.Contracts/", "scripts/build-save-bridge",
                         "scripts/test-save-bridge", "scripts/generate-bridge"))
        or path.endswith(("GameSaveClientTests.cs", "GameSaveClientExtensionsTests.cs", "GameRuntimeBridgeTests.cs", "RuntimeExtensionIntegrationTests.cs", "ExtensionVersionTests.cs")) for path in paths)
    return dict(windows=full or (manual and not benchmarks) or any(not docs_only(path) for path in paths),
                publish=publish, bridge=bridge, benchmarks=benchmarks)


def main():
    event = os.environ.get("GITHUB_EVENT_NAME", "workflow_dispatch")
    full = os.environ.get("CI_FULL", "false").lower() == "true" or event == "push"
    benchmarks = os.environ.get("CI_BENCHMARKS", "false").lower() == "true"
    paths = []
    if event == "pull_request":
        # checkout's PR merge commit, depth 2: compare against its actual base parent.
        # Include both names of renames. A missing parent is an error, not an empty diff.
        changed = subprocess.check_output([
            "git", "diff", "--name-only", "--no-renames", "-z", "HEAD^1", "HEAD"])
        paths = changed.decode("utf-8").rstrip("\0").split("\0") if changed else []
    result = plan(paths, full=full, manual=event == "workflow_dispatch", benchmarks=benchmarks)
    print(json.dumps(result, sort_keys=True))
    if output := os.environ.get("GITHUB_OUTPUT"):
        with open(output, "a", encoding="utf-8") as target:
            for key, value in result.items():
                target.write(f"{key}={str(value).lower()}\n")


if __name__ == "__main__":
    main()

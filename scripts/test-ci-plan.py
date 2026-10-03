#!/usr/bin/env python3
"""Selector boundaries only; no GitHub API, SDK, or test framework installation."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("ci_plan", Path(__file__).with_name("ci-plan.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
plan = module.plan


class PlanTests(unittest.TestCase):
    def test_docs_skip_windows(self):
        self.assertFalse(plan(["docs/configuration.md", "README.md"])["windows"])

    def test_ui_runs_managed_tests_without_bridge_or_publish(self):
        result = plan(["src/PzTools.App/SettingsPage.xaml.cs"])
        self.assertTrue(result["windows"])
        self.assertFalse(result["bridge"] or result["publish"])

    def test_engine_and_bridge_keep_jvm_tests(self):
        for path in ["src/PzTools.Backup.Engine/StableFileCapturer.cs",
                     "src/PzTools.GameBridge.Agent/java/pztools/bridge/AgentEntry.java",
                     "tests/game-bridge/zombie/GameWindow.java"]:
            with self.subTest(path=path):
                self.assertTrue(plan([path])["bridge"])

    def test_packaging_and_worker_changes_publish(self):
        for path in ["build/AppWorkers.targets", "src/PzTools.App/PzTools.App.csproj",
                     "scripts/publish-app.ps1", "src/PzTools.State.Scheduler/Program.cs",
                     ".github/workflows/windows.yml"]:
            with self.subTest(path=path):
                result = plan([path])
                self.assertTrue(result["windows"] and result["publish"] and result["bridge"])

    def test_unknown_and_mixed_changes_are_not_ignored(self):
        self.assertTrue(plan(["future-tool/input.json"])["windows"])
        self.assertTrue(plan(["README.md", "src/PzTools.Projections/ViewModels.cs"])["windows"])

    def test_full_and_manual_modes(self):
        self.assertTrue(all(plan([], full=True, benchmarks=True).values()))
        self.assertTrue(plan([], manual=True)["windows"])
        self.assertFalse(plan([], manual=True, benchmarks=True)["windows"])


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Unit and negative-control tests for the Swift 6 readiness gate."""

import json
from pathlib import Path
import tempfile
import unittest

import swift6_readiness as gate


REPO = Path("/repo")
DEPRECATION = (
    "/repo/Sources/WallpaperApp/Playback/WallpaperSnapshot.swift:41:21: "
    "warning: 'CGWindowListCreateImage' was deprecated in macOS 15.0 "
    "[#DeprecatedDeclaration]"
)
FRONTEND = (
    "/toolchain/swift-frontend -frontend -c -module-name WallpaperApp "
    "/repo/Sources/WallpaperApp/Playback/WallpaperSnapshot.swift"
)


def allowance(**overrides):
    values = {
        "item": "product:DynamicWallpaper",
        "path": "Sources/WallpaperApp/Playback/WallpaperSnapshot.swift",
        "line": 41,
        "symbol": "CGWindowListCreateImage",
        "group": "DeprecatedDeclaration",
        "count": 1,
    }
    values.update(overrides)
    return gate.Allowance(**values)


def item(name="product:DynamicWallpaper", *, kind="product", selection="DynamicWallpaper",
         modules=("WallpaperApp",)):
    return gate.InventoryItem(name, kind, selection, tuple(modules))


class DiagnosticParserTests(unittest.TestCase):
    def parse(self, output, name="product:DynamicWallpaper"):
        return gate.parse_diagnostics(name, output, REPO)

    def test_clean_compile_and_operational_warning_are_not_diagnostics(self):
        output = "warning: dependency cache disabled\nBuilding for debugging...\nBuild complete!\n"
        self.assertEqual(self.parse(output), ())
        self.assertEqual(gate.audit_diagnostics((), ()), ())

    def test_exact_deprecation_is_normalized_and_allowed(self):
        output = f"{FRONTEND}\n\x1b[33m{DEPRECATION}\x1b[0m\n"
        diagnostics = self.parse(output)
        self.assertEqual(len(diagnostics), 1)
        self.assertEqual(diagnostics[0].path,
                         "Sources/WallpaperApp/Playback/WallpaperSnapshot.swift")
        self.assertEqual(diagnostics[0].group, "DeprecatedDeclaration")
        self.assertEqual(diagnostics[0].severity, "warning")
        self.assertEqual(gate.audit_diagnostics(diagnostics, (allowance(),)), diagnostics)

    def test_interleaved_build_prefix_keeps_the_absolute_source_path(self):
        output = f"builtin-SwiftPer{DEPRECATION}\n"
        diagnostics = self.parse(output)
        self.assertEqual(diagnostics[0].path,
                         "Sources/WallpaperApp/Playback/WallpaperSnapshot.swift")
        self.assertEqual(gate.audit_diagnostics(diagnostics, (allowance(),)), diagnostics)

    def test_wrong_allowance_fields_and_stale_allowance_fail(self):
        diagnostics = self.parse(f"{FRONTEND}\n{DEPRECATION}\n")
        cases = (
            allowance(item="target:WallpaperApp"),
            allowance(path="Sources/Other.swift"),
            allowance(line=42),
            allowance(symbol="OtherAPI"),
            allowance(group="Concurrency"),
            allowance(count=2),
        )
        for wrong in cases:
            with self.subTest(wrong=wrong), self.assertRaises(gate.GateFailure):
                gate.audit_diagnostics(diagnostics, (wrong,))
        with self.assertRaisesRegex(gate.GateFailure, "unused allowance"):
            gate.audit_diagnostics((), (allowance(),))

    def test_second_deprecation_missing_group_and_promoted_error_fail(self):
        outputs = (
            f"{FRONTEND}\n{DEPRECATION}\n"
            "/repo/Sources/Other.swift:7:2: warning: 'Old' is deprecated [#DeprecatedDeclaration]\n",
            f"{FRONTEND}\n{DEPRECATION.removesuffix(' [#DeprecatedDeclaration]')}\n",
            f"{FRONTEND}\n{DEPRECATION.replace('warning:', 'error:')}\n",
        )
        for output in outputs:
            with self.subTest(output=output), self.assertRaises(gate.GateFailure):
                gate.audit_diagnostics(self.parse(output), (allowance(),))

    def test_duplicate_rendering_is_deduplicated_only_inside_one_invocation(self):
        one = self.parse(f"{FRONTEND}\n{DEPRECATION}\n{DEPRECATION}\n")
        self.assertEqual(len(one), 1)
        two = self.parse(
            f"{FRONTEND}\n{DEPRECATION}\n"
            f"{FRONTEND} -primary-file /repo/Sources/Other.swift\n{DEPRECATION}\n"
        )
        self.assertEqual(len(two), 2)
        self.assertNotEqual(two[0].frontend_invocation, two[1].frontend_invocation)

    def test_same_real_diagnostic_in_separate_items_is_not_deduplicated(self):
        first = self.parse(f"{FRONTEND}\n{DEPRECATION}\n", "product:DynamicWallpaper")
        second = self.parse(f"{FRONTEND}\n{DEPRECATION}\n", "target:WallpaperApp")
        self.assertEqual(len((*first, *second)), 2)
        allowed = (
            allowance(item="product:DynamicWallpaper"),
            allowance(item="target:WallpaperApp"),
        )
        self.assertEqual(len(gate.audit_diagnostics((*first, *second), allowed)), 2)

    def test_malformed_compiler_diagnostic_is_explicit(self):
        with self.assertRaisesRegex(gate.GateFailure, "malformed diagnostic"):
            self.parse(f"{FRONTEND}\n/repo/Sources/X.swift:bad: warning: broken\n")

    def test_clang_source_and_header_warnings_are_retained_and_rejected(self):
        for suffix in ("c", "cc", "cpp", "cxx", "m", "mm", "h", "hh", "hpp", "hxx", "inc"):
            with self.subTest(suffix=suffix):
                path = f"Sources/MPVBridge/Bridge.{suffix}"
                output = f"/repo/{path}:10:3: warning: unused variable 'value' [-Wunused-variable]\n"
                diagnostics = self.parse(output, "target:MPVBridge")
                self.assertEqual(len(diagnostics), 1)
                self.assertEqual(diagnostics[0].path, path)
                self.assertEqual(diagnostics[0].severity, "warning")
                with self.assertRaisesRegex(gate.GateFailure, "unexpected diagnostics"):
                    gate.audit_diagnostics(diagnostics, ())

    def test_malformed_clang_diagnostic_is_explicit(self):
        for suffix in ("mm", "h"):
            with self.subTest(suffix=suffix), self.assertRaisesRegex(
                    gate.GateFailure, "malformed diagnostic"):
                self.parse(f"/repo/Sources/MPVBridge/Bridge.{suffix}:bad: warning: broken\n")


class InventoryAndCommandTests(unittest.TestCase):
    def setUp(self):
        self.dump = {
            "products": [
                {"name": "App", "targets": ["AppTarget"]},
                {"name": "Tool", "targets": ["ToolTarget"]},
            ],
            "targets": [
                {"name": "Core", "type": "regular"},
                {"name": "AppTarget", "type": "executable"},
                {"name": "ToolTarget", "type": "executable"},
                {"name": "CoreTests", "type": "test"},
                {"name": "AppTests", "type": "test"},
            ],
        }

    def test_inventory_accounts_for_products_targets_tests_and_probe_once(self):
        inventory = gate.inventory_from_dump(self.dump)
        self.assertEqual([entry.name for entry in inventory], [
            "product:App", "product:Tool", "target:AppTarget", "target:Core",
            "target:ToolTarget", "tests:all", "supplemental:ScreenSaverProbePlaybackTiming",
        ])
        tests = next(entry for entry in inventory if entry.kind == "tests")
        self.assertEqual(tests.modules, ("AppTests", "CoreTests"))
        self.assertEqual(sum(entry.kind == "supplemental" for entry in inventory), 1)

    def test_commands_are_isolated_reproducible_and_keep_exact_flag_tail(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            commands = gate.command_specs(
                gate.inventory_from_dump(self.dump), root, REPO,
                Path("/SDKs/MacOSX.sdk"), "arm64-apple-macosx14.0")
            self.assertEqual(len({spec.scratch for spec in commands}), len(commands))
            for spec in commands:
                self.assertEqual(spec.environment["LC_ALL"], "C")
                self.assertEqual(spec.environment["LANG"], "C")
                self.assertEqual(spec.environment["TERM"], "dumb")
                self.assertNotIn("SWIFT_SUPPRESS_WARNINGS", spec.environment)
                self.assertIn("-v", spec.command)
                self.assertIn("-swift-version", spec.command)
                self.assertIn("5", spec.command)
                for child in ("scratch", "cache", "config", "security"):
                    self.assertTrue(any(str(spec.root / child) in argument
                                        for argument in spec.command) or
                                    spec.item.kind == "supplemental" and child != "scratch")
            swiftpm = next(spec for spec in commands if spec.item.kind == "product")
            self.assertEqual(list(swiftpm.command[-len(gate.STRICT_FLAGS):]), gate.STRICT_FLAGS)
            self.assertIn("--product", swiftpm.command)
            tests = next(spec for spec in commands if spec.item.kind == "tests")
            self.assertIn("--build-tests", tests.command)
            probe = next(spec for spec in commands if spec.item.kind == "supplemental")
            self.assertIn("Tests/ScreenSaverProbeHarness/PlaybackTiming.swift", " ".join(probe.command))
            self.assertIn("scripts/feasibility/screensaver/ProbePlayback.swift", " ".join(probe.command))
            self.assertIn("-framework", probe.command)

    def test_clang_compile_command_is_module_evidence_for_c_targets(self):
        output = (
            "clang -c '-fmodule-name=MPVBridge' /repo/Sources/MPVBridge/Bridge.m\n"
            "clang -c \"-fmodule-name=WebWallpaperBridge\" /repo/Sources/WebWallpaperBridge/Bridge.mm\n"
        )
        self.assertEqual(gate._module_evidence(output), {"MPVBridge", "WebWallpaperBridge"})


class FakeRunner:
    def __init__(self, mutate=None):
        self.mutate = mutate
        self.seen = []

    def __call__(self, spec, timeout):
        self.seen.append((spec, timeout))
        output = "\n".join(
            f"/toolchain/swift-frontend -frontend -c -module-name {module} /repo/{module}.swift"
            for module in spec.item.modules
        )
        result = gate.RunResult(0, output, False)
        return self.mutate(spec, result) if self.mutate else result


class GateNegativeControlTests(unittest.TestCase):
    def setUp(self):
        self.dump = {
            "products": [{"name": "App", "targets": ["AppTarget"]}],
            "targets": [
                {"name": "Core", "type": "regular"},
                {"name": "AppTarget", "type": "executable"},
                {"name": "AppTests", "type": "test"},
            ],
        }
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def run_gate(self, runner):
        return gate.execute_gate(
            self.dump, (), self.root, REPO, Path("/SDKs/MacOSX.sdk"),
            "arm64-apple-macosx14.0", runner=runner, timeout=300)

    def test_fake_runner_green_path_records_complete_evidence(self):
        runner = FakeRunner()
        report = self.run_gate(runner)
        self.assertEqual(report["unexpected_diagnostics"], [])
        self.assertEqual(report["allowed_diagnostics"], [])
        self.assertEqual(report["inventory_count"], len(runner.seen))
        self.assertTrue(all(timeout == 300 for _, timeout in runner.seen))
        self.assertTrue(all(Path(entry["log"]).is_file() for entry in report["items"]))

    def test_successful_clang_compile_with_warning_fails_gate(self):
        for suffix in ("mm", "h"):
            def mutate(spec, result, suffix=suffix):
                if spec.item.name != "target:Core":
                    return result
                return gate.RunResult(0,
                    "clang -c -fmodule-name=Core /repo/Sources/Core/Bridge.mm\n"
                    f"/repo/Sources/Core/Bridge.{suffix}:10:3: warning: unused variable [-Wunused-variable]\n",
                    False)
            with self.subTest(suffix=suffix), self.assertRaisesRegex(
                    gate.GateFailure, "unexpected diagnostics"):
                self.run_gate(FakeRunner(mutate))

    def test_missing_product_target_or_test_evidence_fails(self):
        for missing_kind in ("product", "target", "tests"):
            def mutate(spec, result, missing_kind=missing_kind):
                if spec.item.kind == missing_kind:
                    return gate.RunResult(0, "Build complete!", False)
                return result
            with self.subTest(kind=missing_kind), self.assertRaisesRegex(
                    gate.GateFailure, "missing module evidence"):
                self.run_gate(FakeRunner(mutate))

    def test_reused_scratch_nonzero_timeout_and_malformed_output_fail(self):
        inventory = gate.inventory_from_dump(self.dump)
        specs = list(gate.command_specs(
            inventory, self.root, REPO, Path("/SDKs/MacOSX.sdk"),
            "arm64-apple-macosx14.0"))
        specs[1] = gate.CommandSpec(
            specs[1].item, specs[0].root, specs[0].scratch,
            specs[1].command, specs[1].environment)
        with self.assertRaisesRegex(gate.GateFailure, "scratch root"):
            gate.validate_isolation(tuple(specs))

        cases = (
            (gate.RunResult(2, "compiler failed", False), "nonzero"),
            (gate.RunResult(124, "timed out", True), "timed out"),
            (gate.RunResult(0,
                "/toolchain/swift-frontend -frontend -c -module-name AppTarget /repo/App.swift\n"
                "/repo/X.swift:bad: warning: broken", False),
             "malformed diagnostic"),
        )
        for replacement, message in cases:
            def mutate(spec, result, replacement=replacement):
                return replacement if spec.item.kind == "product" else result
            with self.subTest(message=message), self.assertRaisesRegex(gate.GateFailure, message):
                self.run_gate(FakeRunner(mutate))

    def test_failure_report_keeps_all_items_and_parsed_diagnostics(self):
        expected_count = len(gate.inventory_from_dump(self.dump))
        diagnostic = (
            "/toolchain/swift-frontend -frontend -c -module-name AppTarget /repo/App.swift\n"
            "/repo/Sources/App.swift:9:3: error: unsafe transfer [#Concurrency]\n"
        )
        def mutate(spec, result):
            if spec.item.kind == "product":
                return gate.RunResult(1, diagnostic, False)
            return result
        runner = FakeRunner(mutate)
        with self.assertRaisesRegex(gate.GateFailure, "nonzero") as raised:
            self.run_gate(runner)
        report = raised.exception.report
        self.assertEqual(len(runner.seen), expected_count)
        self.assertEqual(len(report["items"]), expected_count)
        self.assertEqual(report["diagnostics"][0]["path"], "Sources/App.swift")
        self.assertTrue(Path(report["items"][0]["log"]).is_file())

    def test_stale_allowance_fails_through_full_gate(self):
        with self.assertRaisesRegex(gate.GateFailure, "unused allowance"):
            gate.execute_gate(
                self.dump, (allowance(item="product:App"),), self.root, REPO,
                Path("/SDKs/MacOSX.sdk"), "arm64-apple-macosx14.0",
                runner=FakeRunner(), timeout=300)

    def test_allowlist_loader_rejects_unknown_shape(self):
        path = self.root / "allow.json"
        path.write_text(json.dumps({"allowances": [{"item": "x", "extra": True}]}))
        with self.assertRaises(gate.GateFailure):
            gate.load_allowances(path)


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import plistlib
import json
import subprocess
import tempfile
import unittest


MODULE_PATH = Path(__file__).with_name("verify-isolated-candidate.py")
SPEC = importlib.util.spec_from_file_location("verify_isolated_candidate", MODULE_PATH)
candidate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(candidate)


class IsolatedCandidateTests(unittest.TestCase):
    def make_app(self, root: Path) -> Path:
        app = root / "Pristine.app"
        helper = app / "Contents/Frameworks/Helper.app"
        framework = app / "Contents/Frameworks/Fixture.framework"
        for bundle, identifier in ((app, "local.dynamicwallpaper.app"),
                                   (helper, "local.dynamicwallpaper.helper")):
            (bundle / "Contents").mkdir(parents=True, exist_ok=True)
            information = {"CFBundleIdentifier": identifier}
            if bundle == app:
                information["CFBundleExecutable"] = "DynamicWallpaper"
            with (bundle / "Contents/Info.plist").open("wb") as stream:
                plistlib.dump(information, stream)
        executable = app / "Contents/MacOS/DynamicWallpaper"
        executable.parent.mkdir(parents=True)
        executable.write_bytes(b"fixture executable")
        executable.chmod(0o755)
        framework.mkdir(parents=True)
        (framework / "fixture").write_bytes(b"framework")
        return app

    def test_prepare_copies_changes_only_outer_identity_and_signs_inside_out(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            pristine = self.make_app(root)
            original = candidate.tree_manifest(pristine)
            commands = []
            prepared = candidate.prepare_candidate(pristine, root / "Validation.app",
                configured_identifier="local.dynamicwallpaper.app", validation_token="test",
                runner=lambda command: commands.append(tuple(map(str, command))))
            self.assertEqual(candidate.read_bundle_identifier(pristine), "local.dynamicwallpaper.app")
            self.assertEqual(candidate.read_bundle_identifier(prepared),
                             "local.dynamicwallpaper.app.validation.test")
            signed = [Path(command[-1]).name for command in commands if command[0] == "codesign"
                      and "--verify" not in command]
            self.assertEqual(signed[-1], "Validation.app")
            self.assertLess(signed.index("Helper.app"), signed.index("Validation.app"))
            self.assertLess(signed.index("Fixture.framework"), signed.index("Validation.app"))
            self.assertIn("--deep", commands[-1]); self.assertIn("--strict", commands[-1])
            candidate.verify_allowed_copy_changes(original, candidate.tree_manifest(prepared),
                pristine_name=pristine.name, candidate_name=prepared.name)

    def test_prepare_rejects_existing_destination_and_symlinked_source_member(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); pristine = self.make_app(root)
            output = root / "Validation.app"; output.mkdir()
            with self.assertRaises(FileExistsError):
                candidate.prepare_candidate(pristine, output,
                    configured_identifier="local.dynamicwallpaper.app", validation_token="test",
                    runner=lambda _: None)
            output.rmdir()
            (pristine / "Contents/escape").symlink_to(root)
            with self.assertRaises(ValueError):
                candidate.prepare_candidate(pristine, output,
                    configured_identifier="local.dynamicwallpaper.app", validation_token="test",
                    runner=lambda _: None)

    def test_preflight_returns_exact_isolated_environment_arguments_and_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            real_preferences = Path.home() / "Library/Preferences"
            result = candidate.create_preflight(Path(directory),
                bundle_identifier="local.dynamicwallpaper.app.validation.test")
            root = Path(result["root"])
            self.assertEqual(result["environment"], {
                "CFFIXED_USER_HOME": str(root / "Home"), "TMPDIR": str(root / "Temp")})
            self.assertEqual(result["arguments"][:2], ["--validation-data-root", str(root)])
            for path in result["paths"].values():
                self.assertTrue(Path(path).resolve().is_relative_to(root.resolve()), path)
            self.assertFalse(Path(result["paths"]["preferences"]).resolve()
                             .is_relative_to(real_preferences.resolve()))
            candidate.remove_preflight(root)
            self.assertFalse(root.exists())

    def test_preflight_rejects_symlinked_parent(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); actual = root / "actual"; actual.mkdir()
            link = root / "link"; link.symlink_to(actual, target_is_directory=True)
            with self.assertRaises(ValueError):
                candidate.create_preflight(link,
                    bundle_identifier="local.dynamicwallpaper.app.validation.test")

    def test_run_preflight_requires_exact_swift_path_record(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); app = self.make_app(root)
            info = app / "Contents/Info.plist"
            document = plistlib.loads(info.read_bytes())
            document["CFBundleIdentifier"] = "local.dynamicwallpaper.app.validation.test"
            info.write_bytes(plistlib.dumps(document))
            layout = candidate.create_preflight(root,
                bundle_identifier=document["CFBundleIdentifier"])
            expected = {
                "event": "preflight", "bundleIdentifier": document["CFBundleIdentifier"],
                "preferencesDomain": document["CFBundleIdentifier"],
                "fixedUserHome": layout["environment"]["CFFIXED_USER_HOME"],
                "temporaryRoot": layout["environment"]["TMPDIR"], "paths": layout["paths"],
            }
            calls = []
            def run(command, **kwargs):
                calls.append((command, kwargs))
                return subprocess.CompletedProcess(command, 0, stdout=json.dumps(expected), stderr="")
            observed = candidate.run_preflight(app / "Contents/MacOS/DynamicWallpaper", layout, runner=run)
            self.assertEqual(observed, expected)
            self.assertEqual(calls[0][1]["env"]["TMPDIR"], layout["environment"]["TMPDIR"])
            bad = dict(expected); bad["paths"] = dict(expected["paths"])
            bad["paths"]["preferences"] = str(Path.home() / "Library/Preferences")
            with self.assertRaises(ValueError):
                candidate.run_preflight(app / "Contents/MacOS/DynamicWallpaper", layout,
                    runner=lambda command, **kwargs: subprocess.CompletedProcess(
                        command, 0, stdout=json.dumps(bad), stderr=""))
            candidate.remove_preflight(Path(layout["root"]))


if __name__ == "__main__":
    unittest.main()

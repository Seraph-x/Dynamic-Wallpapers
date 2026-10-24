#!/usr/bin/env python3
"""Strict product configuration loader tests."""

from dataclasses import FrozenInstanceError
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import product_configuration as configuration_module
from product_configuration import CONFIGURATION_PATH, load, load_document


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/product_configuration.py"


def valid_document():
    return {
        "schema_version": 1,
        "version": "1.0.0",
        "build": "4",
        "target": {
            "architecture": "arm64",
            "minimum_macos": "14.0",
            "swift_language_mode": "5",
        },
        "localizations": ["zh-Hans", "en", "ja", "fr", "es"],
        "development_localization": "en",
        "application": {
            "bundle_identifier": "local.dynamicwallpaper.app",
            "display_name": "Dynamic Wallpaper",
            "bundle_name": "Dynamic Wallpaper.app",
            "executable": "DynamicWallpaper",
            "swiftpm_product": "DynamicWallpaper",
        },
        "screen_saver": {
            "bundle_identifier": "local.dynamicwallpaper.screensaver",
            "display_name": "Dynamic Wallpaper Screen Saver",
            "bundle_name": "Dynamic Wallpaper Screen Saver.saver",
            "executable": "DynamicWallpaperScreenSaver",
            "principal_class": "DynamicWallpaperScreenSaverView",
        },
        "cef_helpers": [
            {
                "role": "main",
                "suffix": "",
                "bundle_identifier": "local.dynamicwallpaper.cef.helper.main",
            },
            {
                "role": "gpu",
                "suffix": " (GPU)",
                "bundle_identifier": "local.dynamicwallpaper.cef.helper.gpu",
            },
            {
                "role": "renderer",
                "suffix": " (Renderer)",
                "bundle_identifier": "local.dynamicwallpaper.cef.helper.renderer",
            },
            {
                "role": "alerts",
                "suffix": " (Alerts)",
                "bundle_identifier": "local.dynamicwallpaper.cef.helper.alerts",
            },
            {
                "role": "plugin",
                "suffix": " (Plugin)",
                "bundle_identifier": "local.dynamicwallpaper.cef.helper.plugin",
            },
        ],
        "screen_saver_targets": [
            {
                "name": "WallpaperCore",
                "kind": "target",
                "path": "Sources/WallpaperCore",
                "root": False,
                "dependencies": [],
            },
            {
                "name": "WallpaperNative",
                "kind": "target",
                "path": "Sources/WallpaperNative",
                "root": False,
                "dependencies": ["WallpaperCore"],
            },
            {
                "name": "ScreenSaverCore",
                "kind": "target",
                "path": "Sources/ScreenSaverCore",
                "root": False,
                "dependencies": ["WallpaperCore"],
            },
            {
                "name": "ScreenSaverRuntime",
                "kind": "target",
                "path": "Sources/ScreenSaverRuntime",
                "root": False,
                "dependencies": ["ScreenSaverCore", "WallpaperCore", "WallpaperNative"],
            },
            {
                "name": "WallpaperScreenSaver",
                "kind": "target",
                "path": "Sources/WallpaperScreenSaver",
                "root": True,
                "dependencies": [
                    "ScreenSaverRuntime",
                    "ScreenSaverCore",
                    "WallpaperCore",
                    "WallpaperNative",
                ],
            },
        ],
    }


def parse(document):
    return load_document(json.dumps(document))


class ProductConfigurationTests(unittest.TestCase):
    def test_checked_in_document_loads_with_exact_values(self):
        configuration = load()
        self.assertEqual(CONFIGURATION_PATH, ROOT / "scripts/product-configuration.json")
        self.assertEqual(configuration.version, "1.0.0")
        self.assertEqual(configuration.build, "4")
        self.assertEqual(configuration.target.architecture, "arm64")
        self.assertEqual(configuration.target.minimum_macos, "14.0")
        self.assertEqual(configuration.target.swift_language_mode, "5")
        self.assertEqual(configuration.localizations, ("zh-Hans", "en", "ja", "fr", "es"))
        self.assertEqual(configuration.development_localization, "en")
        self.assertEqual(configuration.application.swiftpm_product, "DynamicWallpaper")
        self.assertEqual(configuration.screen_saver.principal_class,
                         "DynamicWallpaperScreenSaverView")

    def test_values_are_deeply_immutable(self):
        configuration = parse(valid_document())
        with self.assertRaises(FrozenInstanceError):
            configuration.version = "9.9.9"
        with self.assertRaises(FrozenInstanceError):
            configuration.target.architecture = "x86_64"
        self.assertIsInstance(configuration.localizations, tuple)
        self.assertIsInstance(configuration.cef_helpers, tuple)
        self.assertIsInstance(configuration.screen_saver_targets, tuple)
        self.assertIsInstance(configuration.screen_saver_targets[-1].dependencies, tuple)

    def test_rejects_malformed_json_and_non_object_root(self):
        for text, message in [("{", "Invalid JSON"), ("[]", "root must be an object")]:
            with self.subTest(text=text), self.assertRaisesRegex(ValueError, message):
                load_document(text)

    def test_rejects_non_finite_json_numbers(self):
        text = json.dumps(valid_document()).replace('"schema_version": 1',
                                                     '"schema_version": NaN')
        with self.assertRaisesRegex(ValueError, "Invalid JSON constant"):
            load_document(text)

    def test_rejects_duplicate_json_keys_at_every_object_level(self):
        source = json.dumps(valid_document())
        replacements = {
            "root": ('"schema_version": 1', '"schema_version": 1, "schema_version": 1'),
            "target": ('"architecture": "arm64"',
                       '"architecture": "arm64", "architecture": "arm64"'),
            "application": ('"swiftpm_product": "DynamicWallpaper"',
                            '"swiftpm_product": "DynamicWallpaper", '
                            '"swiftpm_product": "DynamicWallpaper"'),
            "screen_saver": ('"principal_class": "DynamicWallpaperScreenSaverView"',
                             '"principal_class": "DynamicWallpaperScreenSaverView", '
                             '"principal_class": "DynamicWallpaperScreenSaverView"'),
            "cef_helper": ('"role": "main"', '"role": "main", "role": "main"'),
            "swift_target": ('"name": "WallpaperCore"',
                             '"name": "WallpaperCore", "name": "WallpaperCore"'),
        }
        for level, (needle, duplicate) in replacements.items():
            with self.subTest(level=level), self.assertRaisesRegex(ValueError,
                                                                   "Duplicate JSON key"):
                load_document(source.replace(needle, duplicate, 1))

    def test_rejects_unknown_keys_at_every_object_level(self):
        mutations = {
            "root": lambda value: value.update(unexpected=True),
            "target": lambda value: value["target"].update(unexpected=True),
            "application": lambda value: value["application"].update(unexpected=True),
            "screen_saver": lambda value: value["screen_saver"].update(unexpected=True),
            "cef_helper": lambda value: value["cef_helpers"][0].update(unexpected=True),
            "swift_target": lambda value: value["screen_saver_targets"][0].update(
                unexpected=True),
        }
        for level, mutate in mutations.items():
            with self.subTest(level=level):
                document = valid_document()
                mutate(document)
                with self.assertRaisesRegex(ValueError, "unknown keys.*unexpected"):
                    parse(document)

    def test_rejects_missing_keys_at_every_object_level(self):
        mutations = {
            "root": lambda value: value.pop("version"),
            "target": lambda value: value["target"].pop("architecture"),
            "application": lambda value: value["application"].pop("bundle_identifier"),
            "screen_saver": lambda value: value["screen_saver"].pop("principal_class"),
            "cef_helper": lambda value: value["cef_helpers"][0].pop("role"),
            "swift_target": lambda value: value["screen_saver_targets"][0].pop("path"),
        }
        for level, mutate in mutations.items():
            with self.subTest(level=level):
                document = valid_document()
                mutate(document)
                with self.assertRaisesRegex(ValueError, "missing keys"):
                    parse(document)

    def test_rejects_wrong_top_level_types(self):
        invalid_values = {
            "schema_version": "1",
            "version": 3,
            "build": 3,
            "target": [],
            "localizations": "en",
            "development_localization": [],
            "application": [],
            "screen_saver": [],
            "cef_helpers": {},
            "screen_saver_targets": {},
        }
        for key, invalid in invalid_values.items():
            with self.subTest(key=key):
                document = valid_document()
                document[key] = invalid
                with self.assertRaisesRegex(ValueError, "must be"):
                    parse(document)

    def test_rejects_wrong_nested_scalar_and_list_types(self):
        cases = [
            ("architecture", lambda value: value["target"].update(architecture=[])),
            ("minimum_macos", lambda value: value["target"].update(minimum_macos=14.0)),
            ("swift_language_mode",
             lambda value: value["target"].update(swift_language_mode=5)),
            ("application", lambda value: value["application"].update(executable=False)),
            ("screen_saver", lambda value: value["screen_saver"].update(principal_class=[])),
            ("helper", lambda value: value["cef_helpers"][0].update(suffix=None)),
            ("target name", lambda value: value["screen_saver_targets"][0].update(name=1)),
            ("target root", lambda value: value["screen_saver_targets"][0].update(root=1)),
            ("dependencies",
             lambda value: value["screen_saver_targets"][0].update(dependencies="Other")),
            ("dependency item",
             lambda value: value["screen_saver_targets"][1].update(dependencies=[3])),
            ("localization item", lambda value: value["localizations"].append(3)),
            ("helper item", lambda value: value["cef_helpers"].append("helper")),
            ("target item", lambda value: value["screen_saver_targets"].append("target")),
        ]
        for name, mutate in cases:
            with self.subTest(name=name):
                document = valid_document()
                mutate(document)
                with self.assertRaisesRegex(ValueError, "must be"):
                    parse(document)

    def test_rejects_empty_strings_except_main_helper_suffix(self):
        mutations = [
            lambda value: value.update(version=""),
            lambda value: value.update(build=""),
            lambda value: value["target"].update(architecture=""),
            lambda value: value["localizations"].append(""),
            lambda value: value.update(development_localization=""),
            lambda value: value["application"].update(display_name=""),
            lambda value: value["screen_saver"].update(bundle_name=""),
            lambda value: value["cef_helpers"][0].update(role=""),
            lambda value: value["cef_helpers"][0].update(bundle_identifier=""),
            lambda value: value["screen_saver_targets"][0].update(name=""),
            lambda value: value["screen_saver_targets"][0].update(kind=""),
            lambda value: value["screen_saver_targets"][0].update(path=""),
            lambda value: value["screen_saver_targets"][1].update(dependencies=[""]),
        ]
        for index, mutate in enumerate(mutations):
            with self.subTest(index=index):
                document = valid_document()
                mutate(document)
                with self.assertRaisesRegex(ValueError, "must not be empty"):
                    parse(document)
        self.assertEqual(parse(valid_document()).cef_helpers[0].suffix, "")

    def test_rejects_invalid_semantic_versions(self):
        for version in ["1", "1.2", "01.2.3", "1.02.3", "1.2.03", "1.2.3-01", "v1.2.3"]:
            with self.subTest(version=version):
                document = valid_document()
                document["version"] = version
                with self.assertRaisesRegex(ValueError, "semantic version"):
                    parse(document)

    def test_accepts_semver_prerelease_and_build_metadata(self):
        document = valid_document()
        document["version"] = "1.2.3-rc.1+build.9"
        self.assertEqual(parse(document).version, document["version"])

    def test_rejects_invalid_build_numbers(self):
        for build in ["0", "01", "-1", "1.0", "build3"]:
            with self.subTest(build=build):
                document = valid_document()
                document["build"] = build
                with self.assertRaisesRegex(ValueError, "build"):
                    parse(document)

    def test_rejects_unsupported_schema_and_target_values(self):
        cases = [
            ("schema", lambda value: value.update(schema_version=2), "schema version"),
            ("architecture", lambda value: value["target"].update(architecture="x86_64"),
             "architecture"),
            ("macOS", lambda value: value["target"].update(minimum_macos="13.0"),
             "minimum macOS"),
            ("Swift", lambda value: value["target"].update(swift_language_mode="6"),
             "Swift language mode"),
            ("kind", lambda value: value["screen_saver_targets"][0].update(kind="plugin"),
             "target kind"),
        ]
        for name, mutate, message in cases:
            with self.subTest(name=name):
                document = valid_document()
                mutate(document)
                with self.assertRaisesRegex(ValueError, message):
                    parse(document)

    def test_rejects_duplicate_localizations(self):
        document = valid_document()
        document["localizations"].append("en")
        with self.assertRaisesRegex(ValueError, "duplicate localization"):
            parse(document)

    def test_rejects_development_localization_outside_localizations(self):
        document = valid_document()
        document["development_localization"] = "de"
        with self.assertRaisesRegex(ValueError, "development localization"):
            parse(document)

    def test_rejects_mismatched_product_and_executable(self):
        document = valid_document()
        document["application"]["swiftpm_product"] = "OtherProduct"
        with self.assertRaisesRegex(ValueError, "SwiftPM product.*executable"):
            parse(document)

    def test_rejects_duplicate_helpers(self):
        for field in ["role", "suffix", "bundle_identifier"]:
            with self.subTest(field=field):
                document = valid_document()
                source = 1 if field == "suffix" else 0
                destination = 2 if field == "suffix" else 1
                document["cef_helpers"][destination][field] = document["cef_helpers"][source][field]
                with self.assertRaisesRegex(ValueError, "duplicate CEF helper"):
                    parse(document)

    def test_helpers_require_exact_schema_roles(self):
        document = valid_document()
        document["cef_helpers"][-1]["role"] = "utility"
        with self.assertRaisesRegex(ValueError, "CEF helper roles must be exactly"):
            parse(document)

    def test_main_helper_requires_the_only_empty_suffix(self):
        cases = [
            ("main", " (Main)", "main helper suffix must be empty"),
            ("gpu", "", "only main helper may have an empty suffix"),
        ]
        for role, suffix, message in cases:
            with self.subTest(role=role):
                document = valid_document()
                helper = next(item for item in document["cef_helpers"] if item["role"] == role)
                helper["suffix"] = suffix
                with self.assertRaisesRegex(ValueError, message):
                    parse(document)

    def test_helpers_require_the_exact_suffix_for_each_role(self):
        cases = [
            ("swapped", {"gpu": " (Renderer)", "renderer": " (GPU)"}),
            ("arbitrary", {"alerts": " (Notifications)"}),
        ]
        for name, suffixes in cases:
            with self.subTest(name=name):
                document = valid_document()
                for helper in document["cef_helpers"]:
                    if helper["role"] in suffixes:
                        helper["suffix"] = suffixes[helper["role"]]
                with self.assertRaisesRegex(ValueError, "suffix for CEF helper"):
                    parse(document)

    def test_rejects_duplicate_targets_paths_and_dependencies(self):
        cases = [
            lambda value: value["screen_saver_targets"][1].update(name="WallpaperCore"),
            lambda value: value["screen_saver_targets"][1].update(path="Sources/WallpaperCore"),
            lambda value: value["screen_saver_targets"][1].update(
                dependencies=["WallpaperCore", "WallpaperCore"]),
        ]
        for index, mutate in enumerate(cases):
            with self.subTest(index=index):
                document = valid_document()
                mutate(document)
                with self.assertRaisesRegex(ValueError, "duplicate"):
                    parse(document)

    def test_target_graph_rejects_missing_self_and_cycles(self):
        cases = [
            (["Missing"], "unknown dependency"),
            (["WallpaperScreenSaver"], "self dependency"),
        ]
        for dependencies, message in cases:
            with self.subTest(dependencies=dependencies):
                document = valid_document()
                document["screen_saver_targets"][-1]["dependencies"] = dependencies
                with self.assertRaisesRegex(ValueError, message):
                    parse(document)
        document = valid_document()
        document["screen_saver_targets"][0]["dependencies"] = ["WallpaperNative"]
        with self.assertRaisesRegex(ValueError, "dependency cycle"):
            parse(document)

    def test_target_graph_requires_exactly_one_root(self):
        for roots in [set(), {"WallpaperCore", "WallpaperScreenSaver"}]:
            with self.subTest(roots=roots):
                document = valid_document()
                for target in document["screen_saver_targets"]:
                    target["root"] = target["name"] in roots
                with self.assertRaisesRegex(ValueError, "exactly one.*root"):
                    parse(document)

    def test_target_graph_requires_wallpaper_screen_saver_as_root(self):
        document = valid_document()
        document["screen_saver_targets"][-1]["root"] = False
        document["screen_saver_targets"][3]["root"] = True
        with self.assertRaisesRegex(ValueError, "root must be WallpaperScreenSaver"):
            parse(document)

    def test_target_graph_rejects_targets_outside_root_closure(self):
        document = valid_document()
        document["screen_saver_targets"][-1]["dependencies"].remove("WallpaperNative")
        document["screen_saver_targets"][3]["dependencies"].remove("WallpaperNative")
        with self.assertRaisesRegex(ValueError, "outside.*root closure"):
            parse(document)

    def test_topological_targets_are_dependency_first_and_stable(self):
        names = [target.name for target in parse(valid_document()).topological_screen_saver_targets()]
        self.assertEqual(names, [
            "WallpaperCore",
            "WallpaperNative",
            "ScreenSaverCore",
            "ScreenSaverRuntime",
            "WallpaperScreenSaver",
        ])

    def test_swift_manifest_matches_configured_product_and_screen_saver_closure(self):
        media = json.loads((ROOT / 'scripts/media-dependencies.json').read_text())
        self.assertNotIn('observed_build', media['modules']['ffmpeg'])
        self.assertNotIn('observed_build', (ROOT / 'Package.swift').read_text())
        configuration = load()
        result = subprocess.run(
            ["swift", "package", "dump-package"],
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=True,
        )
        package = json.loads(result.stdout)
        self.assertEqual(package["name"], configuration.application.swiftpm_product)
        self.assertEqual(package["defaultLocalization"],
                         configuration.development_localization)
        self.assertEqual(package["platforms"], [{
            "options": [],
            "platformName": "macos",
            "version": configuration.target.minimum_macos,
        }])
        self.assertEqual(package["swiftLanguageVersions"],
                         [configuration.target.swift_language_mode])

        manifest_targets = {target["name"]: target for target in package["targets"]}
        configured_targets = {
            target.name: target for target in configuration.screen_saver_targets
        }

        def dependency_names(target):
            return {
                dependency["byName"][0]
                for dependency in target["dependencies"]
                if "byName" in dependency
            }

        closure = set()
        pending = ["WallpaperScreenSaver"]
        while pending:
            name = pending.pop()
            if name in closure:
                continue
            closure.add(name)
            pending.extend(dependency_names(manifest_targets[name]))

        self.assertEqual(closure, set(configured_targets))
        for name, configured in configured_targets.items():
            with self.subTest(target=name):
                target = manifest_targets[name]
                self.assertEqual(target["type"], "regular")
                self.assertEqual(target.get("path") or f"Sources/{name}", configured.path)
                self.assertEqual(dependency_names(target), set(configured.dependencies))

    def test_metadata_and_archive_helpers_derive_all_product_facts(self):
        configuration = parse(valid_document())
        self.assertEqual(configuration.application_metadata(), {
            "CFBundleIdentifier": "local.dynamicwallpaper.app",
            "CFBundleName": "Dynamic Wallpaper",
            "CFBundleDisplayName": "Dynamic Wallpaper",
            "CFBundleExecutable": "DynamicWallpaper",
            "CFBundleShortVersionString": "1.0.0",
            "CFBundleVersion": "4",
            "LSMinimumSystemVersion": "14.0",
            "CFBundleDevelopmentRegion": "en",
            "CFBundleLocalizations": ["zh-Hans", "en", "ja", "fr", "es"],
        })
        self.assertEqual(configuration.screen_saver_metadata(), {
            "CFBundleIdentifier": "local.dynamicwallpaper.screensaver",
            "CFBundleName": "Dynamic Wallpaper Screen Saver",
            "CFBundleDisplayName": "Dynamic Wallpaper Screen Saver",
            "CFBundleExecutable": "DynamicWallpaperScreenSaver",
            "CFBundleShortVersionString": "1.0.0",
            "CFBundleVersion": "4",
            "LSMinimumSystemVersion": "14.0",
            "CFBundleDevelopmentRegion": "en",
            "CFBundleLocalizations": ["zh-Hans", "en", "ja", "fr", "es"],
            "NSPrincipalClass": "DynamicWallpaperScreenSaverView",
            "DWApplicationBundleIdentifier": "local.dynamicwallpaper.app",
        })
        self.assertEqual(configuration.archive_name(),
                         "DynamicWallpaper-1.0.0-build4-arm64.zip")

    def test_checked_in_plists_are_stable_templates_without_product_facts(self):
        dynamic = {
            "CFBundleIdentifier", "CFBundleName", "CFBundleDisplayName",
            "CFBundleExecutable", "CFBundleShortVersionString", "CFBundleVersion",
            "LSMinimumSystemVersion", "CFBundleDevelopmentRegion",
            "CFBundleLocalizations",
            "DWApplicationBundleIdentifier", "DWScreenSaverBundleIdentifier",
            "DWScreenSaverBundleName", "DWCEFHelpers",
        }
        for relative in ["Resources/Info.plist", "Resources/ScreenSaver/Info.plist"]:
            with self.subTest(path=relative):
                document = plistlib.loads((ROOT / relative).read_bytes())
                prohibited = dynamic | ({"NSPrincipalClass"} if "ScreenSaver" in relative else set())
                self.assertEqual(set(document).intersection(prohibited), set())

    def test_emit_shell_json_outputs_only_the_validated_document(self):
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--emit", "shell-json"],
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=True,
        )
        self.assertEqual(json.loads(result.stdout), valid_document())
        self.assertEqual(result.stderr, "")
        self.assertEqual(result.stdout.count("\n"), 1)

    def test_dump_package_evidence_invokes_swift_without_shell_and_creates_once(self):
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            fake_bin = temporary / "bin"
            fake_bin.mkdir()
            invocation = temporary / "invocation.json"
            swift = fake_bin / "swift"
            swift.write_text(
                "#!/usr/bin/env python3\n"
                "import json, os, pathlib, sys\n"
                "pathlib.Path(os.environ['FAKE_SWIFT_LOG']).write_text("
                "json.dumps({'argv': sys.argv[1:], 'cwd': os.getcwd()}))\n"
                "sys.stdout.buffer.write(b'{\"name\":\"fixture\"}\\n')\n"
            )
            swift.chmod(0o755)
            output = temporary / "evidence.json"
            environment = os.environ.copy()
            environment["PATH"] = str(fake_bin) + os.pathsep + environment["PATH"]
            environment["FAKE_SWIFT_LOG"] = str(invocation)
            command = [sys.executable, str(SCRIPT), "dump-package-evidence",
                       "--output", str(output)]
            subprocess.run(command, cwd=ROOT, env=environment, check=True)
            self.assertEqual(output.read_bytes(), b'{"name":"fixture"}\n')
            self.assertEqual(json.loads(invocation.read_text()), {
                "argv": ["package", "dump-package"],
                "cwd": str(ROOT),
            })
            with self.assertRaises(subprocess.CalledProcessError):
                subprocess.run(command, cwd=ROOT, env=environment, check=True,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def test_dump_package_evidence_rejects_dangling_symlink_output(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "evidence.json"
            output.symlink_to("missing")
            result = subprocess.run(
                [sys.executable, str(SCRIPT), "dump-package-evidence",
                 "--output", str(output)],
                cwd=ROOT,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("already exists", result.stderr)

    def test_evidence_partial_write_failure_removes_temporary_and_final_files(self):
        with tempfile.TemporaryDirectory() as directory:
            parent = Path(directory)
            output = parent / "evidence.json"
            real_write = os.write
            calls = 0

            def fail_after_partial_write(descriptor, payload):
                nonlocal calls
                calls += 1
                if calls == 1:
                    return real_write(descriptor, payload[:1])
                raise OSError("injected write failure")

            with mock.patch.object(configuration_module.os, "write",
                                   side_effect=fail_after_partial_write):
                with self.assertRaisesRegex(OSError, "injected write failure"):
                    configuration_module._write_exclusively(output, b"complete evidence")
            self.assertFalse(output.exists())
            self.assertEqual(list(parent.iterdir()), [])

    def test_evidence_file_fsync_failure_removes_temporary_and_final_files(self):
        with tempfile.TemporaryDirectory() as directory:
            parent = Path(directory)
            output = parent / "evidence.json"
            with mock.patch.object(configuration_module.os, "fsync",
                                   side_effect=OSError("injected file fsync failure")):
                with self.assertRaisesRegex(OSError, "injected file fsync failure"):
                    configuration_module._write_exclusively(output, b"complete evidence")
            self.assertFalse(output.exists())
            self.assertEqual(list(parent.iterdir()), [])

    def test_evidence_directory_fsync_failure_retains_complete_published_file(self):
        with tempfile.TemporaryDirectory() as directory:
            parent = Path(directory)
            output = parent / "evidence.json"
            payload = b"complete evidence"
            real_fsync = os.fsync
            calls = 0

            def fail_directory_fsync(descriptor):
                nonlocal calls
                calls += 1
                if calls == 2:
                    raise OSError("injected directory fsync failure")
                return real_fsync(descriptor)

            with mock.patch.object(configuration_module.os, "fsync",
                                   side_effect=fail_directory_fsync):
                with self.assertRaisesRegex(OSError, "injected directory fsync failure"):
                    configuration_module._write_exclusively(output, payload)
            self.assertEqual(output.read_bytes(), payload)
            self.assertEqual(list(parent.iterdir()), [output])

    def test_evidence_cleanup_never_unlinks_a_racing_replacement(self):
        with tempfile.TemporaryDirectory() as directory:
            parent = Path(directory)
            output = parent / "evidence.json"
            payload = b"complete evidence"
            competing = b"competing evidence"
            real_fsync = os.fsync
            real_lstat = os.lstat
            real_unlink = os.unlink
            fsync_calls = 0
            replacement_happened = False

            def fail_directory_fsync(descriptor):
                nonlocal fsync_calls
                fsync_calls += 1
                if fsync_calls == 2:
                    raise OSError("injected directory fsync failure")
                return real_fsync(descriptor)

            def replace_after_inspection(path):
                nonlocal replacement_happened
                status = real_lstat(path)
                if Path(path) == output:
                    real_unlink(path)
                    output.write_bytes(competing)
                    replacement_happened = True
                return status

            with mock.patch.object(configuration_module.os, "fsync",
                                   side_effect=fail_directory_fsync), \
                    mock.patch.object(configuration_module.os, "lstat",
                                      side_effect=replace_after_inspection):
                with self.assertRaisesRegex(OSError, "injected directory fsync failure"):
                    configuration_module._write_exclusively(output, payload)
            self.assertFalse(replacement_happened,
                             "published output must not enter compare-and-unlink cleanup")
            self.assertEqual(output.read_bytes(), payload)

    def test_evidence_link_failure_removes_temporary_and_final_files(self):
        with tempfile.TemporaryDirectory() as directory:
            parent = Path(directory)
            output = parent / "evidence.json"
            with mock.patch.object(configuration_module.os, "link",
                                   side_effect=OSError("injected publish failure")):
                with self.assertRaisesRegex(OSError, "injected publish failure"):
                    configuration_module._write_exclusively(output, b"complete evidence")
            self.assertFalse(output.exists())
            self.assertEqual(list(parent.iterdir()), [])

    def test_evidence_link_that_publishes_then_raises_retains_complete_output(self):
        with tempfile.TemporaryDirectory() as directory:
            parent = Path(directory)
            output = parent / "evidence.json"
            payload = b"complete evidence"
            real_link = os.link

            def publish_then_fail(source, destination, **options):
                real_link(source, destination, **options)
                raise OSError("injected post-link failure")

            with mock.patch.object(configuration_module.os, "link",
                                   side_effect=publish_then_fail):
                with self.assertRaisesRegex(OSError, "injected post-link failure") as raised:
                    configuration_module._write_exclusively(output, payload)
            notes = getattr(raised.exception, "__notes__", ())
            self.assertTrue(any("publication state is uncertain" in note for note in notes))
            self.assertEqual(output.read_bytes(), payload)
            self.assertEqual(list(parent.iterdir()), [output])

    def test_evidence_parent_rename_during_publish_does_not_leak_temporary(self):
        with tempfile.TemporaryDirectory() as directory:
            container = Path(directory)
            parent = container / "evidence-directory"
            moved_parent = container / "moved-evidence-directory"
            parent.mkdir()
            output = parent / "evidence.json"

            def rename_parent_then_fail(*args, **kwargs):
                parent.rename(moved_parent)
                raise OSError("injected publish failure after parent rename")

            with mock.patch.object(configuration_module.os, "link",
                                   side_effect=rename_parent_then_fail):
                with self.assertRaisesRegex(
                        OSError, "injected publish failure after parent rename"):
                    configuration_module._write_exclusively(output, b"complete evidence")

            self.assertEqual(list(moved_parent.iterdir()), [])

    def test_evidence_publish_race_never_overwrites_competing_file(self):
        with tempfile.TemporaryDirectory() as directory:
            parent = Path(directory)
            output = parent / "evidence.json"
            real_link = os.link

            def race_link(source, destination, **options):
                output.write_bytes(b"competing evidence")
                return real_link(source, destination, **options)

            with mock.patch.object(configuration_module.os, "link", side_effect=race_link):
                with self.assertRaises(FileExistsError):
                    configuration_module._write_exclusively(output, b"our evidence")
            self.assertEqual(output.read_bytes(), b"competing evidence")
            self.assertEqual(list(parent.iterdir()), [output])


if __name__ == "__main__":
    unittest.main()

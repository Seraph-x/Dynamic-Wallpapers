#!/usr/bin/env python3
"""Strict immutable product configuration shared by build and packaging tools."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys
from typing import Any, NoReturn


ROOT = Path(__file__).resolve().parents[1]
CONFIGURATION_PATH = ROOT / "scripts/product-configuration.json"

_ROOT_KEYS = frozenset({
    "schema_version", "version", "build", "target", "localizations",
    "development_localization", "application", "screen_saver", "cef_helpers",
    "screen_saver_targets",
})
_TARGET_KEYS = frozenset({"architecture", "minimum_macos", "swift_language_mode"})
_APPLICATION_KEYS = frozenset({
    "bundle_identifier", "display_name", "bundle_name", "executable", "swiftpm_product",
})
_SCREEN_SAVER_KEYS = frozenset({
    "bundle_identifier", "display_name", "bundle_name", "executable", "principal_class",
})
_CEF_HELPER_KEYS = frozenset({"role", "suffix", "bundle_identifier"})
_CEF_HELPER_SUFFIXES = {
    "main": "",
    "gpu": " (GPU)",
    "renderer": " (Renderer)",
    "alerts": " (Alerts)",
    "plugin": " (Plugin)",
}
_CEF_HELPER_ROLES = frozenset(_CEF_HELPER_SUFFIXES)
_SWIFT_TARGET_KEYS = frozenset({"name", "kind", "path", "root", "dependencies"})
_SEMVER = re.compile(
    r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
    r"(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?"
    r"(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$"
)
_BUILD = re.compile(r"^[1-9][0-9]*$")


@dataclass(frozen=True)
class TargetConfiguration:
    architecture: str
    minimum_macos: str
    swift_language_mode: str


@dataclass(frozen=True)
class BundleConfiguration:
    bundle_identifier: str
    display_name: str
    bundle_name: str
    executable: str
    swiftpm_product: str


@dataclass(frozen=True)
class ScreenSaverConfiguration:
    bundle_identifier: str
    display_name: str
    bundle_name: str
    executable: str
    principal_class: str


@dataclass(frozen=True)
class CEFHelperConfiguration:
    role: str
    suffix: str
    bundle_identifier: str


@dataclass(frozen=True)
class SwiftTargetConfiguration:
    name: str
    kind: str
    path: str
    root: bool
    dependencies: tuple[str, ...]


@dataclass(frozen=True)
class ProductConfiguration:
    schema_version: int
    version: str
    build: str
    target: TargetConfiguration
    localizations: tuple[str, ...]
    development_localization: str
    application: BundleConfiguration
    screen_saver: ScreenSaverConfiguration
    cef_helpers: tuple[CEFHelperConfiguration, ...]
    screen_saver_targets: tuple[SwiftTargetConfiguration, ...]

    def topological_screen_saver_targets(self) -> tuple[SwiftTargetConfiguration, ...]:
        """Return every configured target in stable dependency-first order."""
        by_name = {target.name: target for target in self.screen_saver_targets}
        remaining = {target.name: len(target.dependencies) for target in self.screen_saver_targets}
        ordered: list[SwiftTargetConfiguration] = []
        while len(ordered) < len(self.screen_saver_targets):
            ready = next((target for target in self.screen_saver_targets
                          if remaining[target.name] == 0 and target not in ordered), None)
            if ready is None:
                raise ValueError("screen_saver_targets contains a dependency cycle")
            ordered.append(ready)
            remaining[ready.name] = -1
            for target in self.screen_saver_targets:
                if ready.name in by_name[target.name].dependencies:
                    remaining[target.name] -= 1
        return tuple(ordered)

    def application_metadata(self) -> dict[str, Any]:
        return self._common_metadata(
            self.application.bundle_identifier,
            self.application.display_name,
            self.application.executable,
        )

    def screen_saver_metadata(self) -> dict[str, Any]:
        metadata = self._common_metadata(
            self.screen_saver.bundle_identifier,
            self.screen_saver.display_name,
            self.screen_saver.executable,
        )
        metadata.update({
            "NSPrincipalClass": self.screen_saver.principal_class,
            "DWApplicationBundleIdentifier": self.application.bundle_identifier,
        })
        return metadata

    def archive_name(self) -> str:
        return (f"{self.application.swiftpm_product}-{self.version}-build{self.build}-"
                f"{self.target.architecture}.zip")

    def as_document(self) -> dict[str, Any]:
        return {
            "schema_version": self.schema_version,
            "version": self.version,
            "build": self.build,
            "target": {
                "architecture": self.target.architecture,
                "minimum_macos": self.target.minimum_macos,
                "swift_language_mode": self.target.swift_language_mode,
            },
            "localizations": list(self.localizations),
            "development_localization": self.development_localization,
            "application": {
                "bundle_identifier": self.application.bundle_identifier,
                "display_name": self.application.display_name,
                "bundle_name": self.application.bundle_name,
                "executable": self.application.executable,
                "swiftpm_product": self.application.swiftpm_product,
            },
            "screen_saver": {
                "bundle_identifier": self.screen_saver.bundle_identifier,
                "display_name": self.screen_saver.display_name,
                "bundle_name": self.screen_saver.bundle_name,
                "executable": self.screen_saver.executable,
                "principal_class": self.screen_saver.principal_class,
            },
            "cef_helpers": [
                {
                    "role": helper.role,
                    "suffix": helper.suffix,
                    "bundle_identifier": helper.bundle_identifier,
                }
                for helper in self.cef_helpers
            ],
            "screen_saver_targets": [
                {
                    "name": target.name,
                    "kind": target.kind,
                    "path": target.path,
                    "root": target.root,
                    "dependencies": list(target.dependencies),
                }
                for target in self.screen_saver_targets
            ],
        }

    def _common_metadata(self, bundle_identifier: str, display_name: str,
                         executable: str) -> dict[str, Any]:
        return {
            "CFBundleIdentifier": bundle_identifier,
            "CFBundleName": display_name,
            "CFBundleDisplayName": display_name,
            "CFBundleExecutable": executable,
            "CFBundleShortVersionString": self.version,
            "CFBundleVersion": self.build,
            "LSMinimumSystemVersion": self.target.minimum_macos,
            "CFBundleDevelopmentRegion": self.development_localization,
            "CFBundleLocalizations": list(self.localizations),
        }


def reject_duplicate_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"Duplicate JSON key: {key}")
        result[key] = value
    return result


def _reject_constant(value: str) -> NoReturn:
    raise ValueError(f"Invalid JSON constant: {value}")


def _object(value: Any, path: str, keys: frozenset[str]) -> dict[str, Any]:
    if type(value) is not dict:
        raise ValueError(f"{path} must be an object")
    missing = sorted(keys - value.keys())
    unknown = sorted(value.keys() - keys)
    if missing:
        raise ValueError(f"{path} missing keys: {', '.join(missing)}")
    if unknown:
        raise ValueError(f"{path} has unknown keys: {', '.join(unknown)}")
    return value


def _string(value: Any, path: str, *, allow_empty: bool = False) -> str:
    if type(value) is not str:
        raise ValueError(f"{path} must be a string")
    if not allow_empty and not value:
        raise ValueError(f"{path} must not be empty")
    return value


def _boolean(value: Any, path: str) -> bool:
    if type(value) is not bool:
        raise ValueError(f"{path} must be a boolean")
    return value


def _array(value: Any, path: str, *, allow_empty: bool = False) -> list[Any]:
    if type(value) is not list:
        raise ValueError(f"{path} must be an array")
    if not allow_empty and not value:
        raise ValueError(f"{path} must not be empty")
    return value


def _strings(value: Any, path: str, *, allow_empty_array: bool = False) -> tuple[str, ...]:
    array = _array(value, path, allow_empty=allow_empty_array)
    return tuple(_string(item, f"{path}[{index}]") for index, item in enumerate(array))


def _parse_target(value: Any) -> TargetConfiguration:
    document = _object(value, "target", _TARGET_KEYS)
    configuration = TargetConfiguration(
        architecture=_string(document["architecture"], "target.architecture"),
        minimum_macos=_string(document["minimum_macos"], "target.minimum_macos"),
        swift_language_mode=_string(
            document["swift_language_mode"], "target.swift_language_mode"),
    )
    if configuration.architecture != "arm64":
        raise ValueError(f"Unsupported architecture: {configuration.architecture}")
    if configuration.minimum_macos != "14.0":
        raise ValueError(f"Unsupported minimum macOS: {configuration.minimum_macos}")
    if configuration.swift_language_mode != "5":
        raise ValueError(f"Unsupported Swift language mode: {configuration.swift_language_mode}")
    return configuration


def _parse_application(value: Any) -> BundleConfiguration:
    document = _object(value, "application", _APPLICATION_KEYS)
    configuration = BundleConfiguration(**{
        key: _string(document[key], f"application.{key}") for key in _APPLICATION_KEYS
    })
    if configuration.swiftpm_product != configuration.executable:
        raise ValueError("Application SwiftPM product must equal application executable")
    return configuration


def _parse_screen_saver(value: Any) -> ScreenSaverConfiguration:
    document = _object(value, "screen_saver", _SCREEN_SAVER_KEYS)
    return ScreenSaverConfiguration(**{
        key: _string(document[key], f"screen_saver.{key}") for key in _SCREEN_SAVER_KEYS
    })


def _parse_helpers(value: Any) -> tuple[CEFHelperConfiguration, ...]:
    helpers = []
    for index, item in enumerate(_array(value, "cef_helpers")):
        path = f"cef_helpers[{index}]"
        document = _object(item, path, _CEF_HELPER_KEYS)
        helpers.append(CEFHelperConfiguration(
            role=_string(document["role"], f"{path}.role"),
            suffix=_string(document["suffix"], f"{path}.suffix", allow_empty=True),
            bundle_identifier=_string(
                document["bundle_identifier"], f"{path}.bundle_identifier"),
        ))
    for field in ("role", "bundle_identifier"):
        values = [getattr(helper, field) for helper in helpers]
        if len(values) != len(set(values)):
            raise ValueError(f"duplicate CEF helper {field}")
    roles = {helper.role for helper in helpers}
    if roles != _CEF_HELPER_ROLES:
        expected = ", ".join(sorted(_CEF_HELPER_ROLES))
        raise ValueError(f"CEF helper roles must be exactly: {expected}")
    main = next(helper for helper in helpers if helper.role == "main")
    if main.suffix:
        raise ValueError("main helper suffix must be empty")
    if any(not helper.suffix for helper in helpers if helper.role != "main"):
        raise ValueError("only main helper may have an empty suffix")
    suffixes = [helper.suffix for helper in helpers]
    if len(suffixes) != len(set(suffixes)):
        raise ValueError("duplicate CEF helper suffix")
    for helper in helpers:
        expected = _CEF_HELPER_SUFFIXES[helper.role]
        if helper.suffix != expected:
            raise ValueError(
                f"Invalid suffix for CEF helper {helper.role}: expected {expected!r}")
    return tuple(helpers)


def _parse_swift_targets(value: Any) -> tuple[SwiftTargetConfiguration, ...]:
    targets = []
    for index, item in enumerate(_array(value, "screen_saver_targets")):
        path = f"screen_saver_targets[{index}]"
        document = _object(item, path, _SWIFT_TARGET_KEYS)
        target = SwiftTargetConfiguration(
            name=_string(document["name"], f"{path}.name"),
            kind=_string(document["kind"], f"{path}.kind"),
            path=_string(document["path"], f"{path}.path"),
            root=_boolean(document["root"], f"{path}.root"),
            dependencies=_strings(
                document["dependencies"], f"{path}.dependencies", allow_empty_array=True),
        )
        if target.kind != "target":
            raise ValueError(f"Unsupported target kind: {target.kind}")
        if len(target.dependencies) != len(set(target.dependencies)):
            raise ValueError(f"duplicate dependency in target {target.name}")
        targets.append(target)
    _validate_target_graph(targets)
    return tuple(targets)


def _validate_target_graph(targets: list[SwiftTargetConfiguration]) -> None:
    names = [target.name for target in targets]
    paths = [target.path for target in targets]
    if len(names) != len(set(names)):
        raise ValueError("duplicate screen saver target name")
    if len(paths) != len(set(paths)):
        raise ValueError("duplicate screen saver target path")
    roots = [target for target in targets if target.root]
    if len(roots) != 1:
        raise ValueError("screen_saver_targets must contain exactly one root target")
    if roots[0].name != "WallpaperScreenSaver":
        raise ValueError("screen_saver_targets root must be WallpaperScreenSaver")

    by_name = {target.name: target for target in targets}
    for target in targets:
        for dependency in target.dependencies:
            if dependency == target.name:
                raise ValueError(f"self dependency in target {target.name}")
            if dependency not in by_name:
                raise ValueError(f"unknown dependency {dependency} in target {target.name}")

    reachable: set[str] = set()
    stack = [roots[0].name]
    while stack:
        name = stack.pop()
        if name in reachable:
            continue
        reachable.add(name)
        stack.extend(by_name[name].dependencies)
    outside = sorted(set(names) - reachable)
    if outside:
        raise ValueError(f"targets outside screen saver root closure: {', '.join(outside)}")

    remaining = {target.name: len(target.dependencies) for target in targets}
    ready = [target.name for target in targets if remaining[target.name] == 0]
    visited = 0
    while ready:
        resolved = ready.pop(0)
        visited += 1
        for target in targets:
            if resolved in target.dependencies:
                remaining[target.name] -= 1
                if remaining[target.name] == 0:
                    ready.append(target.name)
    if visited != len(targets):
        raise ValueError("screen_saver_targets contains a dependency cycle")


def _parse_product(document: dict[str, Any]) -> ProductConfiguration:
    document = _object(document, "root", _ROOT_KEYS)
    schema_version = document["schema_version"]
    if type(schema_version) is not int:
        raise ValueError("schema_version must be an integer")
    if schema_version != 1:
        raise ValueError(f"Unsupported schema version: {schema_version}")

    version = _string(document["version"], "version")
    match = _SEMVER.fullmatch(version)
    if match is None or any(
        part.isdigit() and len(part) > 1 and part.startswith("0")
        for part in (match.group(4).split(".") if match and match.group(4) else ())
    ):
        raise ValueError(f"Invalid semantic version: {version}")
    build = _string(document["build"], "build")
    if _BUILD.fullmatch(build) is None:
        raise ValueError(f"Invalid build number: {build}")

    localizations = _strings(document["localizations"], "localizations")
    if len(localizations) != len(set(localizations)):
        raise ValueError("duplicate localization")
    development = _string(
        document["development_localization"], "development_localization")
    if development not in localizations:
        raise ValueError("development localization must be present in localizations")

    application = _parse_application(document["application"])
    configuration = ProductConfiguration(
        schema_version=schema_version,
        version=version,
        build=build,
        target=_parse_target(document["target"]),
        localizations=localizations,
        development_localization=development,
        application=application,
        screen_saver=_parse_screen_saver(document["screen_saver"]),
        cef_helpers=_parse_helpers(document["cef_helpers"]),
        screen_saver_targets=_parse_swift_targets(document["screen_saver_targets"]),
    )
    return configuration


def load_document(text: str) -> ProductConfiguration:
    if type(text) is not str:
        raise ValueError("configuration text must be a string")
    try:
        document = json.loads(
            text,
            object_pairs_hook=reject_duplicate_pairs,
            parse_constant=_reject_constant,
        )
    except json.JSONDecodeError as error:
        raise ValueError(f"Invalid JSON: {error}") from error
    if type(document) is not dict:
        raise ValueError("root must be an object")
    return _parse_product(document)


def load(path: Path | str = CONFIGURATION_PATH) -> ProductConfiguration:
    return load_document(Path(path).read_text(encoding="utf-8"))


def _require_new_output(path: Path) -> None:
    try:
        os.lstat(path)
    except FileNotFoundError:
        return
    raise FileExistsError(f"Output already exists: {path}")


def _write_exclusively(path: Path, payload: bytes) -> None:
    _require_new_output(path)
    directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
    descriptor = -1
    temporary_name: str | None = None
    try:
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
        while descriptor < 0:
            candidate = f".{path.name}.{secrets.token_hex(16)}.tmp"
            try:
                descriptor = os.open(candidate, flags, 0o600, dir_fd=directory)
                temporary_name = candidate
            except FileExistsError:
                continue

        os.fchmod(descriptor, 0o644)
        view = memoryview(payload)
        while view:
            written = os.write(descriptor, view)
            if written == 0:
                raise OSError("Unable to write dump-package evidence")
            view = view[written:]
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = -1

        # link(2) creates the destination atomically and fails with EEXIST
        # instead of replacing a file or dangling symlink created by a racer.
        try:
            os.link(
                temporary_name,
                path.name,
                src_dir_fd=directory,
                dst_dir_fd=directory,
                follow_symlinks=False,
            )
        except BaseException as error:
            error.add_note(
                f"Evidence publication state is uncertain; final output was not removed: {path}")
            raise
        os.unlink(temporary_name, dir_fd=directory)
        temporary_name = None

        os.fsync(directory)
    except BaseException as error:
        if descriptor >= 0:
            try:
                os.close(descriptor)
            except OSError as cleanup_error:
                error.add_note(f"failed to close evidence temporary: {cleanup_error}")
        if temporary_name is not None:
            try:
                os.unlink(temporary_name, dir_fd=directory)
            except FileNotFoundError:
                pass
            except OSError as cleanup_error:
                error.add_note(
                    f"failed to remove evidence temporary {temporary_name}: {cleanup_error}")
        raise
    finally:
        os.close(directory)


def dump_package_evidence(output: Path) -> None:
    load()
    _require_new_output(output)
    result = subprocess.run(
        ["swift", "package", "dump-package"],
        cwd=ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        sys.stderr.buffer.write(result.stderr)
        raise SystemExit(result.returncode)
    _write_exclusively(output, result.stdout)


def _argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--emit", choices=("shell-json",))
    subparsers = parser.add_subparsers(dest="command")
    dump_parser = subparsers.add_parser("dump-package-evidence")
    dump_parser.add_argument("--output", type=Path, required=True)
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = _argument_parser()
    arguments = parser.parse_args(argv)
    if arguments.emit == "shell-json":
        if arguments.command is not None:
            parser.error("--emit cannot be combined with a command")
        print(json.dumps(load().as_document(), ensure_ascii=False, separators=(",", ":")))
        return 0
    if arguments.command == "dump-package-evidence":
        dump_package_evidence(arguments.output)
        return 0
    parser.error("one of --emit or dump-package-evidence is required")


if __name__ == "__main__":
    raise SystemExit(main())

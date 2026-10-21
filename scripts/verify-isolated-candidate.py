#!/usr/bin/env python3
"""Prepare and preflight a signed validation copy without touching production data."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import tempfile

from product_configuration import load as load_product_configuration


PREFLIGHT_PREFIX = "dynamic-wallpaper-validation-"
TOKEN = re.compile(r"^[a-z0-9][a-z0-9-]{0,62}$")


def _lstat(path: Path):
    return path.lstat()


def _require_plain_directory(path: Path) -> Path:
    info = _lstat(path)
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
        raise ValueError(f"Expected a real directory: {path}")
    return path.resolve(strict=True)


def tree_manifest(root: Path) -> dict[str, tuple[str, int, str]]:
    root = _require_plain_directory(root)
    result: dict[str, tuple[str, int, str]] = {}
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root).as_posix()
        info = _lstat(path)
        mode = stat.S_IMODE(info.st_mode)
        if stat.S_ISLNK(info.st_mode):
            target = os.readlink(path)
            resolved = path.resolve(strict=False)
            if not resolved.is_relative_to(root):
                raise ValueError(f"Symlink escapes candidate: {relative} -> {target}")
            result[relative] = ("symlink", mode, target)
        elif stat.S_ISDIR(info.st_mode):
            result[relative] = ("directory", mode, "")
        elif stat.S_ISREG(info.st_mode):
            result[relative] = ("file", mode, hashlib.sha256(path.read_bytes()).hexdigest())
        else:
            raise ValueError(f"Unsupported candidate member: {relative}")
    return result


def verify_allowed_copy_changes(original, prepared, *, pristine_name=None, candidate_name=None,
                                signed_paths=frozenset()):
    del pristine_name, candidate_name
    keys = set(original) | set(prepared)
    unexpected = []
    for relative in sorted(keys):
        signature_member = "/_CodeSignature/" in f"/{relative}/" or relative.endswith("/_CodeSignature")
        allowed = relative == "Contents/Info.plist" or signature_member or relative in signed_paths
        if original.get(relative) != prepared.get(relative) and not allowed:
            unexpected.append(relative)
    if unexpected:
        raise ValueError(f"Validation copy changed non-signing members: {unexpected}")


def _plist_path(bundle: Path) -> Path:
    return bundle / "Contents/Info.plist"


def read_bundle_identifier(bundle: Path) -> str:
    with _plist_path(bundle).open("rb") as stream:
        value = plistlib.load(stream).get("CFBundleIdentifier")
    if not isinstance(value, str) or not value:
        raise ValueError(f"Missing CFBundleIdentifier: {bundle}")
    return value


def _write_validation_identity(bundle: Path, configured_identifier: str, validation_identifier: str):
    path = _plist_path(bundle)
    with path.open("rb") as stream:
        information = plistlib.load(stream)
    if information.get("CFBundleIdentifier") != configured_identifier:
        raise ValueError("Pristine app identity does not match product configuration")
    information["CFBundleIdentifier"] = validation_identifier
    with path.open("wb") as stream:
        plistlib.dump(information, stream, sort_keys=True)


def _verify_identity_only_changed(pristine: Path, candidate: Path,
                                  configured_identifier: str, validation_identifier: str):
    with _plist_path(pristine).open("rb") as stream:
        original = plistlib.load(stream)
    with _plist_path(candidate).open("rb") as stream:
        changed = plistlib.load(stream)
    if original.get("CFBundleIdentifier") != configured_identifier:
        raise ValueError("Pristine app identity changed during preparation")
    if changed.get("CFBundleIdentifier") != validation_identifier:
        raise ValueError("Validation app identity was not applied")
    changed["CFBundleIdentifier"] = configured_identifier
    if changed != original:
        raise ValueError("Validation copy changed product metadata other than CFBundleIdentifier")


def _signing_targets(app: Path) -> list[Path]:
    nested = [path for path in app.rglob("*")
              if not path.is_symlink() and path.is_dir()
              and path.suffix.lower() in {".app", ".framework", ".xpc", ".bundle"}]
    return sorted(nested, key=lambda path: (-len(path.relative_to(app).parts), path.as_posix())) + [app]


def _signed_content_paths(app: Path, targets: list[Path]) -> frozenset[str]:
    paths = set()
    for target in targets:
        plist = _plist_path(target)
        if plist.is_file():
            with plist.open("rb") as stream:
                executable = plistlib.load(stream).get("CFBundleExecutable")
            if isinstance(executable, str):
                binary = target / "Contents/MacOS" / executable
                if binary.exists():
                    paths.add(binary.relative_to(app).as_posix())
        if target.suffix.lower() == ".framework":
            for binary in (target / target.stem, target / "Versions/A" / target.stem):
                if binary.exists():
                    paths.add(binary.relative_to(app).as_posix())
    return frozenset(paths)


def _run(command):
    subprocess.run(command, check=True)


def prepare_candidate(pristine: Path, destination: Path, *, configured_identifier: str,
                      validation_token: str, runner=_run) -> Path:
    if not TOKEN.fullmatch(validation_token):
        raise ValueError("Validation token must be lowercase ASCII, digits, or hyphens")
    pristine = _require_plain_directory(pristine)
    destination_parent = _require_plain_directory(destination.parent)
    destination = destination_parent / destination.name
    if destination.exists() or destination.is_symlink():
        raise FileExistsError(destination)
    original = tree_manifest(pristine)
    shutil.copytree(pristine, destination, symlinks=True)
    copied = tree_manifest(destination)
    if copied != original:
        raise ValueError("Pristine candidate copy changed bytes, modes, or links")
    validation_identifier = f"{configured_identifier}.validation.{validation_token}"
    _write_validation_identity(destination, configured_identifier, validation_identifier)
    _verify_identity_only_changed(pristine, destination, configured_identifier, validation_identifier)
    identity_manifest = tree_manifest(destination)
    verify_allowed_copy_changes(original, identity_manifest)
    targets = _signing_targets(destination)
    signed_paths = _signed_content_paths(destination, targets)
    for target in targets:
        runner(["codesign", "--force", "--sign", "-", "--timestamp=none", str(target)])
    runner(["codesign", "--verify", "--deep", "--strict", str(destination)])
    verify_allowed_copy_changes(original, tree_manifest(destination), signed_paths=signed_paths)
    return destination


def _ensure_child(path: Path, root: Path) -> Path:
    if path.is_symlink():
        raise ValueError(f"Symlink is not allowed in validation root: {path}")
    resolved = path.resolve(strict=False)
    if not resolved.is_relative_to(root):
        raise ValueError(f"Validation path escapes root: {path}")
    return resolved


def create_preflight(parent: Path, *, bundle_identifier: str) -> dict:
    if ".validation." not in bundle_identifier or not bundle_identifier.rsplit(".validation.", 1)[1]:
        raise ValueError("Preflight requires a validation bundle identifier")
    parent = _require_plain_directory(parent)
    root = Path(tempfile.mkdtemp(prefix=PREFLIGHT_PREFIX, dir=parent)).resolve(strict=True)
    home = root / "Home"
    temporary = root / "Temp"
    preferences = home / "Library/Preferences"
    evidence = root / "evidence/events.jsonl"
    for directory in (preferences, temporary, evidence.parent):
        directory.mkdir(parents=True, exist_ok=False)
    support = home / "Library/Application Support/DynamicWallpaper"
    paths = {
        "applicationSupport": support,
        "library": support / "library-extended.json",
        "legacyLibrary": support / "library.json",
        "screenSaverExport": support / "ScreenSaverExport",
        "media": support / "Media",
        "systemWallpapers": support / "SystemWallpapers",
        "cefCache": temporary / "DynamicWallpaper-CEF" / bundle_identifier,
        "transcodeTemporary": temporary / "DynamicWallpaper-Transcode",
        "transcodeDiagnostics": temporary / "DynamicWallpaper-Transcode-Diagnostics",
        "preferences": preferences,
        "logs": support / "Logs",
        "evidence": evidence,
    }
    normalized = {name: str(_ensure_child(path, root)) for name, path in paths.items()}
    base = ["--validation-data-root", str(root), "--validation-evidence", str(evidence)]
    return {
        "root": str(root),
        "environment": {"CFFIXED_USER_HOME": str(home), "TMPDIR": str(temporary)},
        "arguments": base + ["--print-validation-paths"],
        "runtimeArguments": base,
        "paths": normalized,
    }


def run_preflight(executable: Path, layout: dict, *, runner=subprocess.run) -> dict:
    executable = executable.resolve(strict=True)
    environment = os.environ.copy()
    environment.update(layout["environment"])
    completed = runner([str(executable), *layout["arguments"]], env=environment,
                       check=True, capture_output=True, text=True)
    try:
        observed = json.loads(completed.stdout)
    except (AttributeError, json.JSONDecodeError) as error:
        raise ValueError("Validation preflight did not return one JSON document") from error
    expected = {
        "event": "preflight",
        "bundleIdentifier": read_bundle_identifier(executable.parents[2]),
        "preferencesDomain": read_bundle_identifier(executable.parents[2]),
        "fixedUserHome": layout["environment"]["CFFIXED_USER_HOME"],
        "temporaryRoot": layout["environment"]["TMPDIR"],
        "paths": layout["paths"],
    }
    if observed != expected:
        raise ValueError(f"Validation preflight paths differ: expected={expected!r} observed={observed!r}")
    return observed


def remove_preflight(root: Path):
    if root.is_symlink():
        raise ValueError(f"Refusing to remove symlinked preflight directory: {root}")
    root = root.resolve(strict=True)
    if not root.name.startswith(PREFLIGHT_PREFIX) or root.parent == root:
        raise ValueError(f"Refusing to remove non-preflight directory: {root}")
    shutil.rmtree(root)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    prepare = subparsers.add_parser("prepare")
    prepare.add_argument("pristine", type=Path)
    prepare.add_argument("destination", type=Path)
    prepare.add_argument("--token", required=True)
    preflight = subparsers.add_parser("preflight")
    preflight.add_argument("app", type=Path)
    preflight.add_argument("--parent", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "prepare":
        config = load_product_configuration()
        result = prepare_candidate(args.pristine, args.destination,
            configured_identifier=config.application.bundle_identifier, validation_token=args.token)
        print(result)
    else:
        app = args.app.resolve(strict=True)
        identifier = read_bundle_identifier(app)
        layout = create_preflight(args.parent, bundle_identifier=identifier)
        with _plist_path(app).open("rb") as stream:
            executable_name = plistlib.load(stream).get("CFBundleExecutable")
        if not isinstance(executable_name, str) or not executable_name:
            raise ValueError("Validation candidate has no executable")
        observed = run_preflight(app / "Contents/MacOS" / executable_name, layout)
        print(json.dumps({"layout": layout, "observed": observed}, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()

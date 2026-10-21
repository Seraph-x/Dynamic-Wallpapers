#!/usr/bin/env python3
"""Strict Swift 6-readiness compile gate while the package remains in Swift 5 mode."""

from __future__ import annotations

import argparse
from collections import Counter
from dataclasses import asdict, dataclass
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
from typing import Callable, Iterable, Mapping, Sequence


STRICT_FLAGS = [
    "-Xswiftc", "-strict-concurrency=complete",
    "-Xswiftc", "-warn-concurrency",
    "-Xswiftc", "-print-diagnostic-groups",
    "-Xswiftc", "-warnings-as-errors",
    "-Xswiftc", "-Wwarning",
    "-Xswiftc", "DeprecatedDeclaration",
]
DIRECT_STRICT_FLAGS = [value for index, value in enumerate(STRICT_FLAGS) if index % 2]
ANSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
SOURCE_LOCATION = re.compile(r"\.(?:swift|c|cc|cpp|cxx|m|mm|h|hh|hpp|hxx|inc):")
DIAGNOSTIC = re.compile(
    r"^(?P<path>.+):(?P<line>\d+):(?P<column>\d+): "
    r"(?P<severity>warning|error): (?P<message>.*?)(?: \[#(?P<group>[^\]]+)\])?$"
)
MODULE_EVIDENCE = re.compile(r"(?:^|\s)-module-name(?:\s+|=)(?:'|\")?(?P<name>[A-Za-z0-9_]+)")
CLANG_MODULE_EVIDENCE = re.compile(r"(?:^|\s)(?:'|\")?-fmodule-name=(?P<name>[A-Za-z0-9_]+)")


class GateFailure(RuntimeError):
    def __init__(self, message: str, report: dict[str, object] | None = None):
        super().__init__(message)
        self.report = report


@dataclass(frozen=True)
class Diagnostic:
    item: str
    severity: str
    path: str
    line: int
    column: int
    message: str
    group: str | None
    frontend_invocation: str


@dataclass(frozen=True)
class Allowance:
    item: str
    path: str
    line: int
    symbol: str
    group: str
    count: int


@dataclass(frozen=True)
class InventoryItem:
    name: str
    kind: str
    selection: str
    modules: tuple[str, ...]


@dataclass(frozen=True)
class CommandSpec:
    item: InventoryItem
    root: Path
    scratch: Path
    command: tuple[str, ...]
    environment: Mapping[str, str]


@dataclass(frozen=True)
class RunResult:
    returncode: int
    output: str
    timed_out: bool


Runner = Callable[[CommandSpec, int], RunResult]


def _normalize_path(value: str, repo_root: Path) -> str:
    anchor = str(repo_root.resolve(strict=False)) + "/"
    embedded = value.rfind(anchor)
    if embedded > 0:
        value = value[embedded:]
    path = Path(value)
    try:
        return path.resolve(strict=False).relative_to(repo_root.resolve(strict=False)).as_posix()
    except ValueError:
        return path.as_posix()


def _invocation_id(line: str) -> str:
    normalized = re.sub(r"\s+", " ", line.strip())
    return hashlib.sha256(normalized.encode("utf-8")).hexdigest()[:16]


def parse_diagnostics(item: str, output: str, repo_root: Path) -> tuple[Diagnostic, ...]:
    invocation = f"unattributed:{item}"
    parsed: list[Diagnostic] = []
    seen: set[tuple[object, ...]] = set()
    for raw_line in output.splitlines():
        line = ANSI.sub("", raw_line).strip()
        if "swift-frontend" in line:
            invocation = _invocation_id(line)
        match = DIAGNOSTIC.match(line)
        if match is None:
            if SOURCE_LOCATION.search(line) and (" warning:" in line or " error:" in line):
                raise GateFailure(f"malformed diagnostic for {item}: {line}")
            continue
        diagnostic = Diagnostic(
            item=item,
            severity=match.group("severity"),
            path=_normalize_path(match.group("path"), repo_root),
            line=int(match.group("line")),
            column=int(match.group("column")),
            message=match.group("message"),
            group=match.group("group"),
            frontend_invocation=invocation,
        )
        key = tuple(asdict(diagnostic).values())
        if key not in seen:
            seen.add(key)
            parsed.append(diagnostic)
    return tuple(parsed)


def _matches(diagnostic: Diagnostic, allowed: Allowance) -> bool:
    return (
        diagnostic.severity == "warning"
        and diagnostic.item == allowed.item
        and diagnostic.path == allowed.path
        and diagnostic.line == allowed.line
        and diagnostic.group == allowed.group
        and allowed.symbol in diagnostic.message
    )


def audit_diagnostics(
    diagnostics: Sequence[Diagnostic], allowances: Sequence[Allowance]
) -> tuple[Diagnostic, ...]:
    counts: Counter[int] = Counter()
    unexpected: list[Diagnostic] = []
    for diagnostic in diagnostics:
        matches = [index for index, allowed in enumerate(allowances)
                   if _matches(diagnostic, allowed)]
        if len(matches) != 1:
            unexpected.append(diagnostic)
            continue
        counts[matches[0]] += 1
    stale = [allowed for index, allowed in enumerate(allowances)
             if counts[index] != allowed.count]
    if unexpected or stale:
        details = []
        if unexpected:
            details.append("unexpected diagnostics: " + json.dumps(
                [asdict(value) for value in unexpected], ensure_ascii=False, sort_keys=True))
        if stale:
            details.append("unused allowance or count mismatch: " + json.dumps(
                [asdict(value) for value in stale], ensure_ascii=False, sort_keys=True))
        raise GateFailure("; ".join(details))
    return tuple(diagnostics)


def load_allowances(path: Path) -> tuple[Allowance, ...]:
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise GateFailure(f"cannot load allowlist {path}: {error}") from error
    if not isinstance(document, dict) or set(document) != {"schema_version", "allowances"}:
        raise GateFailure("allowlist must contain only schema_version and allowances")
    if document["schema_version"] != 1 or not isinstance(document["allowances"], list):
        raise GateFailure("unsupported allowlist schema")
    required = {"item", "path", "line", "symbol", "group", "count"}
    values: list[Allowance] = []
    for index, entry in enumerate(document["allowances"]):
        if not isinstance(entry, dict) or set(entry) != required:
            raise GateFailure(f"invalid allowance at index {index}")
        if (not all(isinstance(entry[key], str) and entry[key] for key in
                    ("item", "path", "symbol", "group"))
                or not isinstance(entry["line"], int) or entry["line"] < 1
                or not isinstance(entry["count"], int) or entry["count"] < 1):
            raise GateFailure(f"invalid allowance values at index {index}")
        values.append(Allowance(**entry))
    if len(set(values)) != len(values):
        raise GateFailure("duplicate allowances")
    return tuple(values)


def inventory_from_dump(document: Mapping[str, object]) -> tuple[InventoryItem, ...]:
    try:
        products = document["products"]
        targets = document["targets"]
    except KeyError as error:
        raise GateFailure(f"dump-package missing key: {error.args[0]}") from error
    if not isinstance(products, list) or not isinstance(targets, list):
        raise GateFailure("dump-package products and targets must be arrays")
    target_types: dict[str, str] = {}
    for target in targets:
        if not isinstance(target, dict) or not isinstance(target.get("name"), str) \
                or not isinstance(target.get("type"), str):
            raise GateFailure("malformed target in dump-package")
        name = target["name"]
        if name in target_types:
            raise GateFailure(f"duplicate target: {name}")
        target_types[name] = target["type"]
    entries: list[InventoryItem] = []
    for product in sorted(products, key=lambda value: value.get("name", "")):
        if not isinstance(product, dict) or not isinstance(product.get("name"), str) \
                or not isinstance(product.get("targets"), list):
            raise GateFailure("malformed product in dump-package")
        modules = tuple(product["targets"])
        if not modules or not all(isinstance(value, str) and value in target_types for value in modules):
            raise GateFailure(f"invalid product targets: {product['name']}")
        entries.append(InventoryItem(
            f"product:{product['name']}", "product", product["name"], modules))
    for name, kind in sorted(target_types.items()):
        if kind != "test":
            entries.append(InventoryItem(f"target:{name}", "target", name, (name,)))
    test_modules = tuple(sorted(name for name, kind in target_types.items() if kind == "test"))
    if test_modules:
        entries.append(InventoryItem("tests:all", "tests", "all", test_modules))
    entries.append(InventoryItem(
        "supplemental:ScreenSaverProbePlaybackTiming", "supplemental",
        "ScreenSaverProbePlaybackTiming", ("ScreenSaverProbePlaybackTiming",)))
    return tuple(entries)


def _slug(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.-]+", "-", value)


def command_specs(
    inventory: Sequence[InventoryItem], scratch_root: Path, repo_root: Path,
    sdk: Path, target: str,
) -> tuple[CommandSpec, ...]:
    environment = {**os.environ, "LC_ALL": "C", "LANG": "C", "TERM": "dumb"}
    environment.pop("SWIFT_SUPPRESS_WARNINGS", None)
    specs: list[CommandSpec] = []
    for entry in inventory:
        root = scratch_root / _slug(entry.name)
        scratch = root / "scratch"
        if entry.kind == "supplemental":
            command = (
                "xcrun", "swiftc", "-v", "-sdk", str(sdk), "-target", target,
                "-Xclang-linker", "-isysroot", "-Xclang-linker", str(sdk),
                "-parse-as-library", "-swift-version", "5",
                "-module-name", entry.selection,
                str(repo_root / "Tests/ScreenSaverProbeHarness/PlaybackTiming.swift"),
                str(repo_root / "scripts/feasibility/screensaver/ProbePlayback.swift"),
                "-framework", "AppKit", *DIRECT_STRICT_FLAGS,
                "-o", str(scratch / "PlaybackTiming"),
            )
        else:
            command_values = [
                sys.executable, str(repo_root / "scripts/swift_sdk.py"), "build",
                "--scratch-path", str(scratch),
                "--cache-path", str(root / "cache"),
                "--config-path", str(root / "config"),
                "--security-path", str(root / "security"),
                "--disable-sandbox", "--disable-dependency-cache",
                "--manifest-cache", "local", "--no-color-diagnostics", "-v",
            ]
            if entry.kind == "product":
                command_values.extend(("--product", entry.selection))
            elif entry.kind == "target":
                command_values.extend(("--target", entry.selection))
            elif entry.kind == "tests":
                command_values.append("--build-tests")
            else:
                raise GateFailure(f"unknown inventory kind: {entry.kind}")
            command_values.extend(("-Xswiftc", "-swift-version", "-Xswiftc", "5"))
            command_values.extend(STRICT_FLAGS)
            command = tuple(command_values)
        specs.append(CommandSpec(entry, root, scratch, command, dict(environment)))
    return tuple(specs)


def validate_isolation(specs: Sequence[CommandSpec]) -> None:
    roots = [spec.root.resolve(strict=False) for spec in specs]
    scratches = [spec.scratch.resolve(strict=False) for spec in specs]
    if len(set(roots)) != len(roots) or len(set(scratches)) != len(scratches):
        raise GateFailure("each inventory item must have a distinct scratch root")


def _module_evidence(output: str) -> set[str]:
    clean = ANSI.sub("", output)
    return ({match.group("name") for match in MODULE_EVIDENCE.finditer(clean)}
            | {match.group("name") for match in CLANG_MODULE_EVIDENCE.finditer(clean)})


def subprocess_runner(spec: CommandSpec, timeout: int) -> RunResult:
    try:
        result = subprocess.run(
            spec.command, cwd=Path.cwd(), env=dict(spec.environment), text=True,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout,
        )
        return RunResult(result.returncode, result.stdout, False)
    except subprocess.TimeoutExpired as error:
        output = error.stdout or ""
        if isinstance(output, bytes):
            output = output.decode("utf-8", errors="replace")
        return RunResult(124, output, True)


def execute_gate(
    package_dump: Mapping[str, object], allowances: Sequence[Allowance],
    scratch_root: Path, repo_root: Path, sdk: Path, target: str, *,
    runner: Runner = subprocess_runner, timeout: int = 300,
) -> dict[str, object]:
    inventory = inventory_from_dump(package_dump)
    specs = command_specs(inventory, scratch_root, repo_root, sdk, target)
    validate_isolation(specs)
    diagnostics: list[Diagnostic] = []
    item_reports: list[dict[str, object]] = []
    failures: list[str] = []
    for spec in specs:
        for directory in (spec.root, spec.scratch, spec.root / "cache",
                          spec.root / "config", spec.root / "security"):
            directory.mkdir(parents=True, exist_ok=True)
        result = runner(spec, timeout)
        log = spec.root / "compile.log"
        log.write_text(result.output, encoding="utf-8")
        try:
            item_diagnostics = parse_diagnostics(spec.item.name, result.output, repo_root)
            diagnostics.extend(item_diagnostics)
        except GateFailure as error:
            item_diagnostics = ()
            failures.append(str(error))
        item_report = {
            "item": spec.item.name,
            "kind": spec.item.kind,
            "command": list(spec.command),
            "scratch": str(spec.scratch),
            "returncode": result.returncode,
            "timed_out": result.timed_out,
            "log": str(log),
            "diagnostic_count": len(item_diagnostics),
        }
        item_reports.append(item_report)
        if result.timed_out:
            failures.append(f"{spec.item.name} timed out")
            continue
        if result.returncode != 0:
            failures.append(f"{spec.item.name} nonzero exit {result.returncode}")
        evidence = _module_evidence(result.output)
        missing = sorted(set(spec.item.modules) - evidence)
        if missing:
            failures.append(f"{spec.item.name} missing module evidence: {missing}")
    audit_error = None
    try:
        allowed = audit_diagnostics(diagnostics, allowances)
    except GateFailure as error:
        allowed = ()
        audit_error = str(error)
        failures.append(audit_error)
    report = {
        "schema_version": 1,
        "inventory_count": len(inventory),
        "items": item_reports,
        "diagnostics": [asdict(value) for value in diagnostics],
        "allowed_diagnostics": [asdict(value) for value in allowed],
        "unexpected_diagnostics": [] if audit_error is None else [asdict(value) for value in diagnostics],
        "allowances": [asdict(value) for value in allowances],
    }
    if failures:
        raise GateFailure("; ".join(failures), report)
    return report


def _exclusive_json(path: Path, document: Mapping[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        json.dump(document, stream, ensure_ascii=False, indent=2, sort_keys=True)
        stream.write("\n")


def _dump_package(root: Path) -> Mapping[str, object]:
    isolated = root / "package-inventory"
    for child in ("cache", "config", "security"):
        (isolated / child).mkdir(parents=True, exist_ok=True)
    command = [
        "swift", "package", "--cache-path", str(isolated / "cache"),
        "--config-path", str(isolated / "config"),
        "--security-path", str(isolated / "security"), "dump-package",
    ]
    result = subprocess.run(command, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=300)
    if result.returncode != 0:
        raise GateFailure(f"dump-package failed: {result.stderr}")
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise GateFailure(f"dump-package returned invalid JSON: {error}") from error


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scratch-root", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--allowlist", type=Path,
                        default=Path("scripts/swift6-warning-allowlist.json"))
    parser.add_argument("--timeout", type=int, default=300)
    arguments = parser.parse_args()
    if arguments.timeout < 1:
        parser.error("--timeout must be positive")
    for path in (arguments.scratch_root, arguments.report):
        if path.exists() or path.is_symlink():
            raise FileExistsError(path)
    arguments.scratch_root.mkdir(parents=True)
    repo_root = Path(__file__).resolve().parents[1]
    try:
        package_dump = _dump_package(arguments.scratch_root)
        sdk = Path(subprocess.check_output(
            ["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip())
        target = f"{platform.machine()}-apple-macosx14.0"
        report = execute_gate(
            package_dump, load_allowances(arguments.allowlist), arguments.scratch_root,
            repo_root, sdk, target, timeout=arguments.timeout)
    except GateFailure as error:
        report = {"schema_version": 1, "status": "failed", "error": str(error),
                  **(error.report or {})}
        _exclusive_json(arguments.report, report)
        print(str(error), file=sys.stderr)
        return 1
    report["status"] = "passed"
    _exclusive_json(arguments.report, report)
    print(json.dumps({"status": "passed", "inventory_count": report["inventory_count"],
                      "allowed_diagnostic_count": len(report["allowed_diagnostics"])},
                     sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

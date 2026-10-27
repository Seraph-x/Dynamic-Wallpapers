#!/usr/bin/env python3
"""Build/run native media tests without CEF or a personal player's library.

--automation launches only owned fixture apps and sends real Apple Events.
--build-only never launches an app. Consent is requested only when the explicit
--authorize-owned-fixture flag is provided; it never targets Music or Spotify.
"""
import argparse
import json
from pathlib import Path
import plistlib
import runpy
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
ARTIFACTS = ROOT / '.build/verification/public-media'
PACKAGE = ARTIFACTS / 'package'
SUPERVISE = runpy.run_path(str(ROOT / 'scripts/test.py'))['run_tests']


def package():
    PACKAGE.mkdir(parents=True, exist_ok=True)
    for name, source in [('WallpaperCore', 'Sources/WallpaperCore'),
                         ('WallpaperMediaIntegration', 'Sources/WallpaperMediaIntegration'),
                         ('WallpaperCoreTests', 'Tests/WallpaperCoreTests'),
                         ('WallpaperMediaIntegrationTests', 'Tests/WallpaperMediaIntegrationTests'),
                         ('MediaAutomationHarness', 'Tests/MediaAutomationHarness')]:
        destination = PACKAGE / name
        if destination.exists() and destination.resolve() != (ROOT / source).resolve():
            raise ValueError(f'Test source link points at a different checkout: {destination}')
        if not destination.exists():
            destination.symlink_to(ROOT / source, target_is_directory=True)
    (PACKAGE / 'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "PublicMediaTests", platforms: [.macOS(.v14)], products: [
 .executable(name: "MediaAutomationFixture", targets: ["MediaAutomationFixture"]),
 .executable(name: "MediaAutomationClient", targets: ["MediaAutomationClient"]),
], targets: [
 .target(name: "WallpaperCore", path: "WallpaperCore"),
 .target(name: "WallpaperMediaIntegration", dependencies: ["WallpaperCore"], path: "WallpaperMediaIntegration"),
 .testTarget(name: "WallpaperCoreTests", dependencies: ["WallpaperCore"], path: "WallpaperCoreTests"),
 .testTarget(name: "WallpaperMediaIntegrationTests", dependencies: ["WallpaperMediaIntegration", "WallpaperCore"], path: "WallpaperMediaIntegrationTests"),
 .executableTarget(name: "MediaAutomationFixture", path: "MediaAutomationHarness", exclude: ["Client.swift"], sources: ["Fixture.swift"]),
 .executableTarget(name: "MediaAutomationClient", dependencies: ["WallpaperMediaIntegration", "WallpaperCore"], path: "MediaAutomationHarness", exclude: ["Fixture.swift"], sources: ["Client.swift"]),
], swiftLanguageModes: [.v5])
''')


def swift(action, *arguments):
    return [sys.executable, str(ROOT / 'scripts/swift_sdk.py'), action,
            '--disable-sandbox', '--package-path', str(PACKAGE), *arguments]


def app(binary, bin_directory):
    destination = ARTIFACTS / f'{binary}.app'
    executable = destination / 'Contents/MacOS' / binary
    executable.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(bin_directory / binary, executable)
    with (destination / 'Contents/Info.plist').open('wb') as output:
        plistlib.dump({'CFBundleExecutable': binary,
                       'CFBundleIdentifier': f'local.dynamicwallpaper.tests.{binary.lower()}',
                       'CFBundleName': binary, 'CFBundlePackageType': 'APPL',
                       'LSUIElement': True, 'LSMinimumSystemVersion': '14.0',
                       'NSAppleEventsUsageDescription': 'Verify public media Automation using an owned test fixture only; personal music players are never targeted.'}, output)
    subprocess.run(['codesign', '--force', '--sign', '-', str(destination)], check=True)
    subprocess.run(['codesign', '--verify', '--strict', str(destination)], check=True)
    return executable


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    phase = parser.add_mutually_exclusive_group()
    phase.add_argument('--build-only', action='store_true')
    phase.add_argument('--run-only', action='store_true')
    parser.add_argument('--automation', action='store_true')
    parser.add_argument('--authorize-owned-fixture', action='store_true')
    parser.add_argument('--filter')
    options = parser.parse_args()
    if options.authorize_owned_fixture and not options.automation:
        parser.error('--authorize-owned-fixture requires --automation')
    package()
    print(f'PUBLIC_MEDIA artifacts={ARTIFACTS}', flush=True)
    results = {}
    def record():
        (ARTIFACTS / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    record()
    if not options.run_only:
        results['build'] = SUPERVISE(swift('build', '--build-tests'), timeout_seconds=180, label='Public media cold build')
        record()
        if results['build']:
            return results['build']
        binary_directory = Path(subprocess.check_output(swift('build', '--show-bin-path'), text=True).strip())
        app('MediaAutomationFixture', binary_directory)
        app('MediaAutomationClient', binary_directory)
    if options.build_only:
        return 0
    selection = ['--filter', options.filter] if options.filter else []
    results['unit'] = SUPERVISE(swift('test', '--skip-build', *selection), timeout_seconds=60, label='Public media unit tests')
    record()
    if results['unit']:
        return results['unit']
    if options.automation:
        command = [sys.executable, str(ROOT / 'scripts/run-media-automation.py'), str(ARTIFACTS)]
        if options.authorize_owned_fixture:
            command.append('--authorize-owned-fixture')
        results['automation'] = SUPERVISE(command, timeout_seconds=60, label='Public media actual Apple Events')
    record()
    return results.get('automation', 0)


if __name__ == '__main__':
    sys.exit(main())

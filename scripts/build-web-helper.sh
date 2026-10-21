#!/bin/bash
# Prepare development dependencies only; never launch or sign the outer app.
set -euo pipefail
if [ "$#" -gt 1 ]; then
  echo "usage: bash scripts/build-web-helper.sh [DEVELOPMENT_APP_PATH]" >&2
  exit 64
fi
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$(python3 - "$REPO_ROOT" "${1:-}" <<'PY'
import pathlib, sys
repo = pathlib.Path(sys.argv[1])
requested = pathlib.Path(sys.argv[2]).absolute() if sys.argv[2] else repo / '.build/dependencies/cef/DynamicWallpaperCEF.app'
resolved = requested.resolve()
for path in (requested, resolved):
    if any(part.casefold() in {'applications', 'dist'} for part in path.parts):
        raise SystemExit(f'Refusing installed/distribution app target: {path}')
if resolved.suffix != '.app':
    raise SystemExit(f'Development target must end in .app: {resolved}')
if resolved.exists() and not resolved.is_dir():
    raise SystemExit(f'Development target is not a directory: {resolved}')
for relative in ('Contents', 'Contents/Frameworks'):
    directory = resolved / relative
    if directory.is_symlink() or (directory.exists() and not directory.is_dir()):
        raise SystemExit(f'Refusing redirected/non-directory dependency location: {directory}')
print(resolved)
PY
)"
cd "$REPO_ROOT"
PRODUCT_CONFIG_JSON="$(python3 scripts/product_configuration.py --emit shell-json)"
read -r TARGET_ARCH MINIMUM_MACOS CEF_VERSION < <(python3 - "$PRODUCT_CONFIG_JSON" <<'PY'
import json, pathlib, sys
product = json.loads(sys.argv[1])
dependencies = json.loads(pathlib.Path('scripts/media-dependencies.json').read_text())
architecture = product['target']['architecture']
if architecture != 'arm64':
    raise SystemExit(f'Unsupported CEF helper architecture: {architecture}')
print(architecture, product['target']['minimum_macos'], dependencies['modules']['cef']['version'])
PY
)
CEF_ROOT="$REPO_ROOT/.build/dependencies/cef/cef_binary_${CEF_VERSION}_macosarm64_minimal"
WRAPPER="$REPO_ROOT/.build/dependencies/cef/wrapper-make/libcef_dll_wrapper/libcef_dll_wrapper.a"
FRAMEWORK_NAME="Chromium Embedded Framework.framework"
if [ ! -d "$CEF_ROOT/Release/$FRAMEWORK_NAME" ] || [ ! -f "$WRAPPER" ]; then
  echo "Locked CEF framework or compiled wrapper is missing." >&2
  exit 1
fi
STAGING="$(mktemp -d "$REPO_ROOT/.build/dependencies/cef/helper-build.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
clang++ -std=c++20 "-mmacosx-version-min=$MINIMUM_MACOS" -arch "$TARGET_ARCH" \
  -fobjc-arc -frtti -Wall -Wextra -Werror \
  -isystem "$CEF_ROOT" Sources/WebWallpaperHelper/main.mm "$WRAPPER" \
  -framework AppKit -o "$STAGING/WebWallpaperHelper"
mkdir -p "$STAGING/Frameworks"
cp -R "$CEF_ROOT/Release/$FRAMEWORK_NAME" "$STAGING/Frameworks/"
python3 - "$STAGING" "$APP" "$PRODUCT_CONFIG_JSON" <<'PY'
import json, pathlib, plistlib, shutil, subprocess, sys

stage, app = map(pathlib.Path, sys.argv[1:3])
configuration = json.loads(sys.argv[3])
frameworks = stage / 'Frameworks'
framework = frameworks / 'Chromium Embedded Framework.framework'

def sign(path):
    subprocess.run(['codesign', '--force', '--sign', '-', str(path)], check=True)

def verify(path):
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(path)], check=True)

# Sign real nested Mach-O files first; preserve the framework's symlinks.
for path in sorted(framework.rglob('*')):
    if path.is_symlink() or not path.is_file():
        continue
    description = subprocess.check_output(['file', '-b', str(path)], text=True)
    if 'Mach-O' in description:
        sign(path)
sign(framework)
verify(framework)

dependencies = [framework]
for helper_config in configuration['cef_helpers']:
    suffix = helper_config['suffix']
    name = f'{configuration["application"]["executable"]} Helper{suffix}'
    helper = frameworks / f'{name}.app'
    contents = helper / 'Contents'
    executable = contents / 'MacOS' / name
    executable.parent.mkdir(parents=True)
    shutil.copy2(stage / 'WebWallpaperHelper', executable)
    with (contents / 'Info.plist').open('wb') as output:
        plistlib.dump({'CFBundleExecutable': name, 'CFBundleName': name,
                      'CFBundleIdentifier': helper_config['bundle_identifier'],
                      'CFBundlePackageType': 'APPL', 'LSUIElement': True,
                      'LSMinimumSystemVersion': configuration['target']['minimum_macos'],
                      'CFBundleShortVersionString': configuration['version'],
                      'CFBundleVersion': configuration['build'],
                      'NSHighResolutionCapable': True}, output)
    sign(executable)
    sign(helper)
    verify(helper)
    dependencies.append(helper)

destination = app / 'Contents/Frameworks'
# Validate every managed destination before replacing any existing dependency.
for directory in (app, app / 'Contents', destination):
    if directory.is_symlink() or (directory.exists() and not directory.is_dir()):
        raise SystemExit(f'Refusing redirected/non-directory destination: {directory}')
for dependency in dependencies:
    target = destination / dependency.name
    if target.is_symlink() or (target.exists() and not target.is_dir()):
        raise SystemExit(f'Refusing redirected/non-directory dependency: {target}')
destination.mkdir(parents=True, exist_ok=True)
for dependency in dependencies:
    target = destination / dependency.name
    if target.exists():
        shutil.rmtree(target)
    shutil.move(str(dependency), str(target))
    verify(target)
print(f'CEF development dependencies prepared: {destination}', flush=True)
print('Outer application executable, Info.plist and signature were not modified.', flush=True)
PY

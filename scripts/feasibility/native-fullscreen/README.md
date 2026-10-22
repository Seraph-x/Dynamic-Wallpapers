# Main Window Native Full Screen Regression

Verifies the real SwiftUI main window, instead of manually adding `.fullScreenPrimary` to a window created by XCTest.
The criteria are the system's enter/exit notifications and the `.fullScreen` flag; a maximized window does not count as a pass.

While a management window is open, both Dock preferences should use `.regular` so the native app menu is shown;
temporarily showing the icon does not rewrite the saved preference. The hidden preference only takes effect after all management windows are closed.

Requires a working macOS graphical session and the Swift/Clang toolchain. Runs serially with the other GUI tests.
The commands below only launch an isolated-identity validation copy; each of the two Dock settings uses a fresh library, no login item is registered,
system wallpaper sync is not enabled, and neither Magnet nor the release app in use is touched.

```sh
set -euo pipefail
export CANDIDATE="$PWD/dist/Dynamic Wallpaper.app" # or point it at a freshly built candidate
mkdir -p .build/verification
export RUN_DIR="$(mktemp -d "$PWD/.build/verification/native-fullscreen-replay-XXXXXX")"
export VALIDATION_APP="$RUN_DIR/Dynamic Wallpaper Validation.app"
export VALIDATION_ID="local.dynamicwallpaper.native-fullscreen-validation.$(date -u +%Y%m%d%H%M%S)"
ditto "$CANDIDATE" "$VALIDATION_APP"
python3 - <<'PY'
import os, plistlib
from pathlib import Path
info = Path(os.environ['VALIDATION_APP']) / 'Contents/Info.plist'
value = plistlib.loads(info.read_bytes())
value.update(CFBundleIdentifier=os.environ['VALIDATION_ID'],
             CFBundleName='Dynamic Wallpaper Validation', CFBundleDisplayName='Dynamic Wallpaper Validation')
info.write_bytes(plistlib.dumps(value))
PY
codesign --force --sign - "$VALIDATION_APP"
codesign --verify --deep --strict "$VALIDATION_APP"
xcrun clang -dynamiclib -fobjc-arc -Wall -Wextra -Werror -framework Cocoa \
  scripts/feasibility/native-fullscreen/WindowProbe.m -o "$RUN_DIR/WindowProbe.dylib"
codesign --force --sign - "$RUN_DIR/WindowProbe.dylib"
swiftc scripts/feasibility/native-fullscreen/VerifyNativeFullScreen.swift -o "$RUN_DIR/VerifyNativeFullScreen"
for mode in hide show; do
  "$RUN_DIR/VerifyNativeFullScreen" "$VALIDATION_APP" "$RUN_DIR/$mode" "$mode" \
    "$RUN_DIR/WindowProbe.dylib" "$VALIDATION_ID"
done
```

The probe only observes windows and calls `toggleFullScreen(_:)`; it **does not modify window style or full-screen eligibility**.
Each native transition is capped at 6 seconds; launch preparation is capped at 10 seconds; a normal quit is capped at 5 seconds.
Timeouts and forced cleanup are written to `failures.json` and return non-zero; they do not count as a pass.
`window.json` keeps the activation policy before and after, the window flags, the sheet state, and the native notification sequence.

Swift targeted tests run separately:

```sh
python3 scripts/test.py --filter NativeFullScreenWindowTests
```

These tests cover eligibility setup, flag preservation, remounting, and exclusion of fixed-size windows in the macOS 14 AppKit compatibility implementation;
running these unit tests on a newer system does not mean macOS 14 on real hardware has been accepted.

# Replay Login and Window Lifecycle Verification

These probes are not shipped in the product bundle. They only accept the designated isolated validation identity and do not touch the `local.dynamicwallpaper.app` login item. The app under validation keeps its own identity; window acceptance uses another copy and a fresh temporary library.

Requires Apple Silicon, the Swift toolchain, a working graphical session, and screen recording permission already granted to the terminal. `VerifyCandidate` fails immediately when that permission is missing; it never requests it automatically or fabricates a result. All commands run from the repository root in the same shell; **GUI probes and XCTest must run serially**.

## Verify the Current App or an Isolated Candidate

By default the already-deployed release app is used to prepare an isolated copy; the original development candidate and the old validation bundles were cleaned up at the user's request, while logs and sources are kept. To verify a different candidate, point `CANDIDATE` at its path. The command to build a new candidate is in the checkpoint; the output must be a new path that does not exist yet, and must not name the currently running app.

```sh
set -euo pipefail
export CANDIDATE="$PWD/dist/Dynamic Wallpaper.app"
mkdir -p .build/verification/login-menubar
RUN_DIR="$(mktemp -d "$PWD/.build/verification/login-menubar/replay-XXXXXX")"
export RUN_DIR
export VALIDATION_APP="$RUN_DIR/Dynamic Wallpaper Validation.app"
ditto "$CANDIDATE" "$VALIDATION_APP"
python3 - <<'PY'
import os, plistlib
from pathlib import Path
info = Path(os.environ['VALIDATION_APP']) / 'Contents/Info.plist'
value = plistlib.loads(info.read_bytes())
value['CFBundleIdentifier'] = 'local.dynamicwallpaper.window-validation.20260914'
value['CFBundleName'] = 'Dynamic Wallpaper Validation'
value['CFBundleDisplayName'] = 'Dynamic Wallpaper Validation'
info.write_bytes(plistlib.dumps(value))
PY
codesign --force --sign - "$VALIDATION_APP"
codesign --verify --deep --strict "$VALIDATION_APP"
swift scripts/feasibility/startup/VerifyCandidate.swift \
  "$VALIDATION_APP" "$RUN_DIR/accessory" hide
swift scripts/feasibility/startup/VerifyCandidate.swift \
  "$VALIDATION_APP" "$RUN_DIR/regular" show
```

Each round creates its own `home/Library/Application Support/DynamicWallpaper/library-extended.json` and PNG, and launches with `CFFIXED_USER_HOME`. It verifies the real bundle URL, the saved Dock policy, and that the isolated wallpaper has been restored; it does not call login item registration.

- Manual launch: one main window, app activated; `.regular` is used while the window is open, and the native app menu is shown even when the saved Dock preference is hidden.
- Standard login Apple Event launch: no management window and no activation during sampling, the desktop window is present; the Dock policy follows the saved preference.
- Reopen while already running, repeated reopen: one main window is shown, reusing the same PID, desktop window, and main window.
- On exit only the isolated validation app is terminated; results are written to `windows.json` and `failures.json`, and failure exits with code 1.

The probe starts sampling when the request is issued, waits for the real `isFinishedLaunching`, then keeps sampling for one second; cold start is capped at ten seconds. This is an external observation window, not a product delay switch or a “show a window first, then close it”. An injected Apple Event cannot replace real logout/login acceptance.

### Reproduce the External Hide Failure Separately

On the current system `NSRunningApplication.hide()` returns `false` in both Dock modes. The command below preserves this failure and cannot be treated as a successful acceptance:

```sh
swift scripts/feasibility/startup/VerifyCandidate.swift \
  "$VALIDATION_APP" "$RUN_DIR/external-hide" show --check-external-hide
```

That cross-process method is not `NSApplication.hide(_:)` as invoked by `⌘H`. Real same-process hiding, Dock switching, window closing, and player cleanup are verified by `ApplicationResidencyIntegrationTests`; this round did not actually inject a `⌘H` key press into the candidate app.

## Build the Two Small Probes

The commands below continue to use the fresh `RUN_DIR` from above. `StartupProbe` only observes SwiftUI's implicit scene behavior and **is not the explicit main-window routing implementation of the final product**; `VerifyCandidate` is the reference for full functionality.

```sh
python3 - <<'PY'
import os, plistlib
from pathlib import Path
root = Path(os.environ['RUN_DIR'])
identities = {
    'StartupProbe': 'local.dynamicwallpaper.startup-probe.20260914',
    'LoginRegistrationProbe': 'local.dynamicwallpaper.login-validation.20260914',
}
for name, identity in identities.items():
    contents = root / f'{name}.app/Contents'
    (contents / 'MacOS').mkdir(parents=True)
    info = {'CFBundleExecutable': name, 'CFBundleIdentifier': identity,
            'CFBundleName': name, 'CFBundlePackageType': 'APPL',
            'CFBundleVersion': '1', 'LSMinimumSystemVersion': '14.0',
            'LSUIElement': True}
    (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
PY
swiftc -swift-version 5 -parse-as-library -target arm64-apple-macosx14.0 \
  scripts/feasibility/startup/StartupProbe.swift \
  -o "$RUN_DIR/StartupProbe.app/Contents/MacOS/StartupProbe"
swiftc -swift-version 5 -parse-as-library -target arm64-apple-macosx14.0 \
  Sources/WallpaperApp/LoginItemService.swift \
  scripts/feasibility/startup/LoginRegistrationProbe.swift \
  -o "$RUN_DIR/LoginRegistrationProbe.app/Contents/MacOS/LoginRegistrationProbe"
codesign --force --sign - "$RUN_DIR/StartupProbe.app"
codesign --force --sign - "$RUN_DIR/LoginRegistrationProbe.app"
```

### Observe the SwiftUI Launch Sequence

```sh
swift scripts/feasibility/startup/ObserveLaunch.swift \
  "$RUN_DIR/StartupProbe.app" "$RUN_DIR/manual.trace" manual accessory
swift scripts/feasibility/startup/ObserveLaunch.swift \
  "$RUN_DIR/StartupProbe.app" "$RUN_DIR/login.trace" login regular
```

It outputs `willFinish`, `didFinish`, the scene appearance order, the Apple Event marker, and the window and activation state; the probe exits after a three-second observation. The trace path must be a new file. `baseline` means the activation policy is not switched in the callback; it is not a full regression of older product versions.

### Verify Real Registration and Deregistration

This step **briefly registers an isolated test identity** and then explicitly deregisters it; it does not register the main candidate or the currently running product identity. The probe errors out when the identity is already enabled or awaiting approval, and it does not revoke the user's existing choice. Do not run the same identity concurrently.

```sh
open -W -n "$RUN_DIR/LoginRegistrationProbe.app" \
  --args "$RUN_DIR/login-registration.json"
python3 - <<'PY'
import json, os
from pathlib import Path
result = json.loads((Path(os.environ['RUN_DIR']) / 'login-registration.json').read_text())
print(json.dumps(result, indent=2))
assert result['bundleID'] == 'local.dynamicwallpaper.login-validation.20260914'
assert result['before'] in (0, 3), result
assert result['registered'] in (1, 2), result
assert result['after'] == 0 and result['errors'] == [], result
PY
```

`SMAppService.Status` values are `0 = notRegistered`, `1 = enabled`, `2 = requiresApproval`, `3 = notFound`. `open -W` does not reliably propagate the child app's failure exit code, so the JSON must be checked; `2` can only be described as awaiting approval, not as properly enabled. If the final `after != 0` or errors are present, cleanup did not pass and must not be ignored.

Artifacts are kept in `RUN_DIR`; evidence is not deleted automatically. For the current completion status, failure records, and untested boundaries, see [login and menu bar checkpoint](../../../docs/login-menubar-checkpoint.md).

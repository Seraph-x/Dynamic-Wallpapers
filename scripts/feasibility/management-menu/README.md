# Native App Menu Regression

Verifies the real app under the hidden Dock preference: background login shows no window, and after a management window opens the app enters `.regular`,
the native menu actually belongs to that process and has a non-zero display size; minimizing, hiding, opening settings / transcoding / help,
closing the windows one by one, and reopening them all go through real AppKit / Accessibility operations.
Closing the last management window should restore `.accessory`, and the isolated library's file contents must stay unchanged.
Passing `--show-dock` verifies the visible Dock preference with a separate evidence directory; in that case the app stays `.regular` after all windows are closed.
Passing `--cold-start` verifies a manual cold start; by default it verifies reopening after background login. Both startup paths and both preferences must be covered.

Requires a local graphical session, the Swift toolchain, and accessibility permission already granted to the terminal. Runs serially with GUI XCTest.
No screen recording permission is needed, and it does not modify the release app, the user's library, login items, or the system wallpaper.

```sh
set -euo pipefail
export CANDIDATE="$PWD/dist/Dynamic Wallpaper.app" # 已部署版本；也可指定新候选
export RUN_DIR="$(mktemp -d "$PWD/.build/verification/management-menu-replay-XXXXXX")"
export VALIDATION_APP="$RUN_DIR/Validation.app"
ditto "$CANDIDATE" "$VALIDATION_APP"
python3 - <<'PY'
import os, pathlib, plistlib, uuid
path = pathlib.Path(os.environ['VALIDATION_APP']) / 'Contents/Info.plist'
info = plistlib.loads(path.read_bytes())
info['CFBundleIdentifier'] = 'local.dynamicwallpaper.menu-validation.' + uuid.uuid4().hex
path.write_bytes(plistlib.dumps(info))
PY
codesign --force --sign - "$VALIDATION_APP"
swiftc scripts/feasibility/management-menu/VerifyManagementMenu.swift -o "$RUN_DIR/VerifyManagementMenu"
"$RUN_DIR/VerifyManagementMenu" "$VALIDATION_APP" "$RUN_DIR/login-hide"
"$RUN_DIR/VerifyManagementMenu" "$VALIDATION_APP" "$RUN_DIR/login-show" --show-dock
"$RUN_DIR/VerifyManagementMenu" "$VALIDATION_APP" "$RUN_DIR/cold-hide" --cold-start
"$RUN_DIR/VerifyManagementMenu" "$VALIDATION_APP" "$RUN_DIR/cold-show" --cold-start --show-dock
```

The probe points `CFFIXED_USER_HOME` at a fresh library and only acts on the isolated validation identity; its process uses English menus.
A native menu existing in the AX tree is not enough to pass: the process must also own the system menu bar and the menu items must have a visible size.
All readiness waits are capped at 10 seconds; errors are recorded in `menus.json` in each round's directory, and failures return non-zero; clicks are not faked and assertions are not skipped.

## Activation Timing Regression

An already-active `.accessory` app may still not own the system menu bar after switching to `.regular`.
The product hands activation to the system Dock only when this mode switch needs a handoff, waits for the real deactivation event to be processed, and then re-activates.
Switching to another app, hiding, closing all management windows, or quitting cancels the current handoff; there is no fixed delay or automatic retry.
When the Dock is unavailable, rejects the request, or does not grant menu ownership within 5 seconds, the error is shown through the existing runtime mode prompt; opening the window manually again retries.
Unit tests cover event order, duplicate request coalescing, cancellation, rejection, timeout, and manual retry:

```sh
python3 scripts/test.py --filter 'NativeMenuActivationTests|ApplicationMenuLifecycleTests|ApplicationPresentationTests'
```

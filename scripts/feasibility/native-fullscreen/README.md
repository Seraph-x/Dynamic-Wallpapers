# 主窗口原生全屏回归

验证真实 SwiftUI 主窗口，而不是给 XCTest 创建的窗口手动添加 `.fullScreenPrimary`。
判据是系统的进入/退出通知和 `.fullScreen` 标志，窗口最大化不算通过。

管理窗口打开期间，两种 Dock 偏好都应采用 `.regular` 以显示原生应用菜单；
临时显示图标不改写保存的偏好。隐藏偏好只在全部管理窗口关闭后生效。

需要可用的 macOS 图形会话和 Swift/Clang 工具链。与其他 GUI 测试串行运行。
以下命令只启动独立身份的验证副本；两种 Dock 设置各用全新素材库，不注册登录项，
不启用系统底图同步，也不操作 Magnet 或正在使用的正式应用。

```sh
set -euo pipefail
export CANDIDATE="$PWD/dist/Dynamic Wallpaper.app" # 也可以指定新构建的候选包
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

探针只观察窗口并调用 `toggleFullScreen(_:)`，**不修改窗口样式或全屏资格**。
每次原生过渡限时 6 秒；启动准备限时 10 秒；正常退出限时 5 秒。
超时和被迫清理都会写入 `failures.json` 并返回非零，不作为通过。
`window.json` 保留前后激活策略、窗口标志、sheet 状态及原生通知序列。

Swift 定向测试另行运行：

```sh
python3 scripts/test.py --filter NativeFullScreenWindowTests
```

该测试覆盖 macOS 14 AppKit 兼容实现的资格设置、标志保留、重挂载及固定尺寸窗口排除；
在新系统运行这些单元测试不代表已经完成 macOS 14 真机验收。

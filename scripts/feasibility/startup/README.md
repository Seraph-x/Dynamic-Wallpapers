# 重放登录与窗口生命周期验证

这些探针不进入产品包。它们只接受指定的独立验证身份，不操作 `local.dynamicwallpaper.app` 的登录项。待验证应用本身不改身份；窗口验收使用另一个副本和全新临时素材库。

需要 Apple Silicon、Swift 工具链、可用的图形会话，以及终端已有的屏幕录制权限。`VerifyCandidate` 缺少权限时直接失败，不自动申请或伪造结果。所有命令从仓库根目录在同一个 shell 中执行；**GUI 探针与 XCTest 必须串行运行**。

## 验证当前应用或独立候选

默认使用已经部署的正式应用准备独立副本；原研发候选和旧验证包已按用户请求清理，日志与源码保留。要验证另一个候选，将 `CANDIDATE` 改为其路径。构建新候选的命令见检查点，输出必须是尚未存在的新路径，不能指定当前运行的应用。

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

每轮创建自己的 `home/Library/Application Support/DynamicWallpaper/library-extended.json` 和 PNG，使用 `CFFIXED_USER_HOME` 启动。验证真实 bundle URL、保存的 Dock 策略和隔离壁纸已恢复；不会调用登录项注册。

- 手动启动：一个主窗口，应用激活；窗口打开期间采用 `.regular`，即使保存的 Dock 偏好为隐藏也显示原生应用菜单。
- 标准登录 Apple Event 启动：采样期间没有管理窗口、没有激活，正式桌面窗口存在；Dock 策略遵循保存的偏好。
- 已运行时重开、重复重开：显示一个主窗口，复用同一 PID、桌面窗口和主窗口。
- 结束时只终止独立验证应用；结果写入 `windows.json`、`failures.json`，失败退出码为 1。

探针从请求发出开始采样，等待真实 `isFinishedLaunching` 后继续采样一秒，冷启动上限十秒。这是外部观察期限，不是产品的延时开关或“先弹窗再关闭”。不能用注入的 Apple Event 代替真实注销/重新登录验收。

### 单独复现外部隐藏失败

当前系统上 `NSRunningApplication.hide()` 在两个 Dock 模式均返回 `false`。以下命令保留这一失败，不能当作成功验收：

```sh
swift scripts/feasibility/startup/VerifyCandidate.swift \
  "$VALIDATION_APP" "$RUN_DIR/external-hide" show --check-external-hide
```

该跨进程方法不是 `⌘H` 调用的 `NSApplication.hide(_:)`。真实同进程隐藏、Dock 切换、关窗和播放器清理由 `ApplicationResidencyIntegrationTests` 验证；本轮未向候选应用实际注入 `⌘H` 按键。

## 构建两个小型探针

以下命令继续使用上面的全新 `RUN_DIR`。`StartupProbe` 只观察 SwiftUI 的隐式场景行为，**不是最终产品的显式主窗口路由实现**；完整功能以 `VerifyCandidate` 为准。

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

### 观察 SwiftUI 启动顺序

```sh
swift scripts/feasibility/startup/ObserveLaunch.swift \
  "$RUN_DIR/StartupProbe.app" "$RUN_DIR/manual.trace" manual accessory
swift scripts/feasibility/startup/ObserveLaunch.swift \
  "$RUN_DIR/StartupProbe.app" "$RUN_DIR/login.trace" login regular
```

输出 `willFinish`、`didFinish`、场景出现顺序、Apple Event marker、窗口和激活状态；三秒观察后退出该探针。trace 路径必须是新文件。`baseline` 表示不在回调中切换 activation policy，不是旧版本产品的完整回归。

### 验证真实注册及注销

此步骤**会短暂注册独立测试身份**，随后显式注销；不注册主候选或当前运行的产品身份。初始已经启用或等待允许时探针报错，不替用户撤销既有选择。不要并发运行同一身份。

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

`SMAppService.Status` 的值为 `0 = notRegistered`、`1 = enabled`、`2 = requiresApproval`、`3 = notFound`。`open -W` 不可靠传播子应用的失败退出码，所以必须检查 JSON；`2` 只能称为等待允许，不能称为已正常启用。最终 `after != 0` 或出现错误时，清理未通过，不能忽略。

产物保留在 `RUN_DIR`，不自动删除证据。当前完成情况、失败记录及未实测边界见[登录与菜单栏检查点](../../../docs/login-menubar-checkpoint.md)。

# 原生应用菜单回归

验证隐藏 Dock 偏好下的真实应用：后台登录不弹窗，打开管理窗口后进入 `.regular`，
原生菜单实际归属该进程且有非零显示尺寸；最小化、隐藏、打开设置／转码／帮助、
逐个关闭窗口及重新打开均经过真实 AppKit / Accessibility 操作。
关闭最后一个管理窗口应恢复 `.accessory`，隔离素材库的文件内容必须保持不变。
传入 `--show-dock` 可用独立证据目录验证显示 Dock 偏好，此时关闭全部窗口后仍为 `.regular`。
传入 `--cold-start` 验证手动冷启动；默认验证后台登录后重开。两种启动路径和两种偏好均需覆盖。

需要本机图形会话、Swift 工具链及终端已有的辅助功能权限。与 GUI XCTest 串行运行。
不需要屏幕录制权限，不修改正式应用、用户素材库、登录项或系统壁纸。

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

探针以 `CFFIXED_USER_HOME` 指向全新素材库，仅对独立验证身份操作；其进程使用英文菜单。
原生菜单存在于 AX 树并不足以通过，必须同时拥有系统菜单栏且菜单项目有可见尺寸。
所有就绪等待限时 10 秒，错误记录在各轮目录的 `menus.json`，失败返回非零；不伪造点击或跳过断言。

## 激活时序回归

已激活的 `.accessory` 应用切为 `.regular` 后，可能仍不拥有系统菜单栏。
产品只在这次模式切换需要交接时，把激活交给系统 Dock，等真实失活事件处理完成后重新激活。
用户切换到其他应用、隐藏、关闭全部管理窗口或退出会取消当前交接；没有固定延时或自动重试。
Dock 不可用、拒绝请求或 5 秒内未取得菜单归属时，错误通过现有运行模式提示显示；再次手动打开可以重试。
单元测试覆盖事件顺序、重复请求合并、取消、拒绝、超时和手动重试：

```sh
python3 scripts/test.py --filter 'NativeMenuActivationTests|ApplicationMenuLifecycleTests|ApplicationPresentationTests'
```

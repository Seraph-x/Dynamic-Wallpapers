# 安装 Dynamic Wallpaper 1.0.0

Apple Silicon（arm64）· macOS 14.0 或更新版本 · 构建 4

1. 从官方 GitHub Release 下载 `DynamicWallpaper-1.0.0-arm64.dmg` 和 `SHA256SUMS.txt`。
2. 运行 `shasum -a 256 DynamicWallpaper-1.0.0-arm64.dmg`，将结果与 `SHA256SUMS.txt` 对应行比较。
3. 打开 DMG，将 **Dynamic Wallpaper.app** 拖入 **Applications（应用程序）**，弹出 DMG 后启动已安装的应用。使用 ZIP 时先解压，再将应用移入 Applications。
4. 应用使用临时签名，未通过 Apple 公证。若 macOS 拦截启动，先核验下载，再在“系统设置 → 隐私与安全性”中对该应用选择“仍要打开”。

替换旧版前先正常退出。已导入素材与应用程序分开保存。如果需要降级，请在首次启动 1.0.0 前另行复制 `~/Library/Application Support/DynamicWallpaper`；1.0.0 保存素材库格式 4，旧版可能拒绝读取更新后的配置。“备份并清空素材库”也会清空当前素材库，不是仅备份的升级操作。

通过“导入壁纸 → 媒体文件／网页项目／场景项目”导入自己的内容，选择显示器后应用。场景目录需包含 `project.json`、JSON/PKG 入口和资源；请仅导入可信工程。场景暂停后从原位置恢复，网页暂停后继续时则会重新加载。

在应用中打开“帮助文档”可离线阅读。场景兼容性取决于效果和脚本；暂不支持系统音频频谱采集、场景编辑和场景屏保播放。第三方源码与许可材料的现有限制保留在应用的 ThirdParty 目录及发布说明中。

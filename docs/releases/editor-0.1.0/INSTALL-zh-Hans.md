# Dynamic Wallpaper Editor 0.1.0 — 简体中文

Apple Silicon (arm64) · macOS 14.0+ · Build 1

单独下载 Editor ZIP，并对照附带的 `SHA256SUMS.txt` 文件核验 SHA-256。解压后将
**Dynamic Wallpaper Editor.app** 拖入“应用程序”。此发布包使用临时签名，
尚未公证；macOS 可能要求在“系统设置 → 隐私与安全性”中批准可信下载。
壁纸应用不会自动安装 Editor。菜单栏 **Editor** 在已安装时直接打开；未安装时
仅询问“下载 Editor”或“取消”。下载按钮打开官方发布页，安装仍需用户手动完成。

通过“文件 → 在 Dynamic Wallpaper 中打开”将已保存场景导入壁纸库，再自行应用。
两个应用可以独立退出。卸载时退出 Editor，只移除 `.app`；已保存工程保留在
`~/Library/Application Support/DynamicWallpaperEditor/Projects/`。卸载不影响正常
壁纸播放，两个应用均可独立运行。

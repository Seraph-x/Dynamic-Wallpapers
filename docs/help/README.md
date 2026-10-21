# 用户帮助文档维护

文档对应 **v0.3.0 / build 3**，面向安装应用后的最终用户。

## 阅读入口

| 语言 | Markdown 正文 |
| --- | --- |
| 简体中文 | [zh-Hans.md](zh-Hans.md) |
| English | [en.md](en.md) |
| 日本語 | [ja.md](ja.md) |
| Français | [fr.md](fr.md) |
| Español | [es.md](es.md) |

应用的“帮助 → 帮助文档”和菜单栏图标中的“帮助文档”共用一个离线帮助窗口。每次从应用打开时，默认采用当前应用界面语言。文档顶部的语言链接只切换阅读语言，保留当前章节，不修改应用设置；再次从应用打开时，重新采用应用语言。

## 文件与生成方式

| 文件 | 用途 |
| --- | --- |
| `docs/help/{zh-Hans,en,ja,fr,es}.md` | 五语正文，内容修改入口 |
| `docs/help/languages.json` | 语言导航及可访问性标签 |
| `docs/help/help.css`、`docs/help/help.js` | 离线样式、语言切换与章节保留 |
| `scripts/build-help.py` | 将 Markdown 生成 HTML；`--check` 只验证，不写文件 |
| `Sources/WallpaperApp/Help/` | 随应用打包的生成产物，不直接编辑 |

以下命令均从项目根目录运行。Markdown 依赖仅用于生成文档，应用阅读帮助不需要 Python，也不需要联网。

```sh
python3 -m venv .build/help-venv
.build/help-venv/bin/python -m pip install -r scripts/help-requirements.txt
.build/help-venv/bin/python scripts/build-help.py
.build/help-venv/bin/python scripts/build-help.py --check
```

修改正文、样式或导航脚本后，需重新生成，并将源文件与生成产物一并保留。

## 内容约定

- 五语保持相同的章节 ID，例如 `{#settings}`，以便切换语言后定位同一章节。
- 使用当前界面的实际名称、默认值和操作路径；先核对源码与对应的 `Localizable.strings`，再更新翻译。
- 优先回答用户任务：如何导入与应用、预览与正式应用的区别、多屏／列表／屏保的入口、数据和删除的后果、可执行的排障步骤。设置与格式只保留用户判断所需的信息。
- 不写不影响用户操作的开发架构、配置格式版本、内部目录名、未公开的版本沿革、计划功能、发布安排或未经定义的硬件数值；不要把会过时的迭代日期当作使用说明。
- 插图只用于解释真实界面操作，并需与当前正式应用核对。个人素材可以出现在画面中；个人绝对路径、用户名、账户信息及其他敏感信息不得进入截图或图注。无法安全核验时不使用截图，也不留占位。
- 页面链接、样式和脚本使用离线相对路径。

## 验证

```sh
.build/help-venv/bin/python scripts/build-help.py --check
python3 scripts/test-help.py
python3 scripts/test-app-packaging.py
python3 scripts/test.py --filter 'HelpDocumentTests|HelpWindowTests|LocalizationResourceTests|InterfaceSettingsTests'
git diff --check
```

帮助窗口测试使用真实 `WKWebView`，需要已登录的 macOS 图形会话；定向 Swift 测试默认预算为 60 秒，包含构建时间。测试覆盖五语渲染、离线资源、语言与章节切换、重新打开时的语言选择，以及缺失文档和非法语言请求的错误提示。

`Package.swift` 使用 `.copy("Help")` 保留目录结构。打包前及候选校验会核对五语页面、导航、章节和离线资源。发行应用仅从自身资源包读取帮助；资源缺失时明确报错，不换成其他语言，也不读取开发目录。

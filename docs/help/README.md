# User Help Documentation Maintenance

The documentation corresponds to **v1.1.0 / build 5** and targets end users after the app is installed.

## Reading Entry Points

| Language | Markdown source |
| --- | --- |
| 简体中文 | [zh-Hans.md](zh-Hans.md) |
| English | [en.md](en.md) |
| 日本語 | [ja.md](ja.md) |
| Français | [fr.md](fr.md) |
| Español | [es.md](es.md) |

The app's “Help → Help Documentation” menu item and the “Help Documentation” item in the menu bar icon share one offline help window. Each time it is opened from the app, the current app interface language is used by default. The language links at the top of the document only switch the reading language; they keep the current section and do not modify app settings. Opening it from the app again re-adopts the app language.

## Files and Generation

| File | Purpose |
| --- | --- |
| `docs/help/{zh-Hans,en,ja,fr,es}.md` | Five-language bodies; the entry point for content edits |
| `docs/help/languages.json` | Language navigation and accessibility labels |
| `docs/help/help.css`, `docs/help/help.js` | Offline styles, language switching, and section retention |
| `scripts/build-help.py` | Generates HTML from Markdown; `--check` only validates and writes no files |
| `Sources/WallpaperApp/Help/` | Generated artifacts bundled with the app; do not edit directly |

All commands below run from the project root. The Markdown dependencies are only needed to generate the documentation; reading help inside the app requires neither Python nor network access.

```sh
python3 -m venv .build/help-venv
.build/help-venv/bin/python -m pip install -r scripts/help-requirements.txt
.build/help-venv/bin/python scripts/build-help.py
.build/help-venv/bin/python scripts/build-help.py --check
```

After changing the body text, styles, or the navigation script, regenerate, and keep both the sources and the generated artifacts.

## Content Conventions

- All five languages keep the same section IDs, for example `{#settings}`, so that switching language lands on the same section.
- Use the actual names, default values, and interaction paths of the current interface; check the source code and the corresponding `Localizable.strings` before updating a translation.
- Answer user tasks first: how to import and apply, the difference between preview and actually applying, the entry points for multiple displays / lists / screen saver, the consequences of data and deletion, and actionable troubleshooting steps. For settings and formats, keep only the information users need in order to decide.
- Do not describe development architecture, configuration format versions, internal directory names, unreleased version history, planned features, release schedules, or undefined hardware numbers that do not affect what users do; do not present iteration dates that will go stale as usage instructions.
- Illustrations are only used to explain real interface actions and must be checked against the current release app. Personal assets may appear in the image; personal absolute paths, user names, account information, and other sensitive information must not appear in screenshots or captions. When it cannot be verified safely, do not use a screenshot and do not leave a placeholder.
- Page links, styles, and scripts use offline relative paths.

## Verification

```sh
.build/help-venv/bin/python scripts/build-help.py --check
python3 scripts/test-help.py
python3 scripts/test-app-packaging.py
python3 scripts/test.py --filter 'HelpDocumentTests|HelpWindowTests|LocalizationResourceTests|InterfaceSettingsTests'
git diff --check
```

The help window tests use a real `WKWebView` and require a logged-in macOS graphical session; the targeted Swift test has a default budget of 60 seconds including build time. The tests cover five-language rendering, offline resources, language and section switching, language selection when the window is reopened, and the error messages for missing documents and invalid language requests.

`Package.swift` uses `.copy("Help")` to preserve the directory structure. Pre-packaging and candidate validation check the five-language pages, navigation, sections, and offline resources. The release app reads help only from its own resource bundle; when resources are missing it reports an explicit error instead of falling back to another language or reading the development directory.

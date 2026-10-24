import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WallpaperCore

enum WebImportSelection {
    static func relativeEntry(root: URL, selected: URL) throws -> String {
        let base = root.standardizedFileURL.pathComponents
        let path = selected.standardizedFileURL.pathComponents
        guard root.isFileURL, selected.isFileURL, path.count > base.count, path.starts(with: base) else {
            throw WallpaperError("请选择项目目录内的 HTML 文件。")
        }
        let entry = path.dropFirst(base.count).joined(separator: "/")
        try WebProjectReference(root: root, entry: entry).validate()
        return entry
    }
}

struct WallpaperImportView: View {
    @Localized private var l10n
    enum Kind: String, CaseIterable { case media = "媒体文件", web = "网页项目", scene = "场景项目" }
    @ObservedObject var model: AppModel
    let purpose: ImportPurpose
    @Environment(\.dismiss) private var dismiss
    @State private var kind: Kind
    @State private var root: URL?
    @State private var entry: String
    @State private var failure: PresentedFailure?
    @State private var inspectingScene = false
    @State private var importTask: Task<Void, Never>?

    init(model: AppModel, purpose: ImportPurpose = .wallpaper,
         projectRoot: URL? = nil, entry: String = "index.html") {
        self.model = model
        self.purpose = purpose
        _kind = State(initialValue: projectRoot == nil ? .media : .web)
        _root = State(initialValue: projectRoot)
        _entry = State(initialValue: entry)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(purpose == .screenSaver ? l10n("导入屏保素材") : l10n("导入壁纸"))
                .font(.title2.weight(.semibold))
            if purpose == .wallpaper {
                Picker(l10n("壁纸来源"), selection: $kind) {
                    ForEach(Kind.allCases, id: \.self) { Text(l10n.text($0.rawValue)).tag($0) }
                }.pickerStyle(.segmented).disabled(inspectingScene || model.importing)
            }
            if kind == .media {
                Label(l10n("视频、动图与图片"), systemImage: "photo.on.rectangle.angled").font(.headline)
                Text(l10n("可一次导入多个文件，应用会保存独立副本，原文件保持不变。"))
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text(l10n("支持的格式")).font(.caption).foregroundStyle(.secondary)
                    HelpPopover(title: l10n("支持的格式"), message: WallpaperCopy.supportedFormats)
                }
            } else {
                Text(l10n(kind == .scene ? "选择包含 project.json 与场景资源的目录；整个项目将复制到应用目录。" : "选择包含网页与资源的项目目录，再指定 HTML 入口；整个项目将复制到应用目录。"))
                    .foregroundStyle(.secondary)
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(l10n("项目目录")).font(.caption).foregroundStyle(.secondary)
                        Text(root?.path ?? l10n("尚未选择")).lineLimit(2).textSelection(.enabled)
                    }
                    Spacer()
                    Button(root == nil ? l10n("选择目录…") : l10n("更换目录…"), action: chooseRoot)
                        .disabled(inspectingScene || model.importing)
                        .tint(AppColors.secondaryActionText)
                }
                if kind == .web {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text(l10n("入口文件（HTML）")).font(.caption).foregroundStyle(.secondary)
                            HelpPopover(title: l10n("入口文件"), message: l10n("选择项目内要打开的 HTML 文件，默认为 index.html；手动填写时使用相对于项目目录的路径，例如 pages/index.html。"))
                        }
                        HStack {
                            TextField(l10n("相对于项目目录的路径"), text: $entry).textFieldStyle(.roundedBorder)
                                .disabled(inspectingScene || model.importing)
                                .accessibilityLabel(l10n("入口文件（HTML）"))
                                .accessibilityIdentifier("web-import-entry")
                            Button(l10n("选择入口文件…"), action: chooseEntry).disabled(root == nil || inspectingScene || model.importing)
                                .tint(AppColors.secondaryActionText)
                        }
                    }
                }
                if kind == .scene {
                    Text(l10n("支持本地 loose JSON 和 PKG 场景，按作者默认设置播放。系统音频频谱与场景编辑器暂不支持。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let failure { FailureNotice(failure: failure) }
            Divider()
            HStack {
                Text(purpose == .screenSaver ? l10n("添加到素材库；导入后确认屏保内容")
                    : (model.selectedPlaylist.map { l10n("同时加入“\($0.name)”") } ?? l10n("添加到素材库")))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(l10n("取消")) { importTask?.cancel(); model.cancelImport(); dismiss() }.keyboardShortcut(.cancelAction)
                    .tint(AppColors.secondaryActionText)
                if kind == .media {
                    Button(l10n("选择文件…"), action: chooseMedia).keyboardShortcut(.defaultAction)
                        .disabled(inspectingScene || model.importing)
                        .appGlassOutlinedButtonStyle()
                } else {
                    Button(l10n(kind == .scene ? "导入场景项目" : "导入网页项目"), action: importProject).keyboardShortcut(.defaultAction)
                        .appGlassOutlinedButtonStyle()
                        .disabled(root == nil || (kind == .web && entry.isEmpty) || inspectingScene || model.isShuttingDown || model.importing || model.loadFailed)
                }
            }
        }.padding(24).frame(width: 520)
            .appGlassPresentation(appearance: model.library.settings.appearance)
            .onChange(of: kind) { _, _ in failure = nil }
            .onDisappear { importTask?.cancel() }
    }

    private func chooseMedia() {
        let panel = NSOpenPanel()
        panel.title = purpose == .screenSaver ? l10n("选择屏保素材") : l10n("选择壁纸文件")
        panel.prompt = l10n("导入")
        panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.allowedContentTypes = MediaProbe.fileExtensions.compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK else { return }
        model.importURLs(panel.urls, purpose: purpose)
        dismiss()
    }

    private func chooseRoot() {
        let panel = NSOpenPanel()
        panel.title = l10n(kind == .scene ? "选择场景项目目录" : "选择网页项目目录"); panel.prompt = l10n("选择目录")
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.directoryURL = root
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        root = selected.standardizedFileURL; entry = "index.html"; failure = nil
    }

    private func chooseEntry() {
        guard let root else { return }
        let panel = NSOpenPanel()
        panel.title = l10n("选择项目内的 HTML 文件"); panel.prompt = l10n("选择文件")
        panel.allowedContentTypes = [.html]
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.directoryURL = root; panel.nameFieldStringValue = entry
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        do { entry = try WebImportSelection.relativeEntry(root: root, selected: selected); failure = nil }
        catch { failure = PresentedFailure(error, context: .importing) }
    }

    private func importProject() {
        guard let root else { return }
        importTask = Task { @MainActor in
            defer { inspectingScene = false }
            let imported: Bool
            if kind == .scene {
                do {
                    inspectingScene = true
                    let probe = Task.detached { try SceneProjectProbe.inspect(root: root) }
                    let item = try await withTaskCancellationHandler {
                        try await probe.value
                    } onCancel: { probe.cancel() }
                    try Task.checkCancellation()
                    guard let reference = item.sceneProject else { throw WallpaperError("场景项目引用缺失。") }
                    imported = await model.importSceneProject(reference)
                } catch is CancellationError { return }
                catch {
                    failure = PresentedFailure(error, context: .importing)
                    return
                }
            } else {
                imported = await model.importWebProject(WebProjectReference(root: root, entry: entry))
            }
            guard !Task.isCancelled else { return }
            if imported { dismiss() }
            else {
                failure = model.failure
                model.failure = nil // The active importer owns this visible error.
            }
        }
    }
}

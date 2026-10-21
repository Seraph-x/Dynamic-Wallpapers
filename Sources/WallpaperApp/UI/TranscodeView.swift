import AppKit
import SwiftUI
import WallpaperCore

struct TranscodeView: View {
    @Localized private var l10n
    @ObservedObject private var model: AppModel
    @ObservedObject private var transcoding: TranscodeModel
    @State private var directory: URL?
    @State private var name = ""

    init(model: AppModel) {
        self.model = model
        self.transcoding = model.transcoding
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(l10n("视频转码")).font(.title2.weight(.semibold))
                Text(l10n("生成新的 H.264 MP4 文件，不覆盖原文件或已有文件。"))
                    .font(.callout).foregroundStyle(.secondary)
                if let source = transcoding.source {
                    sourceForm(source)
                } else {
                    Text(l10n("尚未选择视频")).font(.headline)
                    Text(l10n("在需要转码的视频详情中点击“转码…”。")).foregroundStyle(.secondary)
                }
                if let failure = transcoding.failure { FailureNotice(failure: failure) }
                if let failure = model.failure { FailureNotice(failure: failure) }
                Divider()
                TranscodeQueueView(queue: transcoding.queue,
                    imported: importedURLs,
                    importDisabled: model.importing || model.loadFailed || model.isShuttingDown,
                    onImport: model.importTranscodedOutput)
            }.padding(24)
        }
        .appGlassBackground(.window, appearance: model.library.settings.appearance,
                            captureWallpaper: model.captureWallpaper, makeWallpaperMirror: model.makeWallpaperMirror)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .onChange(of: transcoding.source?.id, initial: true) { _, _ in
            guard let source = transcoding.source else { return }
            directory = (source.origin?.url ?? source.url).deletingLastPathComponent()
            name = source.url.deletingPathExtension().lastPathComponent + "-h264.mp4"
        }
    }

    private var importedURLs: Set<URL> {
        Set(model.library.media.flatMap { item in
            [item.url, item.origin?.url].compactMap { $0?.standardizedFileURL }
        })
    }

    @ViewBuilder
    private func sourceForm(_ source: MediaItem) -> some View {
        Text(source.url.path).font(.callout).textSelection(.enabled)
        if transcoding.isProbing {
            ProgressView(l10n("正在检查原文件…"))
        }
        Picker(l10n("预设"), selection: $transcoding.preset) {
            ForEach(TranscodePreset.allCases) { Text(l10n.text($0.title)).tag($0) }
        }.pickerStyle(.segmented)
        if let plan = transcoding.plan {
            switch plan {
            case .success(let plan):
                HStack(spacing: 6) {
                    Text(l10n("输出尺寸：\(plan.width) × \(plan.height) · H.264")).font(.callout).textSelection(.enabled)
                    HelpPopover(title: l10n("转码参数"), message: plan.preset == .original
                        ? l10n("使用 VideoToolbox 硬件编码并保留输入时间戳，奇数尺寸补边；不会改用软件编码。")
                        : l10n("使用 VideoToolbox 硬件编码，按输入时间基精度限至约 30 fps，仅丢帧、不补帧；不会改用软件编码。"))
                }
                Text(plan.preset == .original
                     ? l10n("重新编码，并非无损复制；奇数尺寸会补为偶数。")
                     : l10n("保持比例缩小、不放大，帧率最高约 30 fps。"))
                    .font(.caption).foregroundStyle(.secondary)
                Text(l10n("仅保留第一条视频轨道（不含封面），不保留字幕或章节。"))
                    .font(.caption).foregroundStyle(.secondary)
                Text(plan.media.audioIndex == nil ? l10n("原视频无音轨，输出为无声视频。")
                     : l10n("仅保留第一条音轨并转为 AAC，输出声音不受应用内静音和音量设置影响。"))
                    .font(.caption).foregroundStyle(.secondary)
            case .failure(let error):
                FailureNotice(failure: PresentedFailure(error, context: .transcode))
            }
        }
        HStack(alignment: .top) {
            Button(l10n("选择输出目录…"), action: chooseDirectory)
                .tint(AppColors.secondaryActionText)
            Text(directory?.path ?? l10n("尚未选择")).font(.caption).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        TextField(l10n("新文件名（.mp4）"), text: $name).textFieldStyle(.roundedBorder)
        Button(l10n("加入转码队列"), systemImage: "arrow.triangle.2.circlepath") {
            if let directory {
                transcoding.enqueue(directory: directory, name: name, managedMediaDirectory: model.managedImport.files.directory)
            }
        }
        .appGlassOutlinedButtonStyle()
        .disabled(directory == nil || transcoding.media == nil || transcoding.isProbing || transcoding.isShuttingDown)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.title = l10n("选择转码输出目录"); panel.prompt = l10n("选择目录")
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
        panel.directoryURL = directory
        if panel.runModal() == .OK { directory = panel.url }
    }
}

private struct TranscodeQueueView: View {
    @Localized private var l10n
    @ObservedObject var queue: TranscodeQueue
    let imported: Set<URL>
    let importDisabled: Bool
    let onImport: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 6) {
                Text(l10n("转码任务")).font(.headline)
                HelpPopover(title: l10n("转码队列"), message: l10n("任务按顺序逐个执行。"))
            }
            Text(l10n("关闭窗口后任务仍会继续。")).font(.caption).foregroundStyle(.secondary)
            if queue.jobs.isEmpty { Text(l10n("还没有转码任务")).foregroundStyle(.secondary) }
            ForEach(queue.jobs) { job in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(job.request.destination.lastPathComponent).font(.headline)
                        Spacer()
                        Text(l10n.text(job.state.title)).font(.caption)
                    }
                    Text("\(l10n.text(job.request.plan.preset.title)) · \(job.request.plan.width) × \(job.request.plan.height)")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(job.request.destination.path).font(.caption).textSelection(.enabled)
                    if job.state.isActive {
                        ProgressView(value: job.progress)
                        Button(job.state == .cancelling ? l10n("正在取消…") : l10n("取消")) { queue.cancel(job.id) }
                            .disabled(job.state == .cancelling).tint(AppColors.secondaryActionText)
                    }
                    if case .failed(let failure) = job.state { FailureNotice(failure: failure) }
                    if job.state == .succeeded, let output = job.output {
                        let alreadyImported = imported.contains(output.standardizedFileURL)
                        HStack {
                            Button(alreadyImported ? l10n("已在素材库") : l10n("导入到素材库")) { onImport(output) }
                                .disabled(alreadyImported || importDisabled)
                            Button(l10n("在 Finder 中显示")) { NSWorkspace.shared.activateFileViewerSelecting([output]) }
                        }.tint(AppColors.secondaryActionText)
                        Text(l10n("导入后不会替换原播放列表中的壁纸。")).font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(14).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

}

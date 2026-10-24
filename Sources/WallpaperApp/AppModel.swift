import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import ScreenSaverCore
import WallpaperCore

enum SidebarSection: Hashable { case library, favorites, playlist(UUID), displays, screenSaver }
enum ImportPurpose: Equatable { case wallpaper, screenSaver }

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var library: Library {
        didSet {
            mirrorFrameRate.value = library.settings.appearance.fullScreenFrameRate
            webRuntime.setFrameRate(library.settings.webWallpaperFrameRate)
            webRuntime.systemAudioSpectrum.setEnabled(!loadFailed && library.settings.systemAudioSpectrumEnabled)
        }
    }
    @Published var section: SidebarSection? = .library {
        didSet {
            guard section != oldValue else { return }
            batchSelection.finish()
            selectedEntryID = nil
            selectedMediaID = nil
        }
    }
    @Published var batchSelection = BatchSelection()
    @Published var selectedMediaID: UUID?
    @Published var selectedEntryID: UUID? {
        didSet {
            guard selectedEntryID != oldValue, let playlist = selectedPlaylist else { return }
            selectedMediaID = playlist.entries.first { $0.id == selectedEntryID }?.mediaID
        }
    }
    @Published var search = "" { didSet { if search != oldValue { batchSelection.clear() } } }
    @Published var failure: PresentedFailure?
    @Published private(set) var appearanceFailure: PresentedFailure?
    @Published private(set) var languageFailure: PresentedFailure?
    @Published private(set) var systemWallpaperFailure: PresentedFailure?
    @Published private(set) var systemLanguages = Locale.preferredLanguages
    @Published private(set) var presentationFailure: PresentedFailure?
    var errorMessage: String? {
        get { failure?.localizedDescription }
        set { failure = newValue.map { PresentedFailure(WallpaperError($0)) } }
    }
    @Published private(set) var lastLibraryBackup: URL?
    @Published private(set) var loadFailed = false
    @Published private(set) var importing = false
    @Published var showingImport = false
    @Published private(set) var importPurpose: ImportPurpose = .wallpaper
    @Published private(set) var screenSaverImportChoices: [UUID] = []
    @Published private(set) var displays: [DisplayInfo] = []
    @Published private(set) var statuses: [UUID: String] = [:]
    @Published private(set) var pauseReasons = Set<String>()
    @Published private(set) var userPaused = false
    @Published private(set) var isShuttingDown = false
    @Published private(set) var webInteractionStatus = WebInteractionStatus("网页交互已关闭")
    @Published private(set) var webInteractionFailure: PresentedFailure?
    let store: LibraryStore
    let paths: ApplicationPaths
    let managedImport: ManagedMediaImport
    let thumbnails: ThumbnailLifetime
    private let mediaRemoval: ManagedMediaRemoval
    let previewLifetime: PreviewLifetime
    let inspectorMedia: InspectorMediaModel
    let transcoding: TranscodeModel
    let systemWallpaperSync: SystemWallpaperSync
    let screenSaver: ScreenSaverModel?
    private let desktop: DesktopCoordinator
    private let mirrorFrameRate: CurrentValueSubject<WallpaperMirrorFrameRate, Never>
    let webRuntime: CEFApplicationRuntime
    let loginItems: LoginItemController
    private(set) lazy var mainWindow = MainWindowCoordinator { [weak self] in self?.activateManagementInterface() }
    private let presentation: any ApplicationPresenting
    private var hasOpenManagementWindows = false
    private let webInteractionController: WebInteractionController
    private let lifecycle: ApplicationLifecycleController
    private var importTask: Task<Bool, Never>?

    init(paths suppliedPaths: ApplicationPaths? = nil,
         store suppliedStore: LibraryStore? = nil, transcoding suppliedTranscoding: TranscodeModel? = nil,
         inspectorMedia suppliedInspectorMedia: InspectorMediaModel? = nil,
         managedImport suppliedManagedImport: ManagedMediaImport? = nil,
         thumbnails suppliedThumbnails: ThumbnailLifetime? = nil,
         presentation suppliedPresentation: (any ApplicationPresenting)? = nil,
         loginItems suppliedLoginItems: LoginItemController? = nil,
         webInteractionPermissions suppliedPermissions: (any WebInteractionPermissionServicing)? = nil,
         screenSaver suppliedScreenSaver: ScreenSaverModel? = nil,
         fullScreenMonitor suppliedFullScreenMonitor: OtherAppFullScreenMonitor? = nil,
         setSystemDesktopImage: @escaping @MainActor (URL, String) throws -> Void = { url, displayID in
             try SystemDesktopImageService().setImage(at: url, displayID: displayID)
         }) {
        let overrides = AppCompositionOverrides(paths: suppliedPaths, store: suppliedStore, transcoding: suppliedTranscoding,
            inspectorMedia: suppliedInspectorMedia, managedImport: suppliedManagedImport,
            thumbnails: suppliedThumbnails, presentation: suppliedPresentation,
            loginItems: suppliedLoginItems, webInteractionPermissions: suppliedPermissions,
            screenSaver: suppliedScreenSaver, fullScreenMonitor: suppliedFullScreenMonitor)
        let environment = AppCompositionRoot.make(overrides: overrides,
            setSystemDesktopImage: setSystemDesktopImage)
        paths = environment.paths
        presentation = environment.presentation
        loginItems = environment.loginItems
        webRuntime = environment.webRuntime
        thumbnails = environment.thumbnails
        inspectorMedia = environment.inspectorMedia
        mirrorFrameRate = environment.mirrorFrameRate
        desktop = environment.desktop
        webInteractionController = environment.webInteractionController
        lifecycle = environment.lifecycle
        previewLifetime = environment.previewLifetime
        transcoding = environment.transcoding
        store = environment.store
        screenSaver = environment.screenSaver
        managedImport = environment.managedImport
        mediaRemoval = environment.mediaRemoval
        systemWallpaperSync = environment.systemWallpaperSync
        if let error = environment.screenSaverConstructionFailure { failure = PresentedFailure(error) }
        let wallpaperSource = desktop.systemWallpaperSource
        do { library = try store.load() }
        catch { library = .empty; loadFailed = true; failure = PresentedFailure(error, context: .library) }
        webRuntime.setFrameRate(library.settings.webWallpaperFrameRate)
        webRuntime.systemAudioSpectrum.setEnabled(!loadFailed && library.settings.systemAudioSpectrumEnabled)
        screenSaver?.attach(library: library, loaded: !loadFailed)
        mirrorFrameRate.value = library.settings.appearance.fullScreenFrameRate
        wallpaperSource.onChange = { [weak sync = systemWallpaperSync] in sync?.updateTargets($0) }
        systemWallpaperSync.setEnabled(!loadFailed && library.settings.systemWallpaperSyncEnabled)
        desktop.onError = { [weak self] in self?.report($0, context: .playback) }
        thumbnails.onReleaseError = { [weak self] in self?.report($0, context: .inspection) }
        inspectorMedia.onReleaseError = { [weak self] in self?.report($0, context: .inspection) }
        desktop.onStatus = { [weak self] group, status in self?.statuses[group] = status }
        desktop.onWebInteractionStatus = { [weak self] status in self?.webInteractionStatus = status }
        webInteractionController.onPoll = { [weak self] in self?.refreshWebInteractionStatus() }
        desktop.onCommit = { [weak self] group, entry in self?.recordCommit(group: group, entry: entry) }
        lifecycle.onPauseReasons = { [weak self] reasons in
            guard let self, reasons != self.pauseReasons else { return }
            self.pauseReasons = reasons
            self.updatePause()
        }
        lifecycle.onScreensChanged = { [weak self] displays in
            guard let self else { return }
            self.displays = displays
            if !self.loadFailed { self.desktop.reconcile(self.library) }
        }
        lifecycle.onError = { [weak self] error in
            guard let self else { return }
            self.report(error, context: self.isShuttingDown ? .shutdown : .playback)
        }
        lifecycle.update(settings: library.settings)
        lifecycle.refreshScreens()
        restoreWebInteraction()
        if !loadFailed { scheduleMediaRemoval(library.pendingMediaDeletions, releasing: nil) }
        if suppliedScreenSaver == nil { screenSaver?.start() }
    }

    var inspectorSelection: InspectorSelection? { InspectorSelection(model: self) }
    var selectedMedia: MediaItem? { inspectorSelection?.item }
    var selectedPlaylist: Playlist? {
        guard case let .playlist(id) = section else { return nil }
        return library.playlists.first { $0.id == id }
    }
    var selectedEntryAudio: AudioSettings {
        inspectorSelection?.audio ?? AudioSettings()
    }
    var isPaused: Bool { userPaused || !pauseReasons.isEmpty }
    var desktopIdentity: [String: ObjectIdentifier] { desktop.windowIdentities }
    var localizer: AppLocalizer {
        AppLocalizer(language: library.settings.language, preferredLanguages: systemLanguages)
    }

    func refreshSystemLanguages() {
        let languages = Locale.preferredLanguages
        if systemLanguages != languages { systemLanguages = languages }
    }
    func captureWallpaper(on screen: NSScreen) async throws -> CGImage {
        try await desktop.captureWallpaper(on: screen)
    }
    func makeWallpaperMirror(on screen: NSScreen) throws -> WallpaperMirrorSession {
        try desktop.makeWallpaperMirror(on: screen)
    }

    var playbackSummary: String {
        if isPaused { return "已暂停 · " + (userPaused ? "手动暂停" : pauseReasons.sorted().joined(separator: "、")) }
        if library.displays.isEmpty { return "尚未应用壁纸" }
        return statuses.values.sorted().first ?? "正在准备壁纸…"
    }

    @discardableResult
    func mutate(_ change: (inout Library) throws -> Void) -> Bool {
        guard !isShuttingDown else { report(WallpaperError("应用正在退出，无法修改素材库。"), context: .save); return false }
        guard !loadFailed else { report(WallpaperError("素材库无法读取，编辑已停用。"), context: .save); return false }
        do {
            let coordinator = LibraryCommitCoordinator(save: store.save,
                validateRemoval: transcoding.validateRemoval,
                withCommitLock: { operation in
                    if let screenSaver = self.screenSaver { try screenSaver.withLibraryCommitLock(operation) }
                    else { try operation() }
                })
            let result = try coordinator.commit(current: library, change: change,
                beginRelease: beginReleasingMedia,
                publish: { self.library = $0 },
                screenSaverDidCommit: { committed, previous in
                    self.screenSaver?.libraryDidCommit(committed, previous: previous)
                })
            let removed = result.removed
            if !removed.isEmpty {
                scheduleMediaRemoval(removed.filter { $0.origin != nil }, releasing: result.releasing)
            }
            statuses = statuses.filter { key, _ in result.library.displays.contains { $0.groupID == key } }
            batchSelection.retain(visibleBatchIDs)
            if let id = selectedMediaID, !library.media.contains(where: { $0.id == id }) { selectedMediaID = nil }
            if let id = selectedEntryID, selectedPlaylist?.entries.contains(where: { $0.id == id }) != true { selectedEntryID = nil }
            desktop.reconcile(library)
            lifecycle.update(settings: library.settings)
            return true
        } catch { report(error, context: .save); return false }
    }

    @discardableResult
    func setAppearance(_ appearance: AppAppearanceSettings) -> Bool {
        do {
            guard !isShuttingDown else { throw WallpaperError("应用正在退出，无法修改外观。") }
            guard !loadFailed else { throw WallpaperError("素材库无法读取，外观编辑已停用。") }
            guard appearance != library.settings.appearance || appearanceFailure != nil else { return true }
            var candidate = library
            candidate.settings.appearance = appearance
            try store.save(candidate)
            // Appearance changes publish to every window without reconciling desktop playback.
            library = candidate
            appearanceFailure = nil
            return true
        } catch { appearanceFailure = PresentedFailure(error, context: .save); return false }
    }

    @discardableResult
    func setLanguage(_ language: AppLanguage) -> Bool {
        do {
            guard !isShuttingDown else { throw WallpaperError("应用正在退出，无法修改语言。") }
            guard !loadFailed else { throw WallpaperError("素材库无法读取，语言编辑已停用。") }
            guard language != library.settings.language || languageFailure != nil else { return true }
            var candidate = library
            candidate.settings.language = language
            try store.save(candidate)
            // Publish translated UI only after persistence succeeds; do not restart playback or previews.
            library = candidate
            languageFailure = nil
            return true
        } catch { languageFailure = PresentedFailure(error, context: .save); return false }
    }

    @discardableResult
    func setSystemWallpaperSyncEnabled(_ enabled: Bool) -> Bool {
        do {
            guard !isShuttingDown else { throw WallpaperError("应用正在退出，无法修改系统底图同步。") }
            guard !loadFailed else { throw WallpaperError("素材库无法读取，无法保存系统底图同步设置。") }
            guard enabled != library.settings.systemWallpaperSyncEnabled || systemWallpaperFailure != nil else { return true }
            var candidate = library
            candidate.settings.systemWallpaperSyncEnabled = enabled
            try store.save(candidate)
            // Persist intent before starting any system writes, without restarting playback or previews.
            library = candidate
            systemWallpaperSync.setEnabled(enabled)
            systemWallpaperFailure = nil
            return true
        } catch { systemWallpaperFailure = PresentedFailure(error, context: .save); return false }
    }

    @discardableResult
    func restoreApplicationPresentation() -> Bool {
        let policy = desiredActivationPolicy(showDockIcon: library.settings.showDockIcon)
        guard presentation.activationPolicy == policy || presentation.setActivationPolicy(policy) else {
            presentationFailure = PresentedFailure(title: "运行模式未切换", summary: "无法更新应用菜单和 Dock 的显示状态。")
            return false
        }
        presentationFailure = nil
        return true
    }

    func finishLaunching(event: NSAppleEventDescriptor?) {
        // Managed scenes suppress automatic launch/restoration on macOS 27;
        // earlier SwiftUI versions honor the native login Apple Event themselves.
        restoreApplicationPresentation()
        if ApplicationLaunchOrigin(event: event) == .manual { mainWindow.open() }
    }

    func activateManagementInterface() {
        guard !isShuttingDown else { return }
        presentation.activate { [weak self] error in
            self?.presentationFailure = PresentedFailure(title: "运行模式未切换",
                summary: "无法更新应用菜单和 Dock 的显示状态。", diagnostics: FailureDiagnostics.describe(error))
        }
    }

    func setManagementWindowsOpen(_ hasOpenWindows: Bool) {
        guard !isShuttingDown, hasOpenWindows != hasOpenManagementWindows else { return }
        hasOpenManagementWindows = hasOpenWindows
        if !hasOpenWindows { presentation.cancelActivation() }
        let wasActive = presentation.isActive
        let previousPolicy = presentation.activationPolicy
        if restoreApplicationPresentation(), hasOpenWindows, wasActive,
           presentation.activationPolicy != previousPolicy { activateManagementInterface() }
    }

    private func desiredActivationPolicy(showDockIcon: Bool) -> NSApplication.ActivationPolicy {
        showDockIcon || hasOpenManagementWindows ? .regular : .accessory
    }

    @discardableResult
    func setShowDockIcon(_ visible: Bool) -> Bool {
        guard !isShuttingDown, !loadFailed else {
            presentationFailure = PresentedFailure(title: "运行模式未切换", summary: isShuttingDown
                ? "应用正在退出，无法修改 Dock 图标。" : "素材库无法读取，无法保存 Dock 图标设置。")
            return false
        }
        let previousPolicy = presentation.activationPolicy
        let wasActive = presentation.isActive
        let policy = desiredActivationPolicy(showDockIcon: visible)
        var changedPolicy = false
        defer { if wasActive && changedPolicy { activateManagementInterface() } }
        do {
            guard previousPolicy == policy || presentation.setActivationPolicy(policy) else {
                throw WallpaperError("系统未接受 Dock 图标切换。")
            }
            changedPolicy = previousPolicy != policy
            var candidate = library
            candidate.settings.showDockIcon = visible
            try store.save(candidate)
            // Presentation changes must not reconcile or recreate desktop playback.
            library = candidate
            presentationFailure = nil
            return true
        } catch {
            let recoveryFailed = presentation.activationPolicy != previousPolicy
                && !presentation.setActivationPolicy(previousPolicy)
            presentationFailure = PresentedFailure(title: "运行模式未切换",
                summary: recoveryFailed ? "Dock 图标设置未保存，且无法恢复原运行模式。" : "Dock 图标设置未更改。",
                diagnostics: FailureDiagnostics.describe(error)
                    + (recoveryFailed ? "\n恢复策略失败；当前策略：\(presentation.activationPolicy.rawValue)" : ""))
            return false
        }
    }

    func importFiles(purpose: ImportPurpose = .wallpaper) {
        guard canBeginImport() else { return }
        importPurpose = purpose
        showingImport = true
    }

    private func canBeginImport() -> Bool {
        let reason: String
        if isShuttingDown { reason = "应用正在退出，无法导入。" }
        else if loadFailed { reason = "素材库无法读取，暂时无法导入。" }
        else if importing { reason = "正在导入，请稍候。" }
        else { return true }
        report(WallpaperError(reason), context: .importing)
        return false
    }

    @discardableResult
    func importWebProject(_ reference: WebProjectReference) async -> Bool {
        guard let task = beginImport([.web(reference)], targetList: selectedPlaylist?.id) else { return false }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    @discardableResult
    func importSceneProject(_ reference: SceneProjectReference) async -> Bool {
        guard let task = beginImport([.scene(reference)], targetList: selectedPlaylist?.id) else { return false }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    func importTranscodedOutput(_ url: URL) { importURLs([url], addingToSelectedPlaylist: false) }

    func importURLs(_ urls: [URL], addingToSelectedPlaylist: Bool = true, purpose: ImportPurpose = .wallpaper) {
        _ = beginImport(urls.map { .file($0) },
                        targetList: purpose == .screenSaver ? nil : (addingToSelectedPlaylist ? selectedPlaylist?.id : nil),
                        purpose: purpose)
    }

    func cancelImport() { importTask?.cancel() }

    private func beginImport(_ sources: [ManagedMediaSource], targetList: UUID?,
                             purpose: ImportPurpose = .wallpaper) -> Task<Bool, Never>? {
        guard canBeginImport() else { return nil }
        importing = true
        if purpose == .screenSaver { screenSaverImportChoices = [] }
        failure = nil
        let task = Task { [weak self] in
            guard let self else { return false }
            defer { self.importing = false; self.importTask = nil }
            return await self.runManagedImport(sources, targetList: targetList, purpose: purpose)
        }
        importTask = task
        return task
    }

    @discardableResult
    func storeImported(_ items: [MediaItem], targetList: UUID?, selectFirst: Bool = true) -> Bool {
        guard mutate({ library in
            library.media.append(contentsOf: items)
            if let index = library.playlists.firstIndex(where: { $0.id == targetList }) {
                library.playlists[index].entries.append(contentsOf: items.map { PlaylistEntry(mediaID: $0.id) })
            }
        }) else { return false }
        if selectFirst, let item = items.first { selectImportedMedia(item.id, in: targetList) }
        return true
    }

    func finishScreenSaverImport(_ ids: [UUID]) {
        let candidates = Array(Set(ids)).sorted { left, right in
            guard let a = library.media.first(where: { $0.id == left }),
                  let b = library.media.first(where: { $0.id == right }) else { return left.uuidString < right.uuidString }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        section = .screenSaver
        screenSaverImportChoices = candidates
    }

    func discardScreenSaverImportChoices() { screenSaverImportChoices = [] }

    func selectImportedMedia(_ mediaID: UUID, in playlistID: UUID?) {
        if let playlist = library.playlists.first(where: { $0.id == playlistID }),
           let entry = playlist.entries.first(where: { $0.mediaID == mediaID }) {
            section = .playlist(playlist.id)
            selectedEntryID = entry.id
        } else {
            section = .library
            selectedEntryID = nil
            selectedMediaID = mediaID
        }
    }

    func addPlaylist() {
        let list = Playlist(name: localizer("新播放列表"))
        mutate { $0.playlists.append(list) }
        if library.playlists.contains(where: { $0.id == list.id }) { section = .playlist(list.id) }
    }
    func updatePlaylist(_ playlist: Playlist) {
        mutate { if let index = $0.playlists.firstIndex(where: { $0.id == playlist.id }) { $0.playlists[index] = playlist }; $0 = $0.clearingMissingCurrent() }
    }
    func updateEntryAudio(_ audio: AudioSettings, playlistID: UUID, entryID: UUID) {
        guard let listIndex = library.playlists.firstIndex(where: { $0.id == playlistID }),
              let entryIndex = library.playlists[listIndex].entries.firstIndex(where: { $0.id == entryID }) else {
            report(WallpaperError("播放列表条目已不存在，无法保存声音设置。")); return
        }
        mutate { $0.playlists[listIndex].entries[entryIndex].audio = audio }
    }
    func deletePlaylist(_ id: UUID) {
        mutate { $0.playlists.removeAll { $0.id == id }; $0.displays.removeAll { $0.playlistID == id } }
        if !library.playlists.contains(where: { $0.id == id }) { section = .library }
    }
    func add(_ mediaID: UUID, to listID: UUID) {
        mutate { if let index = $0.playlists.firstIndex(where: { $0.id == listID }) { $0.playlists[index].entries.append(PlaylistEntry(mediaID: mediaID)) } }
    }
    func favorite(_ id: UUID) { mutate { if let index = $0.media.firstIndex(where: { $0.id == id }) { $0.media[index].isFavorite.toggle() } } }
    @discardableResult
    func renameMedia(_ id: UUID, name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            report(WallpaperError("壁纸名称不能为空。"), context: .save)
            return false
        }
        guard let item = library.media.first(where: { $0.id == id }) else {
            report(WallpaperError("壁纸已不存在，无法重命名。"), context: .save)
            return false
        }
        guard item.name != trimmed || item.customName != nil else { return true }
        return mutate {
            guard let index = $0.media.firstIndex(where: { $0.id == id }) else {
                throw WallpaperError("壁纸已不存在，无法重命名。")
            }
            $0.media[index].customName = trimmed
        }
    }
    func removeMedia(_ id: UUID) {
        mutate {
            $0.media.removeAll { $0.id == id }
            $0.displays.removeAll { $0.source.mediaID == id }
            for index in $0.playlists.indices { $0.playlists[index].entries.removeAll { $0.mediaID == id } }
            $0 = $0.clearingMissingCurrent()
        }
    }

    func applyPlaylist(_ id: UUID, displayID: String?, fit: ContentFit) {
        guard let ids = applicationDisplayIDs(displayID) else { return }
        guard let list = library.playlists.first(where: { $0.id == id }), !list.entries.isEmpty else {
            report(WallpaperError("请先向播放列表添加壁纸。")); return
        }
        let group = UUID()
        if mutate({
            $0.displays.removeAll { ids.contains($0.id) }
            $0.displays.append(contentsOf: ids.map { DisplayBinding(id: $0, playlistID: id, fit: fit, groupID: group) })
        }) { previewLifetime.stopCurrent() }
    }
    func applyMedia(_ item: MediaItem, displayID: String?, fit: ContentFit, audio: AudioSettings = AudioSettings()) {
        guard let ids = applicationDisplayIDs(displayID) else { return }
        guard library.media.contains(where: { $0.id == item.id }) else {
            report(WallpaperError("壁纸已不在素材库中，请重新选择。")); return
        }
        let group = UUID()
        if mutate({
            $0.displays.removeAll { ids.contains($0.id) }
            $0.displays.append(contentsOf: ids.map {
                DisplayBinding(id: $0, source: .media(item.id, audio: audio), fit: fit, groupID: group)
            })
        }) { previewLifetime.stopCurrent() }
    }
    func updateDirectAudio(_ audio: AudioSettings, groupID: UUID) {
        guard let binding = library.displays.first(where: { $0.groupID == groupID }),
              case .media(let mediaID, _) = binding.source else {
            report(WallpaperError("此单张壁纸已停止或更换，无法保存声音设置。")); return
        }
        mutate {
            for index in $0.displays.indices where $0.displays[index].groupID == groupID {
                $0.displays[index].source = .media(mediaID, audio: audio)
            }
        }
    }

    func canAdvance(groupID: UUID? = nil) -> Bool {
        guard !loadFailed, !isShuttingDown else { return false }
        let connected = Set(displays.map(\.id))
        return library.displays.contains { binding in
            connected.contains(binding.id) && (groupID == nil || binding.groupID == groupID)
                && library.playlists.contains { $0.id == binding.playlistID && !$0.entries.isEmpty }
        }
    }
    private func applicationDisplayIDs(_ displayID: String?) -> [String]? {
        let connected = NSScreen.screens.compactMap(\.wallpaperID)
        if let displayID {
            guard connected.contains(displayID) else {
                report(WallpaperError("目标显示器已断开，请重新选择显示器。")); return nil
            }
            return [displayID]
        }
        guard !connected.isEmpty else { report(WallpaperError("没有可用的显示器。")); return nil }
        return connected
    }
    func stopDisplay(_ id: String) { mutate { $0.displays.removeAll { $0.id == id } } }
    func next(groupID: UUID? = nil) {
        guard canAdvance(groupID: groupID) else { return }
        desktop.next(groupID: groupID)
    }
    func togglePause() { userPaused.toggle(); updatePause() }
    @discardableResult
    func setWebInteractionEnabled(_ enabled: Bool) -> WebInteractionSettingResult {
        guard !isShuttingDown, !loadFailed else {
            webInteractionFailure = PresentedFailure(title: "网页交互设置未完成", summary: isShuttingDown
                ? "应用正在退出，无法修改网页交互。" : "素材库无法读取，无法保存网页交互设置。")
            return .failed
        }
        let outcome = webInteractionController.setEnabled(enabled,
            currentEnabled: library.settings.webInteractionEnabled,
            persistAndPublish: persistAndPublishWebInteractionSetting,
            forcePublish: forcePublishWebInteractionSetting)
        presentWebInteractionFailure(outcome.failure)
        return outcome.result
    }

    @discardableResult
    func requestWebInteractionPermission(_ permission: WebInteractionPermission) -> Bool {
        guard !isShuttingDown else {
            webInteractionFailure = PresentedFailure(title: "网页交互设置未完成",
                summary: "应用正在退出，无法请求网页交互权限。")
            return false
        }
        switch webInteractionController.requestPermission(permission) {
        case nil:
            // Opening Settings, even if permission is granted there, is not a request to enable.
            return true
        case .settings(let error):
            webInteractionFailure = PresentedFailure(title: "网页交互设置未完成",
                summary: "无法打开系统隐私设置。", diagnostics: FailureDiagnostics.describe(error))
            return false
        case .shuttingDown:
            webInteractionFailure = PresentedFailure(title: "网页交互设置未完成",
                summary: "应用正在退出，无法请求网页交互权限。")
            return false
        case .persistence:
            preconditionFailure("Permission requests cannot persist settings")
        }
    }

    func refreshWebInteractionStatus() {
        guard !isShuttingDown else { return }
        let failure = webInteractionController.refresh(currentEnabled: library.settings.webInteractionEnabled,
            persistAndPublish: persistAndPublishWebInteractionSetting,
            forcePublish: forcePublishWebInteractionSetting)
        presentWebInteractionFailure(failure)
    }

    private func restoreWebInteraction() {
        guard !loadFailed, library.settings.webInteractionEnabled else { return }
        let failure = webInteractionController.restore(currentEnabled: true,
            persistAndPublish: persistAndPublishWebInteractionSetting,
            forcePublish: forcePublishWebInteractionSetting)
        presentWebInteractionFailure(failure)
    }

    private func persistAndPublishWebInteractionSetting(_ enabled: Bool) throws {
        var candidate = library
        candidate.settings.webInteractionEnabled = enabled
        try store.save(candidate)
        library = candidate
        webInteractionFailure = nil
    }

    private func forcePublishWebInteractionSetting(_ enabled: Bool) {
        library.settings.webInteractionEnabled = enabled
    }

    private func presentWebInteractionFailure(_ failure: WebInteractionControlFailure?) {
        switch failure {
        case nil: break
        case .persistence(let error, let runtimeWasForcedOff):
            webInteractionFailure = PresentedFailure(title: "网页交互设置未完成",
                summary: runtimeWasForcedOff
                    ? "缺少所需权限，网页交互已关闭，但无法保存关闭状态。"
                    : "无法保存网页交互设置。",
                diagnostics: FailureDiagnostics.describe(error))
        case .settings(let error):
            webInteractionFailure = PresentedFailure(title: "网页交互设置未完成",
                summary: "无法打开系统隐私设置。", diagnostics: FailureDiagnostics.describe(error))
        case .shuttingDown:
            webInteractionFailure = PresentedFailure(title: "网页交互设置未完成",
                summary: "应用正在退出，无法修改网页交互。")
        }
    }
    private func updatePause() {
        desktop.setPaused(isPaused)
        previewLifetime.setPowerPaused(!pauseReasons.isEmpty)
    }

    @discardableResult
    func clearMediaLibrary() -> Bool {
        do {
            guard !isShuttingDown, !loadFailed else { throw WallpaperError("当前无法清空素材库。") }
            guard !importing else { throw WallpaperError("请等待导入完成或取消导入后，再清空素材库。") }
            try transcoding.validateRemoval(library.media)
            lastLibraryBackup = try store.backup()
            guard mutate({ $0.media = []; $0.playlists = []; $0.displays = [] }) else { return false }
            section = .library; selectedMediaID = nil; selectedEntryID = nil
            batchSelection.finish()
            return true
        } catch { report(error, context: .save); return false }
    }

    func waitForMediaRemovals() async { await mediaRemoval.wait() }

    private func beginReleasingMedia(_ ids: Set<UUID>) -> Task<Void, Error> {
        transcoding.didRemoveMedia(ids)
        let tasks = [previewLifetime.beginRemovingMedia(ids), inspectorMedia.beginRemovingMedia(ids),
                     thumbnails.beginRemovingMedia(ids), desktop.beginRemovingMedia(ids)]
            + (screenSaver.map { [$0.beginRemovingMedia(ids)] } ?? [])
        return Task { @MainActor in try await PlaybackCloseBarrier.wait(for: tasks) }
    }

    private func scheduleMediaRemoval(_ items: [MediaItem], releasing: Task<Void, Error>?) {
        guard !items.isEmpty || releasing != nil else { return }
        mediaRemoval.enqueue(items, releasing: releasing, didRemove: { [weak self] id in
            guard let self else { throw WallpaperError("素材库已关闭，待清理记录未更新。") }
            var candidate = self.library
            candidate.pendingMediaDeletions.removeAll { $0.id == id }
            try self.store.save(candidate)
            self.library = candidate
        }, onError: { [weak self] in self?.report($0) })
    }

    func resetLibrary() {
        guard loadFailed, !isShuttingDown else {
            report(WallpaperError("当前不能重置损坏配置；清空素材请使用“清空素材库”。")); return
        }
        do {
            if FileManager.default.fileExists(atPath: store.url.path) {
                let backup = store.url.deletingLastPathComponent().appendingPathComponent("library-backup-\(UUID().uuidString).json")
                try FileManager.default.copyItem(at: store.url, to: backup)
            }
            let empty = Library.empty
            let previous = library
            let commit: () throws -> Void = {
                try self.store.save(empty)
                self.library = empty; self.loadFailed = false; self.errorMessage = nil
                self.screenSaver?.attach(library: empty, loaded: true)
                self.screenSaver?.libraryDidCommit(empty, previous: previous, forceRevalidate: true)
            }
            if let screenSaver { try screenSaver.withLibraryCommitLock(commit) }
            else { try commit() }
            systemWallpaperSync.setEnabled(false)
            systemWallpaperFailure = nil
            desktop.reconcile(empty)
            webInteractionFailure = nil
            webInteractionController.disableRuntime()
        } catch { report(error) }
    }
    func report(_ error: Error) { report(error, context: .operation) }
    func report(_ error: Error, context: FailureContext) { failure = PresentedFailure(error, context: context) }
    private func recordCommit(group: UUID, entry: UUID) {
        var candidate = library
        for index in candidate.displays.indices where candidate.displays[index].groupID == group {
            guard candidate.playlists.contains(where: { $0.id == candidate.displays[index].playlistID && $0.entries.contains(where: { $0.id == entry }) }) else { continue }
            candidate.displays[index].currentEntryID = entry
        }
        guard candidate != library else { return }
        do { try store.save(candidate); library = candidate } catch { report(error) }
    }
    func shutdown() {
        _ = beginShutdown()
    }

    func shutdownAndWait() async throws { try await beginShutdown().value }

    private func beginShutdown() -> Task<Void, Error> {
        lifecycle.beginShutdown(plan: ApplicationShutdownPlan(
            immediate: {
                self.isShuttingDown = true
                self.presentation.cancelActivation()
                self.systemWallpaperSync.shutdown()
                self.loginItems.shutdown()
                self.webInteractionController.shutdown()
                self.importTask?.cancel()
                self.desktop.shutdown()
            }, importing: importTask,
            drain: {
                await self.mediaRemoval.wait()
                await self.systemWallpaperSync.waitForPendingOperations()
            }, makeCloseTasks: {
                let tasks = [
                    Task { @MainActor in try await self.desktop.waitForShutdown() },
                    Task { @MainActor in try await self.previewLifetime.closeAll() },
                    self.transcoding.beginShutdown(), self.inspectorMedia.beginShutdown(),
                    self.thumbnails.beginShutdown(),
                ]
                return tasks + (self.screenSaver.map { [$0.beginShutdown()] } ?? [])
            }, requireReleased: managedImport.requireReleased,
            shutdownWebRuntime: webRuntime.shutdown))
    }
}

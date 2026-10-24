import SwiftUI
import WallpaperCore

struct LibraryView: View {
    @Localized private var l10n
    @ObservedObject var model: AppModel
    let product: ProductBundleMetadata
    @Environment(\.appPalette) private var palette
    var applicationIcon: NSImage = AppBranding.applicationIcon
    @State private var isSidebarVisible = true
    @State private var showReset = false
    @State private var removal: LibraryRemoval?

    var body: some View {
        // Keep the columns flush; NavigationSplitView adds floating sidebar chrome on macOS 26.
        HSplitView {
            if isSidebarVisible {
                sidebar.frame(minWidth: 190, idealWidth: 205, maxWidth: 250, maxHeight: .infinity)
            }
            VStack(spacing: 0) {
                if model.loadFailed { recoveryBanner }
                if case .displays = model.section { DisplaySettingsView(model: model) }
                else if case .screenSaver = model.section, let screenSaver = model.screenSaver {
                    ScreenSaverManagementView(model: model, screenSaver: screenSaver, product: product)
                }
                else if let playlist = model.selectedPlaylist { PlaylistEditor(model: model, playlist: playlist) }
                else { mediaLibrary }
            }
            .frame(minWidth: 400, idealWidth: 580, maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)
            if model.inspectorSelection != nil {
                InspectorView(model: model)
                    .frame(minWidth: 260, idealWidth: 290, maxWidth: 360, maxHeight: .infinity)
            }
        }
        .appGlassBackground(.window, appearance: model.library.settings.appearance,
                            receivesTransparentClicks: true,
                            captureWallpaper: model.captureWallpaper, makeWallpaperMirror: model.makeWallpaperMirror)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .toolbar { libraryToolbar }
        .dropDestination(for: URL.self) { urls, _ in
            model.importURLs(urls, purpose: model.section == .screenSaver ? .screenSaver : .wallpaper)
            return true
        }
        .sheet(isPresented: $model.showingImport) {
            WallpaperImportView(model: model, purpose: model.importPurpose).appInterfacePreferences(model)
        }
        .applicationFailurePresentation($model.failure)
        .onReceive(NotificationCenter.default.publisher(for: .cancelPendingPresentationsForQuit)) { _ in
            model.failure = nil
            showReset = false
            removal = nil
        }
        .modifier(LibraryRemovalConfirmation(removal: $removal, model: model))
        .confirmationDialog(l10n("备份并重置素材库？"), isPresented: $showReset, titleVisibility: .visible) {
            Button(l10n("备份并重置"), role: .destructive, action: model.resetLibrary)
        } message: { Text(l10n.text(WallpaperCopy.resetConfirmation)) }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            AppBrandHeader(icon: applicationIcon, product: product)
            List(selection: $model.section) {
                Section(l10n("素材库")) {
                    sidebarRow(l10n("全部壁纸"), systemImage: "square.grid.2x2", section: .library)
                    sidebarRow(l10n("我的收藏"), systemImage: "heart", section: .favorites)
                    sidebarRow(l10n("显示器"), systemImage: "display.2", section: .displays)
                    sidebarRow(l10n("屏幕保护"), systemImage: "sparkles.tv", section: .screenSaver)
                }
                Section {
                    ForEach(model.library.playlists) { playlist in
                        sidebarRow(playlist.name, systemImage: "music.note.list", section: .playlist(playlist.id))
                            .contextMenu { Button(l10n("删除播放列表"), role: .destructive) { removal = .playlist(playlist) } }
                    }
                    Button(action: model.addPlaylist) { Label(l10n("新建播放列表"), systemImage: "plus") }.buttonStyle(.plain)
                } header: { Text(l10n("播放列表")) }
            }.listStyle(.sidebar).scrollContentBackground(.hidden)
            HStack {
                SettingsLink { Label(l10n("设置"), systemImage: "gearshape") }.buttonStyle(.plain)
                Spacer()
                Text(l10n("本地优先")).font(.caption2).foregroundStyle(.tertiary)
            }.padding(16)
        }
    }

    @ToolbarContentBuilder
    private var libraryToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                isSidebarVisible.toggle()
            } label: {
                Label(l10n("切换侧边栏"), systemImage: "sidebar.left")
            }
            .help(isSidebarVisible ? l10n("隐藏侧边栏") : l10n("显示侧边栏"))
            .keyboardShortcut("s", modifiers: [.control, .command])
        }
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .primaryAction) { importButton }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .primaryAction) { importButton }
        }
    }

    private var importButton: some View {
        let title = model.importing ? l10n("导入中…")
            : (model.section == .screenSaver ? l10n("导入屏保素材") : l10n("导入壁纸"))
        return Button { model.importFiles(purpose: model.section == .screenSaver ? .screenSaver : .wallpaper) } label: {
            Label(title, systemImage: "plus")
        }
            .labelStyle(.iconOnly)
            .appGlassControlStyle()
            .help(title)
            .disabled(model.importing || model.loadFailed || model.isShuttingDown)
    }

    private func sidebarRow(_ title: String, systemImage: String, section: SidebarSection) -> some View {
        Label {
            Text(title).foregroundStyle(.primary)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(model.section == section ? palette.selectionIndicator : .primary)
        }
        .tag(section)
        .selectionRowStyle(isSelected: model.section == section)
    }

    private var mediaLibrary: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(model.section == .favorites ? l10n("我的收藏") : l10n("壁纸"))
                .font(.title2.weight(.semibold))
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(l10n("搜索壁纸"), text: $model.search).textFieldStyle(.plain)
                Text(l10n("\(model.filteredMedia.count) 项")).font(.caption).foregroundStyle(.secondary)
            }.padding(10).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
            BatchToolbar(model: model)
            if model.filteredMedia.isEmpty {
                Spacer()
                libraryEmptyState
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 16)], spacing: 18) {
                        ForEach(model.filteredMedia) { item in
                            MediaCard(item: item, thumbnails: model.thumbnails, selected: model.batchSelection.isActive ? model.batchSelection.ids.contains(item.id) : item.id == model.selectedMediaID)
                                .overlay(alignment: .topTrailing) {
                                    if model.batchSelection.isActive {
                                        Image(systemName: model.batchSelection.ids.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                            .font(.title2).foregroundStyle(palette.selectionIndicator).padding(16)
                                    }
                                }
                                .onTapGesture {
                                    if model.batchSelection.isActive { model.batchSelection.toggle(item.id) }
                                    else { model.selectedMediaID = item.id; model.selectedEntryID = nil }
                                }
                                .accessibilityLabel(item.name)
                                .accessibilityValue(model.batchSelection.isActive && model.batchSelection.ids.contains(item.id) ? l10n("已选择") : "")
                                .contextMenu {
                                    if !model.batchSelection.isActive {
                                        Button(item.isFavorite ? l10n("取消收藏") : l10n("收藏")) { model.favorite(item.id) }
                                        Menu(l10n("加入播放列表")) {
                                            ForEach(model.library.playlists) { list in Button(list.name) { model.add(item.id, to: list.id) } }
                                        }
                                        Button(l10n("在 Finder 中显示")) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                                        Button(l10n("从素材库移除"), role: .destructive) { removal = .wallpaper(item) }
                                    }
                                }
                        }
                    }.padding(2)
                }
            }
        }.padding(24)
    }

    @ViewBuilder
    private var libraryEmptyState: some View {
        if !model.search.isEmpty {
            EmptyState(l10n("未找到匹配的壁纸"), subtitle: l10n("尝试其他关键词，或清除搜索。")) {
                Image(systemName: "magnifyingglass")
            } actions: {
                Button(l10n("清除搜索")) { model.search = "" }
            }
        } else if model.section == .favorites {
            EmptyState(l10n("还没有收藏的壁纸"), subtitle: l10n("收藏的壁纸会显示在这里。")) {
                Image(systemName: "heart")
            } actions: {
                Button(l10n("浏览全部壁纸")) { model.section = .library }
            }
        } else {
            EmptyState(l10n("还没有壁纸"), subtitle: l10n("拖入视频、动图或图片，或点击“导入壁纸”添加文件或本地网页项目。")) {
                Image(systemName: "rectangle.on.rectangle")
            } actions: {
                Button(l10n("导入壁纸")) { model.importFiles() }
                    .disabled(model.importing || model.loadFailed || model.isShuttingDown)
            }
        }
    }

    private var recoveryBanner: some View {
        HStack {
            Label(l10n("素材库无法读取，编辑已停用。"), systemImage: "exclamationmark.triangle")
            Button(l10n("备份并重置…")) { showReset = true }
        }.font(.caption).padding().frame(maxWidth: .infinity).background(.orange.opacity(0.15))
    }
}

private struct MediaCard: View {
    @Localized private var l10n
    @Environment(\.appPalette) private var palette
    let item: MediaItem
    let thumbnails: ThumbnailLifetime
    let selected: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ThumbnailView(item: item, lifetime: thumbnails).aspectRatio(16 / 10, contentMode: .fit)
                .overlay(alignment: .bottomLeading) {
                    Text(item.kind == .scene ? l10n("场景") : item.kind == .web ? l10n("网页") : item.url.pathExtension.uppercased()).font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 3).background(.ultraThinMaterial, in: Capsule()).padding(9)
                }.clipShape(RoundedRectangle(cornerRadius: 10))
            HStack {
                Text(item.name).font(.callout.weight(.medium)).lineLimit(1)
                Spacer(minLength: 0)
                if item.isFavorite { Image(systemName: "heart.fill").font(.caption).foregroundStyle(.pink) }
            }
            Text(item.kind == .scene ? l10n("本地场景项目") : item.kind == .web ? l10n("本地网页项目") : "\(item.width) × \(item.height)" + (item.duration.map { l10n("  ·  \($0.formatted(.number.precision(.fractionLength(0)))) 秒") } ?? ""))
                .font(.caption).foregroundStyle(.secondary)
        }.padding(10).background(selected ? palette.selectionBackground : Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(selected ? palette.selectionIndicator : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
    }
}

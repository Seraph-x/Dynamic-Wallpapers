import XCTest
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import ScreenCaptureKit
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class UISnapshotTests: XCTestCase {
    func testTranscodeWindowRendersRealPlanAndCompletedOutput() async throws {
        _ = NSApplication.shared
        let directory = try TranscodeTestFixtures.directory()
        defer { do { try FileManager.default.removeItem(at: directory) } catch { XCTFail("\(error)") } }
        let store = LibraryStore(url: directory.appendingPathComponent("library.json"))
        try store.save(.empty)
        let transcoding = TranscodeModel(tools: { TranscodeTestFixtures.tools })
        let model = AppModel(store: store, transcoding: transcoding)
        defer { model.shutdown() }
        let source = TranscodeTestFixtures.root.appendingPathComponent(".build/dependencies/mpv/fixtures/h264-aac.mkv")
        transcoding.select(try await MediaProbe.inspect(source))
        let deadline = ContinuousClock.now + .seconds(5)
        while transcoding.isProbing {
            guard ContinuousClock.now < deadline else { throw WallpaperError("Transcode UI probe timed out") }
            try await Task.sleep(for: .milliseconds(5))
        }
        transcoding.preset = .hd1080
        XCTAssertTrue(transcoding.enqueue(directory: directory, name: "转码输出.mp4", managedMediaDirectory: model.managedImport.files.directory))
        while transcoding.queue.hasActiveJobs {
            guard ContinuousClock.now < deadline else { throw WallpaperError("Transcode UI encoder timed out") }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(transcoding.queue.jobs[0].state, .succeeded)
        let window = NSWindow(contentRect: CGRect(x: 20, y: 20, width: 760, height: 760),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "DynamicWallpaper — transcode verification"
        window.contentView = NSHostingView(rootView: (TranscodeView(model: model).tint(AppColors.brandAccent)).environment(\.locale, Locale(identifier: "zh-Hans")))
        window.orderBack(nil)
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(300))
        let output = TranscodeTestFixtures.root.appendingPathComponent(".build/verification/transcode-window.png")
        try await capture(window, to: output)
        XCTAssertNil(transcoding.errorMessage)
        XCTAssertTrue(model.library.media.isEmpty, "A success row is not an automatic import")
        try await model.shutdownAndWait()
    }

    func testExtendedLibraryWindowRendersRealThumbnailsAndPolicy() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let output = root.appendingPathComponent(".build/verification")
        let store = LibraryStore(url: output.appendingPathComponent("extended-ui-test-library.json"))
        var library = Library.empty
        for name in ["h264-aac.mkv", "vp9-opus.webm", "mpeg4-mp3.avi"] {
            library.media.append(try await MediaProbe.inspect(root.appendingPathComponent(".build/dependencies/mpv/fixtures/" + name)))
        }
        library.playlists[0].entries = library.media.map { PlaylistEntry(mediaID: $0.id) }
        try store.save(library)
        let model = AppModel(store: store)
        model.section = .playlist(library.playlists[0].id)
        model.selectedMediaID = library.media[0].id
        model.selectedEntryID = library.playlists[0].entries[0].id
        let window = NSWindow(contentRect: CGRect(x: 20, y: 20, width: 1000, height: 650),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "DynamicWallpaper — extended verification"
        window.contentView = NSHostingView(rootView: (LibraryView(model: model,
            product: ProductMetadataTestSupport.product).tint(AppColors.brandAccent)
            .frame(width: 1000, height: 650)).environment(\.locale, Locale(identifier: "zh-Hans")))
        window.orderBack(nil)
        defer { window.contentView = nil; window.close(); model.shutdown() }
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertNil(model.errorMessage)
        try await capture(window, to: output.appendingPathComponent("extended-library-window.png"))
        window.contentView = nil
        try await model.shutdownAndWait()
    }

    func testRealLibraryWindowRenders() async throws {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/verification")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let mediaURL = output.appendingPathComponent("test-landscape.png")
        try writeLandscape(to: mediaURL)
        let store = LibraryStore(url: output.appendingPathComponent("ui-test-library.json"))
        var library = Library.empty
        let media = try await MediaProbe.inspect(mediaURL)
        library.media = [media]
        library.playlists[0].entries = [PlaylistEntry(mediaID: media.id)]
        try store.save(library)
        let model = AppModel(store: store)
        model.selectedMediaID = media.id
        defer { model.shutdown() }
        let host = NSHostingView(rootView: (LibraryView(model: model,
            product: ProductMetadataTestSupport.product).tint(AppColors.brandAccent)
            .frame(width: 1180, height: 760)).environment(\.locale, Locale(identifier: "zh-Hans")))
        let window = NSWindow(contentRect: CGRect(x: 20, y: 20, width: 1180, height: 760),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "DynamicWallpaper — UI verification"
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(700))
        try await capture(window, to: output.appendingPathComponent("library-window.png"))
        model.section = .playlist(library.playlists[0].id)
        model.selectedEntryID = library.playlists[0].entries[0].id
        try await Task.sleep(for: .milliseconds(300))
        try await capture(window, to: output.appendingPathComponent("playlist-window.png"))
        model.section = .displays
        try await Task.sleep(for: .milliseconds(100))
        model.applyPlaylist(library.playlists[0].id, displayID: nil, fit: .fit)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertNil(model.errorMessage)
        try await capture(window, to: output.appendingPathComponent("displays-window.png"))
        let videoURL = try await VideoIntegrationTests.makeVideo()
        defer { do { try FileManager.default.removeItem(at: videoURL) } catch { XCTFail(error.localizedDescription) } }
        let video = try await MediaProbe.inspect(videoURL)
        let entry = PlaylistEntry(mediaID: video.id, audio: AudioSettings(volume: 0.35))
        model.mutate { $0.media.append(video); $0.playlists[0].entries.append(entry) }
        model.section = .playlist(library.playlists[0].id)
        model.selectedMediaID = video.id; model.selectedEntryID = entry.id
        try await Task.sleep(for: .milliseconds(300))
        try await capture(window, to: output.appendingPathComponent("audio-playlist-window.png"))
        let settings = NSHostingView(rootView: (SettingsView(
            model: model, product: ProductMetadataTestSupport.product)
            .tint(AppColors.brandAccent)).environment(\.locale, Locale(identifier: "zh-Hans")))
        window.contentView = settings
        window.setContentSize(settings.fittingSize)
        try await Task.sleep(for: .milliseconds(200))
        try await capture(window, to: output.appendingPathComponent("audio-settings-window.png"))
    }

    func testBatchWindowsRenderAtMinimumSize() async throws {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/verification")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let imageURL = output.appendingPathComponent("batch-landscape.png")
        try writeLandscape(to: imageURL)
        let videoURL = try await VideoIntegrationTests.makeVideo()
        defer { do { try FileManager.default.removeItem(at: videoURL) } catch { XCTFail(error.localizedDescription) } }
        let photo = try await MediaProbe.inspect(imageURL), video = try await MediaProbe.inspect(videoURL)
        let store = LibraryStore(url: output.appendingPathComponent("batch-ui-library.json"))
        var library = Library.empty
        library.media = [photo, video]
        library.playlists[0].entries = [PlaylistEntry(mediaID: photo.id), PlaylistEntry(mediaID: video.id),
            PlaylistEntry(mediaID: video.id, audio: AudioSettings(isMuted: true, volume: 0.3))]
        try store.save(library)
        let model = AppModel(store: store)
        defer { model.shutdown() }
        model.batchSelection.start(); model.batchSelection.selectAll(model.visibleBatchIDs)
        let window = NSWindow(contentRect: CGRect(x: 20, y: 20, width: 1000, height: 650),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "DynamicWallpaper — batch verification"
        window.contentView = NSHostingView(rootView: (LibraryView(model: model,
            product: ProductMetadataTestSupport.product).tint(AppColors.brandAccent)
            .frame(width: 1000, height: 650)).environment(\.locale, Locale(identifier: "zh-Hans")))
        window.orderBack(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(400))
        try await capture(window, to: output.appendingPathComponent("v2-batch-library.png"))
        model.section = .playlist(library.playlists[0].id)
        model.batchSelection.start(); model.batchSelection.selectAll(model.visibleBatchIDs)
        try await Task.sleep(for: .milliseconds(250))
        try await capture(window, to: output.appendingPathComponent("v2-batch-playlist.png"))
        let target = BatchEditTarget(playlistID: library.playlists[0].id, entryIDs: model.batchSelection.ids)
        window.setContentSize(NSSize(width: 548, height: 648))
        window.contentView = NSHostingView(rootView: (BatchEntryEditor(model: model, target: target).tint(AppColors.brandAccent)).environment(\.locale, Locale(identifier: "zh-Hans")))
        try await Task.sleep(for: .milliseconds(250))
        try await capture(window, to: output.appendingPathComponent("v2-batch-editor.png"))
        var draft = BatchEntryDraft()
        draft.changeTiming = true; draft.mode = .loops; draft.durationValue = "7"; draft.loops = "3"
        draft.changeMute = true; draft.muted = true; draft.changeVolume = true; draft.volume = 0.35
        window.contentView = NSHostingView(rootView: (BatchEntryEditor(model: model, target: target, draft: draft).tint(AppColors.brandAccent)).environment(\.locale, Locale(identifier: "zh-Hans")))
        try await Task.sleep(for: .milliseconds(200))
        try await capture(window, to: output.appendingPathComponent("v2-batch-editor-expanded.png"))
        draft.durationValue = "abc"
        window.contentView = NSHostingView(rootView: (BatchEntryEditor(model: model, target: target, draft: draft).tint(AppColors.brandAccent)).environment(\.locale, Locale(identifier: "zh-Hans")))
        try await Task.sleep(for: .milliseconds(200))
        try await capture(window, to: output.appendingPathComponent("v2-batch-editor-invalid.png"))
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.library, library, "Opening batch selection and editor must not edit data")
    }

    func testWebEditorsRenderAndSaveOnlyCheckedFieldsViaNativeAction() async throws {
        _ = NSApplication.shared
        let directory = try TranscodeTestFixtures.directory()
        defer { do { try FileManager.default.removeItem(at: directory) } catch { XCTFail("\(error)") } }
        let output = TranscodeTestFixtures.root.appendingPathComponent(".build/verification")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try Data("<!doctype html><title>网页编辑验证</title><canvas></canvas>".utf8)
            .write(to: directory.appendingPathComponent("index.html"))
        let web = try WebProjectProbe.inspect(WebProjectReference(root: directory, entry: "index.html"))
        let photoURL = directory.appendingPathComponent("photo.png")
        try writeLandscape(to: photoURL)
        let photo = try await MediaProbe.inspect(photoURL)
        let store = LibraryStore(url: directory.appendingPathComponent("library.json"))
        var library = Library.empty
        library.media = [web, photo]
        library.playlists[0].entries = [
            PlaylistEntry(mediaID: web.id, timing: EntryTiming(seconds: 12.5), audio: AudioSettings(volume: 0.35)),
            PlaylistEntry(mediaID: web.id, timing: EntryTiming(seconds: 42), audio: AudioSettings(isMuted: true)),
            PlaylistEntry(mediaID: photo.id)]
        try store.save(library)
        let model = AppModel(store: store)
        defer { model.shutdown() }
        model.section = .playlist(library.playlists[0].id)
        model.selectedMediaID = web.id; model.selectedEntryID = library.playlists[0].entries[0].id
        let window = NSWindow(contentRect: CGRect(x: 20, y: 20, width: 1000, height: 650),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "DynamicWallpaper — web editor verification"
        window.contentView = NSHostingView(rootView: (LibraryView(model: model,
            product: ProductMetadataTestSupport.product).tint(AppColors.brandAccent)
            .frame(width: 1000, height: 650)).environment(\.locale, Locale(identifier: "zh-Hans")))
        window.orderBack(nil)
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(300))
        try await capture(window, to: output.appendingPathComponent("web-playlist-window.png"))
        // A tall inspector makes the timing section inspectable without pretending
        // that the current backend can already render or preview this webpage.
        window.contentView = NSHostingView(rootView: (InspectorView(model: model).tint(AppColors.brandAccent).frame(width: 400, height: 1000)).environment(\.locale, Locale(identifier: "zh-Hans")))
        try await Task.sleep(for: .milliseconds(200))
        // Let SwiftUI remove the library toolbar/titlebar configuration before
        // sizing the replacement; those changes alter AppKit's content area.
        window.setContentSize(NSSize(width: 400, height: 1000))
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(window.contentView?.bounds.size, NSSize(width: 400, height: 1000))
        try await capture(window, to: output.appendingPathComponent("web-detail-editor.png"))
        let target = BatchEditTarget(playlistID: library.playlists[0].id,
                                    entryIDs: Set(library.playlists[0].entries.map(\.id)))
        var draft = BatchEntryDraft()
        draft.changeTiming = true; draft.durationValue = "18.5"
        draft.changeMute = true; draft.muted = true; draft.changeVolume = true; draft.volume = 0.42
        window.setContentSize(NSSize(width: 548, height: 648))
        window.contentView = NSHostingView(rootView: (BatchEntryEditor(model: model, target: target, draft: draft).tint(AppColors.brandAccent)).environment(\.locale, Locale(identifier: "zh-Hans")))
        try await Task.sleep(for: .milliseconds(200))
        try await capture(window, to: output.appendingPathComponent("web-batch-editor.png"))
        draft.durationValue = "not-a-number"
        window.contentView = NSHostingView(rootView: (BatchEntryEditor(model: model, target: target, draft: draft).tint(AppColors.brandAccent)).environment(\.locale, Locale(identifier: "zh-Hans")))
        try await Task.sleep(for: .milliseconds(200))
        try await capture(window, to: output.appendingPathComponent("web-batch-editor-invalid.png"))
        let saveKey = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        XCTAssertFalse(window.performKeyEquivalent(with: saveKey), "Invalid timing must disable the actual Save action")
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.library, library)
        XCTAssertEqual(try store.load(), library)
        draft.changeTiming = false
        window.contentView = NSHostingView(rootView: (BatchEntryEditor(model: model, target: target, draft: draft).tint(AppColors.brandAccent)).environment(\.locale, Locale(identifier: "zh-Hans")))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(window.performKeyEquivalent(with: saveKey), "The actual editor must handle its default Save action")
        try await Task.sleep(for: .milliseconds(50))
        library.playlists[0].entries[0].audio = AudioSettings(isMuted: true, volume: 0.42)
        library.playlists[0].entries[1].audio = AudioSettings(isMuted: true, volume: 0.42)
        XCTAssertEqual(model.library, library, "Unchecked invalid timing and the photo's audio must stay unchanged")
        XCTAssertEqual(try store.load(), library)
        window.contentView = nil
        try await model.shutdownAndWait()
    }

    private func capture(_ window: NSWindow, to url: URL) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        let target = try XCTUnwrap(content.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
        let filter = SCContentFilter(desktopIndependentWindow: target)
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * 2); config.height = Int(window.frame.height * 2)
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func writeLandscape(to url: URL) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 960, height: 600, bitsPerComponent: 8,
            bytesPerRow: 3840, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let colors = [NSColor(red: 0.04, green: 0.11, blue: 0.19, alpha: 1).cgColor,
                      NSColor(red: 0.23, green: 0.64, blue: 0.59, alpha: 1).cgColor]
        let gradient = try XCTUnwrap(CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]))
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 600), end: CGPoint(x: 960, y: 0), options: [])
        context.setFillColor(NSColor(red: 0.93, green: 0.86, blue: 0.63, alpha: 1).cgColor)
        context.fillEllipse(in: CGRect(x: 660, y: 370, width: 95, height: 95))
        for (height, opacity) in [(80.0, 0.4), (0.0, 0.7)] {
            context.move(to: CGPoint(x: 0, y: 160 + height))
            context.addCurve(to: CGPoint(x: 960, y: 240 + height), control1: CGPoint(x: 300, y: 520 + height), control2: CGPoint(x: 450, y: -40 + height))
            context.addLine(to: CGPoint(x: 960, y: 0)); context.addLine(to: .zero); context.closePath()
            context.setFillColor(NSColor(red: 0.04, green: 0.17, blue: 0.22, alpha: opacity).cgColor); context.fillPath()
        }
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}

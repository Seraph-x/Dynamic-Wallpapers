import AppKit
import Darwin
import WebWallpaperBridge
import WallpaperCore

@main
struct WebSwiftHarness {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw WallpaperError(message) }
    }

    @MainActor
    static func run() async throws {
        let arguments = CommandLine.arguments
        let mirrorExperiments = arguments.count == 4 && arguments[2] == "--mirror-experiments"
        guard arguments.count == 2 || mirrorExperiments else {
            throw WallpaperError("Expected lifecycle fixture path, optionally followed by --mirror-experiments and dynamic fixture path")
        }
        print("WEB_SWIFT MODE \(mirrorExperiments ? "mirror-experiments" : "lifecycle")")
        fflush(stdout)
        let project = WebProjectReference(root: URL(fileURLWithPath: arguments[1]), entry: "index.html")
        let mirrorProject = mirrorExperiments
            ? WebProjectReference(root: URL(fileURLWithPath: arguments[3]), entry: "index.html") : nil
        let runtime = CEFApplicationRuntime()
        let surface = WebSurface(size: CGSize(width: 320, height: 180), fit: .fill, pageFactory: runtime)
        var failure: Error?
        surface.onError = { failure = $0 }
        let item = MediaItem(url: project.entryURL, kind: .web, width: 320, height: 180,
                             backend: .web, webProject: project)
        do {
            try await surface.prepare(item: item, scale: 1, fit: .fill)
            try require(surface.state == .ready && runtime.activePageCount == 1, "Swift page did not prepare")
            let paintView = try surface.subviews.first.unwrap("No mounted CEF view")
            try require(paintView.layer?.contents != nil, "Swift surface has no real frame")
            try require(paintView.layer?.contentsGravity == .resizeAspectFill, "Fit was not applied to the painted layer")
            let frame = paintView.layer?.contents as AnyObject?
            surface.play()
            try require(surface.state == .playing, "Muted page did not play")
            surface.pause()
            let deadline = ProcessInfo.processInfo.systemUptime + 8
            while surface.state == .pausing {
                try require(ProcessInfo.processInfo.systemUptime < deadline, "Swift pause close deadline")
                try await Task.sleep(for: .milliseconds(5))
            }
            if let failure { throw failure }
            try require(surface.state == .paused && runtime.activePageCount == 0, "Pause did not close the CEF session")
            try require(surface.subviews.first === paintView && paintView.layer?.contents as AnyObject? === frame,
                        "Pause did not preserve the exact view/frame")
            try await surface.prepareToResume()
            try require(surface.state == .ready && runtime.activePageCount == 1, "Resume did not reload one session")
            try require(surface.subviews.first === paintView, "Resume preparation replaced the retained pause frame")
            surface.play()
            try require(surface.subviews.first !== paintView, "Resume commit reused the closed page")
            try await surface.close()
            try require(runtime.activePageCount == 0, "Swift close left an owned page")
            if let mirrorProject {
                if #available(macOS 14.4, *) {
                    try await WebSwiftMirrorHarness.run(project: mirrorProject, runtime: runtime)
                } else {
                    throw WallpaperError("Fullscreen mirror pixel readback requires macOS 14.4 or later")
                }
            }
            try await runtime.shutdown()
            if let failure { throw failure }
            print("WEB_SWIFT PASS frame=1 fit=1 pauseClosed=1 retainedFrame=1 resumeReloaded=1 shutdown=1 audio=muted-only")
        } catch {
            do { try await surface.close(); try await runtime.shutdown() }
            catch { fputs("WEB_SWIFT cleanup failure: \(error.localizedDescription)\n", stderr) }
            throw error
        }
    }

    @MainActor
    static func main() {
        DWWebCreateApplication()
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await run(); Darwin.exit(0) }
            catch { fputs("WEB_SWIFT FAILED \(error.localizedDescription)\n", stderr); Darwin.exit(1) }
        }
        NSApp.run()
    }
}

private extension Optional {
    func unwrap(_ message: String) throws -> Wrapped {
        guard let value = self else { throw WallpaperError(message) }
        return value
    }
}

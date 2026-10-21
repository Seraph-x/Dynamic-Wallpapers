import WallpaperNative
import AppKit
import CoreMedia
import ScreenCaptureKit
import WallpaperCore
import Darwin

extension WebAudioHarness {
    @MainActor static func runPair() async throws {
        try require(CommandLine.arguments.count == 3, "Expected two isolated projects")
        let projects = CommandLine.arguments.dropFirst().map {
            WebProjectReference(root: URL(fileURLWithPath: $0), entry: "index.html")
        }
        let output = projects[0].root.deletingLastPathComponent()
        let runtime = CEFApplicationRuntime()
        let surfaces = projects.map { _ in WebSurface(size: CGSize(width: 320, height: 180), fit: .fill, pageFactory: runtime) }
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 320, height: 180),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "DynamicWallpaper isolated two-page audio test"
        window.orderBack(nil)
        defer { window.orderOut(nil); window.close() }
        let capture = SystemAudioEvidence(), bypass = SystemAudioEvidence()
        let queue = DispatchQueue(label: "web-pair-native"), bypassQueue = DispatchQueue(label: "web-pair-default")
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let own = content.applications.first(where: { $0.processID == getpid() }), let display = content.displays.first else {
            throw WallpaperError("Two-page audio test process is not enumerated")
        }
        let stream = try makeStream(SCContentFilter(display: display, including: [own], exceptingWindows: []),
                                    excludingSelf: false, observer: capture, queue: queue)
        let defaultStream = try makeStream(SCContentFilter(display: display,
            excludingApplications: content.applications.filter { $0.processID != getpid() }, exceptingWindows: []),
            excludingSelf: true, observer: bypass, queue: bypassQueue)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var windows: [NativeRetirementAudioWindow] = [], failure: Error?
        var capturing = false, capturingDefault = false
        var rampStart = 0.0
        func save() throws {
            try capture.writeEvidence(to: output.appendingPathComponent("native-capture.json"))
            try bypass.writeEvidence(to: output.appendingPathComponent("default-capture.json"))
            try encoder.encode(windows).write(to: output.appendingPathComponent("windows.json"), options: .withoutOverwriting)
        }
        func observePair(_ name: String, silent: Bool) async throws {
            if let failure { throw failure }
            windows.append(try await observe(name, silent: silent))
            if let failure { throw failure }
        }
        do {
            try await stream.startCapture(); capturing = true
            try await defaultStream.startCapture(); capturingDefault = true
            let deadline = ContinuousClock.now + .seconds(10)
            while capture.snapshot().packets.isEmpty || bypass.snapshot().packets.isEmpty {
                try require(ContinuousClock.now < deadline, "Two-page capture did not become ready")
                try require(capture.snapshot().errors.isEmpty && bypass.snapshot().errors.isEmpty, "Capture startup error")
                try await Task.sleep(for: .milliseconds(20))
            }
            for (surface, project) in zip(surfaces, projects) {
                surface.onError = { failure = $0 }
                surface.setGlobalMute(false); surface.setAudio(AudioSettings(volume: 0.8))
                window.contentView?.addSubview(surface)
                try await surface.prepare(item: MediaItem(url: project.entryURL, kind: .web, width: 320,
                    height: 180, backend: .web, webProject: project), scale: 1, fit: .fill)
                try await waitForGreen(surface, failure: { failure })
            }
            let first = surfaces[0], second = surfaces[1]
            try await observePair("both-prepared", silent: true)
            first.play()
            try await observePair("first-alone", silent: false)
            first.setAudioSuppressed(true); second.play()
            try await observePair("second-alone", silent: false)
            first.setAudioSuppressed(false)
            try await observePair("both-playing", silent: false)
            second.setTransitionGain(0)
            try await observePair("transition-start", silent: false)
            rampStart = CMClockGetTime(CMClockGetHostTimeClock()).seconds
            try await SharedTransition.run(duration: 0.8) { progress in
                first.alphaValue = 1 - progress; second.alphaValue = progress
                first.setTransitionGain(1 - progress); second.setTransitionGain(progress)
            }
            try await observePair("transition-end", silent: false)
            try await first.close()
            try require(runtime.activePageCount == 1, "Closing the first page must leave the second page owned")
            try await observePair("first-closed-second-playing", silent: false)
            second.setGlobalMute(true)
            try await observePair("second-muted", silent: true)
            second.setGlobalMute(false)
            try await observePair("second-unmuted", silent: false)
            second.pause()
            try await observePair("second-paused", silent: true)
            let paused = ContinuousClock.now + .seconds(8)
            while second.state == .pausing {
                try require(ContinuousClock.now < paused, "Second page pause did not release its session")
                try await Task.sleep(for: .milliseconds(10))
            }
            try require(runtime.activePageCount == 0 && second.state == .paused, "Paused pair retains a live webpage")
            try await second.prepareToResume()
            try await observePair("second-resume-prepared", silent: true)
            second.play()
            try await observePair("second-resumed", silent: false)
            try await second.close()
            try await observePair("both-closed", silent: true)
            try await runtime.shutdown()
            try await stop(stream, queue: queue, observer: capture); capturing = false
            try await stop(defaultStream, queue: bypassQueue, observer: bypass); capturingDefault = false
            if let failure { throw failure }
            let native = capture.snapshot(), browser = bypass.snapshot()
            try require(native.errors.isEmpty && browser.errors.isEmpty, "Two-page capture failed")
            let reports = try windows.map { try $0.analyze(native.packets) }
            let defaults = try windows.map {
                try NativeRetirementAudioWindow(name: "default-" + $0.name, start: $0.start,
                    end: $0.end, expectsSilence: true).analyze(browser.packets)
            }
            let levels = Dictionary(uniqueKeysWithValues: reports.map { ($0.name, $0.stableRMS) })
            func level(_ name: String) throws -> Double {
                guard let value = levels[name] else { throw WallpaperError("Missing pair observation: \(name)") }
                return value
            }
            let firstEnergy = pow(try level("first-alone"), 2), secondEnergy = pow(try level("second-alone"), 2)
            let mixRatio = pow(try level("both-playing"), 2) / (firstEnergy + secondEnergy)
            try require((0.85...1.15).contains(mixRatio), "Two independent page outputs did not mix")
            for name in ["transition-end", "first-closed-second-playing", "second-unmuted", "second-resumed"] {
                let ratio = try level(name) / level("second-alone")
                try require((0.85...1.15).contains(ratio), "Second page output changed after first-page controls: \(name)")
            }
            let middle = native.packets.filter { $0.start >= rampStart + 0.32 && $0.end <= rampStart + 0.48 }
            try require(middle.count >= 5 && middle.first!.start <= rampStart + 0.35 && middle.last!.end >= rampStart + 0.45,
                        "Two-page transition capture coverage is insufficient")
            let middleEnergy = middle.reduce(0) { $0 + $1.energy } / Double(middle.reduce(0) { $0 + $1.samples })
            let middleRatio = middleEnergy / (firstEnergy + secondEnergy)
            try require((0.18...0.38).contains(middleRatio), "Two-page output did not follow the shared fade")
            try encoder.encode(reports).write(to: output.appendingPathComponent("native-analysis.json"))
            try encoder.encode(defaults).write(to: output.appendingPathComponent("default-analysis.json"))
            try encoder.encode(["mixEnergyRatio": mixRatio, "fadeMiddleEnergyRatio": middleRatio,
                                "rampStart": rampStart]).write(to: output.appendingPathComponent("pair-analysis.json"))
            try save()
            print("WEB_AUDIO_PAIR PASS independent-sources=1 mixing=1 shared-fade=1 close-isolation=1 gates=1 reload=1 shutdown=1 default-covered-samples=zero continuous=unverified physicalAcoustics=unverified")
        } catch {
            for surface in surfaces {
                do { try await surface.close() } catch { fputs("WEB_AUDIO_PAIR page cleanup: \(error)\n", stderr) }
            }
            do { try await runtime.shutdown() } catch { fputs("WEB_AUDIO_PAIR runtime cleanup: \(error)\n", stderr) }
            if capturing { do { try await stop(stream, queue: queue, observer: capture) } catch { fputs("WEB_AUDIO_PAIR capture cleanup: \(error)\n", stderr) } }
            if capturingDefault { do { try await stop(defaultStream, queue: bypassQueue, observer: bypass) } catch { fputs("WEB_AUDIO_PAIR default cleanup: \(error)\n", stderr) } }
            do { try save() } catch { fputs("WEB_AUDIO_PAIR evidence: \(error)\n", stderr) }
            throw error
        }
    }
}

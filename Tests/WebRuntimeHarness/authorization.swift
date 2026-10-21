import AppKit
import WallpaperCore
import WebWallpaperBridge
import Darwin

/// Separate process mode: initialize the exact signed runtime, then wait for
/// the user's authorization confirmation before any timed test is launched.
enum HarnessAuthorization {
    @MainActor static func runIfRequested() async throws -> Bool {
        guard CommandLine.arguments.dropFirst().first == "--authorize" else { return false }
        guard CommandLine.arguments.count == 5 else {
            throw WallpaperError("Authorization mode requires project, ready file and continue file")
        }
        let project = WebProjectReference(root: URL(fileURLWithPath: CommandLine.arguments[2]), entry: "index.html")
        let ready = URL(fileURLWithPath: CommandLine.arguments[3])
        let continued = URL(fileURLWithPath: CommandLine.arguments[4])
        let owner = CEFApplicationRuntime()
        let page = try owner.createPage(project: project, size: CGSize(width: 64, height: 64), scale: 1)
        let parent = getppid()
        do {
            try Data("WEB_AUTH READY executionStarted=0\n".utf8).write(to: ready, options: .withoutOverwriting)
            print("WEB_AUTH READY executionStarted=0")
            fflush(stdout)
            while !FileManager.default.fileExists(atPath: continued.path) {
                guard getppid() == parent else { throw WallpaperError("Authorization controller exited") }
                try await Task.sleep(for: .milliseconds(100))
            }
            try await close(page)
            try await owner.shutdown()
            print("WEB_AUTH COMPLETE timedTestNotRun=1")
        } catch {
            do { try await close(page); try await owner.shutdown() }
            catch { fputs("WEB_AUTH cleanup failed: \(error)\n", stderr) }
            throw error
        }
        return true
    }

    @MainActor private static func close(_ page: DWWebPage) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            page.close { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
}

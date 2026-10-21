import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO
import ScreenSaverCore
import WallpaperCore

private func emit(_ value: [String: Any]) throws {
    let bytes = try JSONSerialization.data(withJSONObject: value, options: .sortedKeys)
    try FileHandle.standardOutput.write(contentsOf: bytes + Data([10]))
}

private func expect(_ command: String) throws {
    guard readLine() == command else { throw WallpaperError("Expected harness command: \(command)") }
}

private func makePNG() throws -> Data {
    guard let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw WallpaperError("Cannot create fixture context")
    }
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
    let bytes = NSMutableData()
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil) else {
        throw WallpaperError("Cannot create PNG fixture")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw WallpaperError("Cannot finish PNG fixture") }
    return bytes as Data
}

private func publish(_ store: ScreenSaverSnapshotStore) async throws {
    let stage = try await store.beginPublication()
    let manifest: ScreenSaverManifest
    do {
        let bytes = try makePNG()
        let media = MediaItem(url: URL(fileURLWithPath: "/generated-only/fixture.png"), kind: .image, width: 1, height: 1)
        let relative = "media/\(media.id.uuidString).png"
        try bytes.write(to: stage.directory.appendingPathComponent(relative), options: .withoutOverwriting)
        var library = Library()
        library.media = [media]
        let projection = try ScreenSaverProjection(library: library, source: .media(media.id))
        let file = try ScreenSaverMediaFile(media: media, relativePath: relative, byteCount: Int64(bytes.count),
            sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        manifest = try ScreenSaverManifest(generationID: stage.id, projection: projection,
            settings: ScreenSaverSettings(source: projection.source), files: [file])
    } catch {
        let original = error
        do { try await store.abort(stage) }
        catch { throw WallpaperErrorGroup([original, error]) }
        throw original
    }
    let pointer = try await store.commit(stage, manifest: manifest, settingsRevision: UUID())
    try emit(["event": "published", "generation": pointer.generationID!.uuidString])
}

private func read(_ store: ScreenSaverSnapshotStore, mode: String) async throws {
    guard let one = try await store.acquireCurrent() else {
        guard mode == "read" else { throw WallpaperError("No current generation to hold") }
        try emit(["event": "read", "generation": NSNull()])
        return
    }
    let two = mode == "hold-two" ? try await store.acquireCurrent() : nil
    do {
        if mode == "hold-two", two == nil { throw WallpaperError("Second reader could not acquire current") }
        try emit(["event": mode == "read" ? "read" : "held", "generation": one.manifest.generationID.uuidString])
        if mode == "hold-two" {
            try expect("close-one")
            try await one.close()
            guard let two else { throw WallpaperError("Missing second lease") }
            // Read real published bytes after the sibling has closed.
            let data = try Data(contentsOf: two.directory.appendingPathComponent(two.manifest.files[0].relativePath))
            guard !data.isEmpty else { throw WallpaperError("Leased media disappeared") }
            try emit(["event": "oneClosed"])
            try expect("close-two")
        } else if mode == "hold" {
            try expect("close")
        }
        try await one.close()
        try await two?.close()
        if mode != "read" { try emit(["event": "closed"]) }
    } catch {
        var errors = [error]
        do { try await one.close() } catch { errors.append(error) }
        do { try await two?.close() } catch { errors.append(error) }
        throw WallpaperErrorGroup(errors)
    }
}

@main
private struct LeaseHarness {
    static func main() async {
        do {
            guard CommandLine.arguments.count == 3 else { throw WallpaperError("Usage: ScreenSaverLeaseHarness <root> <mode>") }
            let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            let mode = CommandLine.arguments[2]
            var operations = ScreenSaverStoreOperations.system
            if mode == "pause-register" {
                let register = operations.registerGeneration
                operations.registerGeneration = { root, id in
                    try register(root, id)
                    try emit(["event": "registered", "generation": id.uuidString])
                    try expect("commit")
                }
            }
            if mode == "pause-last-unlink" {
                operations.removeDirectory = { root, relative in
                    let directory = root.appendingPathComponent(relative, isDirectory: true)
                    for child in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                        where child.lastPathComponent != ".lease" {
                        try FileManager.default.removeItem(at: child)
                    }
                    try FileManager.default.removeItem(at: directory.appendingPathComponent(".lease"))
                    try emit(["event": "lastLeaseUnlinked", "generation": directory.lastPathComponent])
                    try expect("finish")
                    try FileManager.default.removeItem(at: directory)
                }
            }
            let store = try ScreenSaverSnapshotStore(root: root, operations: operations)
            switch mode {
            case "init":
                let identity = try await store.initialize()
                try emit(["event": "initialized", "exportID": identity.id.uuidString])
            case "publish", "pause-register": try await publish(store)
            case "read", "hold", "hold-two": try await read(store, mode: mode)
            case "stage":
                let stage = try await store.beginPublication()
                try emit(["event": "staged", "generation": stage.id.uuidString])
                try expect("abort")
                try await store.abort(stage)
                try emit(["event": "aborted"])
            case "gc", "pause-last-unlink":
                try emit(["event": "gcStarted"])
                let result = try await store.collectGarbage()
                try emit(["event": "collected", "removed": result.removed.map(\.uuidString), "retained": result.retained.map(\.uuidString)])
            case "recover":
                let ids = try await store.recoverStaging()
                try emit(["event": "recovered", "removed": ids.map(\.uuidString)])
            case "disable":
                _ = try await store.disable(settingsRevision: UUID())
                try emit(["event": "disabled", "generation": NSNull()])
            default: throw WallpaperError("Unknown harness mode: \(mode)")
            }
        } catch {
            fputs("STORAGE HARNESS FAILED: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}

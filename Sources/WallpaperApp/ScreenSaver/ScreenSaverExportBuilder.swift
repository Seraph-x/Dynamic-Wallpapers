import AVFoundation
import CryptoKit
import ImageIO
import Foundation
import ScreenSaverCore
import WallpaperCore
import WallpaperNative

struct ScreenSaverCopyDestination: Sendable {
    let root: URL
    let relativePath: String
    var url: URL { root.appendingPathComponent(relativePath) }
}

struct ScreenSaverCopyDigest: Sendable {
    let byteCount: Int64
    let sha256: String
}

struct ScreenSaverExportOperations: Sendable {
    var copy: @Sendable (ScreenSaverSourceFile, ScreenSaverCopyDestination) async throws -> ScreenSaverCopyDigest
    var inspect: @Sendable (URL) async throws -> MediaItem
    var closeSource: @Sendable (ScreenSaverSourceFile) throws -> Void
    static var system: Self {
        Self(copy: { try ScreenSaverExportBuilder.copy($0, to: $1) },
             inspect: { try await ScreenSaverExportBuilder.inspect($0) }, closeSource: { try $0.close() })
    }
}

/// Non-main-actor async work. Ownership spans actual copy and decoder completion, not cancellation requests.
struct ScreenSaverExportBuilder: Sendable {
    let operations: ScreenSaverExportOperations
    init(operations: ScreenSaverExportOperations = .system) { self.operations = operations }

    func build(projection: ScreenSaverProjection, settings: ScreenSaverSettings,
               stage: ScreenSaverStagingGeneration, exportRoot: URL) async throws -> ScreenSaverManifest {
        try projection.validateForPublication(consent: settings.consent)
        var files: [ScreenSaverMediaFile] = []
        for item in projection.media {
            try Task.checkCancellation()
            files.append(try await export(item, stage: stage, exportRoot: exportRoot))
        }
        try Task.checkCancellation()
        return try ScreenSaverManifest(generationID: stage.id, projection: projection, settings: settings, files: files)
    }

    private func export(_ item: MediaItem, stage: ScreenSaverStagingGeneration, exportRoot: URL) async throws -> ScreenSaverMediaFile {
        let input = try ScreenSaverSourceFile(item: item)
        let result: Result<ScreenSaverMediaFile, Error>
        do {
            let suffix = item.url.pathExtension.lowercased()
            let name = item.id.uuidString + (suffix.isEmpty ? "" : "." + suffix)
            let relative = "media/" + name
            try ScreenSaverPaths.validateMediaPath(relative)
            let destination = ScreenSaverCopyDestination(root: exportRoot,
                relativePath: "staging/\(stage.id.uuidString)/" + relative)
            let digest = try await operations.copy(input, destination)
            try Task.checkCancellation()
            let observed = try await operations.inspect(destination.url)
            try Task.checkCancellation()
            try input.verifyUnchanged()
            guard observed.backend == .native, observed.kind == item.kind, observed.width == item.width,
                  observed.height == item.height, observed.duration == item.duration else {
                throw ScreenSaverFailure(code: .copyMismatch(item.name))
            }
            result = .success(try ScreenSaverMediaFile(media: item, relativePath: relative,
                                                        byteCount: digest.byteCount, sha256: digest.sha256))
        } catch { result = .failure(error) }
        do { try operations.closeSource(input) }
        catch {
            var errors: [Error] = [error]
            if case .failure(let original) = result { errors.insert(original, at: 0) }
            throw ScreenSaverSourceReleaseFailure(mediaID: item.id, resource: input, errors: errors)
        }
        return try result.get()
    }

    static func copy(_ input: ScreenSaverSourceFile, to destination: ScreenSaverCopyDestination) throws -> ScreenSaverCopyDigest {
        let output = try ScreenSaverFileAccess.createFile(root: destination.root, relativePath: destination.relativePath)
        let result = Result<ScreenSaverCopyDigest, Error> {
            var hash = SHA256()
            var length: Int64 = 0
            let chunkSize = 1_048_576
            while let bytes = try input.handle.read(upToCount: chunkSize), !bytes.isEmpty {
                try Task.checkCancellation()
                try output.write(contentsOf: bytes)
                hash.update(data: bytes)
                let (next, overflow) = length.addingReportingOverflow(Int64(bytes.count))
                guard !overflow else { throw ScreenSaverFailure(code: .copyMismatch(input.url.lastPathComponent)) }
                length = next
            }
            try input.verifyUnchanged()
            try output.synchronize()
            return ScreenSaverCopyDigest(byteCount: length,
                sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
        }
        do { try output.close() }
        catch {
            if case .failure(let original) = result { throw WallpaperErrorGroup([original, error]) }
            throw error
        }
        return try result.get()
    }

    static func inspect(_ url: URL) async throws -> MediaItem {
        let item = try await NativeMediaProbe.inspect(url)
        try Task.checkCancellation()
        if item.kind == .video {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            let frame = try await generator.image(at: .zero)
            guard frame.image.width > 0, frame.image.height > 0 else {
                throw ScreenSaverFailure(code: .invalidSourceMetadata(url.lastPathComponent))
            }
        } else {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                throw ScreenSaverFailure(code: .invalidSourceMetadata(url.lastPathComponent))
            }
            // Decode every frame at verification size; NativeMediaProbe independently validates all frame delays.
            let verificationPixelSize = 64
            let decoder = try ImageDecoder(url: url, maxPixelSize: verificationPixelSize)
            for index in 0..<CGImageSourceGetCount(source) { _ = try await decoder.frame(at: index) }
        }
        try Task.checkCancellation()
        return item
    }
}

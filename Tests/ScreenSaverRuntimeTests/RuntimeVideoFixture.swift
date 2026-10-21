import AVFoundation
import XCTest
import WallpaperCore

@MainActor
enum RuntimeVideoFixture {
    static func makeVideo() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? WallpaperError("Fixture encoder did not start") }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<12 {
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw writer.error ?? WallpaperError("Fixture encoder failed") }
                try await Task.sleep(for: .milliseconds(1))
            }
            var optional: CVPixelBuffer?
            let result = CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &optional)
            XCTAssertEqual(result, kCVReturnSuccess)
            let buffer = try XCTUnwrap(optional)
            CVPixelBufferLockBaseAddress(buffer, [])
            let address = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<64 { for x in 0..<64 {
                let offset = y * stride + x * 4
                address[offset] = 255; address[offset + 1] = 220
                address[offset + 2] = UInt8(frame * 15); address[offset + 3] = 80
            } }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 12)) else {
                throw writer.error ?? WallpaperError("Fixture encoder append failed")
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? WallpaperError("Fixture encoder did not finish") }
        return url
    }
}

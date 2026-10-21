import AppKit
import AVFoundation
import SwiftUI

@MainActor
final class WallpaperMirrorView: NSView {
    let videoLayer = AVSampleBufferDisplayLayer()

    init() {
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("fullscreen-wallpaper-mirror")
        wantsLayer = true
        layer?.contentsGravity = .resizeAspectFill
        layer?.masksToBounds = true
        videoLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(videoLayer)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.frame = bounds
        CATransaction.commit()
    }

    func setUnderlay(_ image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = image
        CATransaction.commit()
    }
}

struct WallpaperMirrorPresentation: NSViewRepresentable {
    let view: WallpaperMirrorView

    func makeNSView(context: Context) -> WallpaperMirrorView { view }
    func updateNSView(_ view: WallpaperMirrorView, context: Context) {}
}

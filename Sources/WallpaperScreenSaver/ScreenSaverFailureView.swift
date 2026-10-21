import AppKit
import ScreenSaverCore

@MainActor
final class ScreenSaverFailureView: NSView {
    private let message = NSTextField(wrappingLabelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true; layer?.backgroundColor = NSColor.black.cgColor
        message.textColor = .white; message.alignment = .center
        addSubview(message)
        isHidden = true
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let horizontalInset = min(24, bounds.width / 2)
        let verticalInset = min(24, bounds.height / 2)
        message.frame = bounds.insetBy(dx: horizontalInset, dy: verticalInset)
    }

    func show(_ failure: ScreenSaverFailure) {
        message.stringValue = failure.errorDescription ?? ""
        isHidden = false
        needsLayout = true
    }
    func hide() { isHidden = true; message.stringValue = "" }
}

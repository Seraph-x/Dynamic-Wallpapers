import AppKit
import SwiftUI

@MainActor
enum AppBranding {
    static var applicationIcon: NSImage { NSApplication.shared.applicationIconImage }

    static func centerAlertHeader(in alert: NSAlert) {
        // NSAlert permits layout customization after layout(), but has no header alignment property.
        alert.layout()
        guard let contentView = alert.window.contentView,
              let iconView = contentView.subviews.compactMap({ $0 as? NSImageView }).first,
              let titleView = contentView.subviews.compactMap({ $0 as? NSTextField })
                .first(where: { $0.stringValue == alert.messageText }) else {
            preconditionFailure("NSAlert did not create the alert's icon and title views")
        }
        titleView.alignment = .center
        // The native attributed paragraph style overrides the text field's alignment.
        let originalTitle = titleView.attributedStringValue
        let centeredTitle = NSMutableAttributedString(attributedString: originalTitle)
        originalTitle.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: originalTitle.length)) { value, range, _ in
            let style = NSMutableParagraphStyle()
            if let nativeStyle = value as? NSParagraphStyle { style.setParagraphStyle(nativeStyle) }
            style.alignment = .center
            centeredTitle.addAttribute(.paragraphStyle, value: style, range: range)
        }
        titleView.attributedStringValue = centeredTitle
        let headerViews: [NSView] = [iconView, titleView]
        for view in headerViews {
            view.setFrameOrigin(NSPoint(x: contentView.bounds.midX - view.frame.width / 2, y: view.frame.minY))
        }
    }


    static let menuBarIcon: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            // Six open, interwoven bands, rather than two overlapping triangle outlines.
            // Design coordinates use a 100-point canvas; AppKit rasterizes at the display scale.
            let slope = sqrt(CGFloat(3))
            let points = [
                NSPoint(x: 0, y: 48),
                NSPoint(x: 12, y: 48 - 12 * slope),
                NSPoint(x: 6, y: 48 - 12 * slope),
                NSPoint(x: 0, y: 48 - 6 * slope),
                NSPoint(x: -19, y: 48 - 25 * slope),
                NSPoint(x: -22, y: 48 - 22 * slope)
            ]
            NSColor.black.setFill()
            for index in 0..<6 {
                let angle = CGFloat(index) * .pi / 3
                let path = NSBezierPath()
                for (pointIndex, point) in points.enumerated() {
                    let rotated = NSPoint(
                        x: rect.midX + (point.x * cos(angle) - point.y * sin(angle)) * rect.width / 100,
                        y: rect.midY + (point.x * sin(angle) + point.y * cos(angle)) * rect.height / 100)
                    if pointIndex == 0 { path.move(to: rotated) }
                    else { path.line(to: rotated) }
                }
                path.close()
                path.fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }()
}

struct AppBrandHeader: View {
    let icon: NSImage
    let product: ProductBundleMetadata

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 46, height: 46)
            Text(product.displayName)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .tracking(0.1)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(product.displayName)
        .accessibilityIdentifier("sidebar-brand")
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
    }
}

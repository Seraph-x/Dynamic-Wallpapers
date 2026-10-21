import AppKit
import SwiftUI

extension View {
    func selectionRowStyle(isSelected: Bool) -> some View {
        modifier(SelectionRowStyle(isSelected: isSelected))
    }
}

private struct SelectionRowStyle: ViewModifier {
    let isSelected: Bool
    @Environment(\.appPalette) private var palette

    func body(content: Content) -> some View {
        content
            .foregroundStyle(Color.primary)
            .background(NativeSelectionPaintOverride().frame(width: 0, height: 0))
            .listRowBackground(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? palette.selectionBackground : .clear)
                    .overlay(alignment: .leading) {
                        if isSelected {
                            Capsule().fill(palette.selectionIndicator)
                                .frame(width: 3).padding(.vertical, 6).padding(.leading, 3)
                        }
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            )
    }
}

private struct NativeSelectionPaintOverride: NSViewRepresentable {
    func makeNSView(context: Context) -> SelectionPaintView { SelectionPaintView() }
    func updateNSView(_ view: SelectionPaintView, context: Context) { view.updateRow() }
    static func dismantleNSView(_ view: SelectionPaintView, coordinator: ()) { view.restoreRow() }

    final class SelectionPaintView: NSView {
        private weak var row: NSTableRowView?
        private var originalStyle: NSTableView.SelectionHighlightStyle?

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            updateRow()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateRow()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func updateRow() {
            guard window != nil else { restoreRow(); return }
            var ancestor = superview
            while let view = ancestor, !(view is NSTableRowView) { ancestor = view.superview }
            guard let current = ancestor as? NSTableRowView else {
                assertionFailure("Selection row decoration must be hosted inside a native table row")
                return
            }
            if row !== current {
                restoreRow()
                row = current
                originalStyle = current.selectionHighlightStyle
            }
            // SwiftUI's row background sits below AppKit's selection layer.
            // Keep the native row selected; suppress only its default paint.
            current.selectionHighlightStyle = .none
            current.needsDisplay = true
        }

        func restoreRow() {
            if let row, let originalStyle, row.selectionHighlightStyle == .none {
                row.selectionHighlightStyle = originalStyle
                row.needsDisplay = true
            }
            row = nil
            originalStyle = nil
        }
    }
}

import AppKit

@MainActor
enum AccessibilityTestText {
    static func read(_ name: String, of element: AnyObject?) -> String? {
        // Obtain the Objective-C object before bridging: SwiftUI menu attributes
        // can contain NSAttributedString instead of NSString on macOS 27.
        let selector = NSSelectorFromString(name)
        guard let object = element as? NSObject, object.responds(to: selector) else { return nil }
        let value = object.perform(selector)?.takeUnretainedValue()
        if let attributed = value as? NSAttributedString { return attributed.string }
        return value as? String
    }
}

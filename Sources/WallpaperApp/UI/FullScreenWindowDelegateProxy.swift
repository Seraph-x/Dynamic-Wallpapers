import AppKit

extension Notification.Name {
    static let fullScreenWindowDidFailToEnter = Notification.Name("FullScreenWindowDidFailToEnter")
    static let fullScreenWindowDidFailToExit = Notification.Name("FullScreenWindowDidFailToExit")
    static let fullScreenWindowWillRestoreNormalFrame =
        Notification.Name("FullScreenWindowWillRestoreNormalFrame")
}

@MainActor
final class FullScreenWindowDelegateProxy: NSObject, NSWindowDelegate {
    enum Phase: Equatable {
        case idle
        case entering
        case fullScreen
        case exiting
    }

    // Objective-C's synchronous forwarding hook is nonisolated; AppKit invokes it on the main actor.
    nonisolated(unsafe) weak var originalDelegate: NSWindowDelegate?
    private(set) var phase: Phase = .idle
    private weak var targetWindow: NSWindow?
    private var normalFrame: NSRect?
    private var normalContentFrame: NSRect?
    private var fullScreenFrame: NSRect?
    private var exitChromeState: WindowChromeState?

    @MainActor
    private struct WindowChromeState {
        let toolbar: NSToolbar?
        let toolbarWasVisible: Bool?
        let titleVisibility: NSWindow.TitleVisibility
        let titlebarSeparatorStyle: NSTitlebarSeparatorStyle
        let titlebarAppearsTransparent: Bool
        let closeButtonWasHidden: Bool?
        let miniaturizeButtonWasHidden: Bool?
        let zoomButtonWasHidden: Bool?

        init(window: NSWindow) {
            toolbar = window.toolbar
            toolbarWasVisible = window.toolbar?.isVisible
            titleVisibility = window.titleVisibility
            titlebarSeparatorStyle = window.titlebarSeparatorStyle
            titlebarAppearsTransparent = window.titlebarAppearsTransparent
            closeButtonWasHidden = window.standardWindowButton(.closeButton)?.isHidden
            miniaturizeButtonWasHidden = window.standardWindowButton(.miniaturizeButton)?.isHidden
            zoomButtonWasHidden = window.standardWindowButton(.zoomButton)?.isHidden
        }

        func suppress(in window: NSWindow) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                toolbar?.isVisible = false
                if window.toolbar === toolbar { window.toolbar = nil }
                window.titleVisibility = .hidden
                window.titlebarSeparatorStyle = .none
                window.titlebarAppearsTransparent = true
                window.standardWindowButton(.closeButton)?.isHidden = true
                window.standardWindowButton(.miniaturizeButton)?.isHidden = true
                window.standardWindowButton(.zoomButton)?.isHidden = true
                window.contentView?.superview?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
            }
        }

        func restore(in window: NSWindow) {
            if window.toolbar == nil { window.toolbar = toolbar }
            if let toolbarWasVisible { toolbar?.isVisible = toolbarWasVisible }
            window.titleVisibility = titleVisibility
            window.titlebarSeparatorStyle = titlebarSeparatorStyle
            window.titlebarAppearsTransparent = titlebarAppearsTransparent
            if let closeButtonWasHidden {
                window.standardWindowButton(.closeButton)?.isHidden = closeButtonWasHidden
            }
            if let miniaturizeButtonWasHidden {
                window.standardWindowButton(.miniaturizeButton)?.isHidden = miniaturizeButtonWasHidden
            }
            if let zoomButtonWasHidden {
                window.standardWindowButton(.zoomButton)?.isHidden = zoomButtonWasHidden
            }
        }
    }

    init(originalDelegate: NSWindowDelegate?) {
        self.originalDelegate = originalDelegate
        super.init()
    }

    override func responds(to selector: Selector!) -> Bool {
        // NSWindow queries its delegate on the main thread; assert that contract here.
        MainActor.assumeIsolated {
            super.responds(to: selector) || originalDelegate?.responds(to: selector) == true
        }
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        MainActor.preconditionIsolated()
        guard originalDelegate?.responds(to: selector) == true else {
            return super.forwardingTarget(for: selector)
        }
        return originalDelegate
    }

    func customWindowsToEnterFullScreen(for window: NSWindow) -> [NSWindow]? {
        beginEntering(window, screenFrame: window.screen?.frame ?? window.frame)
    }

    func customWindowsToEnterFullScreen(for window: NSWindow, on screen: NSScreen) -> [NSWindow]? {
        beginEntering(window, screenFrame: screen.frame)
    }

    func window(_ window: NSWindow, startCustomAnimationToEnterFullScreenWithDuration duration: TimeInterval) {
        guard let frame = fullScreenFrame else { return }
        setFrame(frame, for: window, during: .entering)
    }

    func window(_ window: NSWindow, startCustomAnimationToEnterFullScreenOn screen: NSScreen,
                withDuration duration: TimeInterval) {
        fullScreenFrame = screen.frame
        setFrame(screen.frame, for: window, during: .entering)
    }

    func customWindowsToExitFullScreen(for window: NSWindow) -> [NSWindow]? {
        guard targetWindow === window, normalFrame != nil,
              phase == .fullScreen || phase == .entering else { return nil }
        if fullScreenFrame == nil { fullScreenFrame = window.frame }
        phase = .exiting
        let chromeState = WindowChromeState(window: window)
        exitChromeState = chromeState
        chromeState.suppress(in: window)
        return [window]
    }

    func window(_ window: NSWindow, startCustomAnimationToExitFullScreenWithDuration duration: TimeInterval) {
        guard targetWindow === window, phase == .exiting, normalFrame != nil else { return }
        // Keep the window screen-sized until its native Space has finished moving.
        // Resizing here makes the normal title bar travel with the outgoing Space.
        exitChromeState?.suppress(in: window)
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        originalDelegate?.windowDidEnterFullScreen?(notification)
        guard let window = notification.object as? NSWindow,
              targetWindow === window, phase == .entering else { return }
        phase = .fullScreen
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              targetWindow === window, phase == .exiting else {
            originalDelegate?.windowDidExitFullScreen?(notification)
            return
        }
        NotificationCenter.default.post(name: .fullScreenWindowWillRestoreNormalFrame, object: window)
        restoreExitChrome(in: window)
        if let normalFrame {
            let exitFrame = window.styleMask.contains(.fullScreen) ? normalContentFrame ?? normalFrame : normalFrame
            window.setFrame(exitFrame, display: true)
        }
        clearTransition()
        originalDelegate?.windowDidExitFullScreen?(notification)
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        originalDelegate?.windowDidFailToEnterFullScreen?(window)
        guard targetWindow === window, phase == .entering else { return }
        if let normalFrame { window.setFrame(normalFrame, display: true) }
        clearTransition()
        NotificationCenter.default.post(name: .fullScreenWindowDidFailToEnter, object: window)
    }

    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        guard targetWindow === window, phase == .exiting else {
            originalDelegate?.windowDidFailToExitFullScreen?(window)
            return
        }
        restoreExitChrome(in: window)
        if let fullScreenFrame { window.setFrame(fullScreenFrame, display: true) }
        phase = .fullScreen
        NotificationCenter.default.post(name: .fullScreenWindowDidFailToExit, object: window)
        originalDelegate?.windowDidFailToExitFullScreen?(window)
    }

    func restoreWindowChromeForDetachment(from window: NSWindow) {
        guard targetWindow === window else { return }
        restoreExitChrome(in: window)
    }

    private func beginEntering(_ window: NSWindow, screenFrame: NSRect) -> [NSWindow]? {
        guard phase == .idle else { return nil }
        targetWindow = window
        normalFrame = window.frame
        normalContentFrame = window.contentRect(forFrameRect: window.frame)
        fullScreenFrame = screenFrame
        phase = .entering
        return [window]
    }

    private func setFrame(_ frame: NSRect, for window: NSWindow, during expectedPhase: Phase) {
        guard targetWindow === window, phase == expectedPhase else { return }
        window.setFrame(frame, display: true)
    }

    private func clearTransition() {
        phase = .idle
        targetWindow = nil
        normalFrame = nil
        normalContentFrame = nil
        fullScreenFrame = nil
        exitChromeState = nil
    }

    private func restoreExitChrome(in window: NSWindow) {
        exitChromeState?.restore(in: window)
        exitChromeState = nil
    }
}

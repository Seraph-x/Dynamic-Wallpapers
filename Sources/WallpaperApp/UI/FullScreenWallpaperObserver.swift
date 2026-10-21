import AppKit
import SwiftUI
import WallpaperCore

struct FullScreenWallpaperObserver: NSViewRepresentable {
    let state: FullScreenWallpaperState
    let capture: WallpaperSnapshotCapture
    var makeMirror: WallpaperMirrorFactory?

    func makeNSView(context: Context) -> WindowView {
        WindowView(state: state, capture: capture, makeMirror: makeMirror)
    }
    func updateNSView(_ view: WindowView, context: Context) {
        view.capture = capture
        view.makeMirror = makeMirror
    }
    static func dismantleNSView(_ view: WindowView, coordinator: ()) { view.detach() }

    final class WindowView: NSView {
        private enum Phase {
            case normal
            case entering
            case fullScreen
            case exiting
        }

        let state: FullScreenWallpaperState
        var capture: WallpaperSnapshotCapture
        var makeMirror: WallpaperMirrorFactory?
        private weak var observedWindow: NSWindow?
        private var phase = Phase.normal
        private var activeSpace = false

        init(state: FullScreenWallpaperState, capture: @escaping WallpaperSnapshotCapture,
             makeMirror: WallpaperMirrorFactory? = nil) {
            self.state = state; self.capture = capture; self.makeMirror = makeMirror
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window !== observedWindow else { return }
            detach()
            guard let window else { return }
            observedWindow = window
            observe(window)
            if window.styleMask.contains(.fullScreen) {
                Task { @MainActor [weak self, weak window] in
                    guard let self, let window, self.observedWindow === window,
                          window.styleMask.contains(.fullScreen) else { return }
                    self.willEnter()
                    self.didEnter()
                }
            }
        }

        private func observe(_ window: NSWindow) {
            let center = NotificationCenter.default
            let notifications: [(Notification.Name, Selector)] = [
                (NSWindow.willEnterFullScreenNotification, #selector(willEnter)),
                (NSWindow.didEnterFullScreenNotification, #selector(didEnter)),
                (NSWindow.willExitFullScreenNotification, #selector(willExit)),
                (NSWindow.didExitFullScreenNotification, #selector(didExit)),
                (.fullScreenWindowWillRestoreNormalFrame, #selector(willRestoreNormalFrame)),
                (.fullScreenWindowDidFailToEnter, #selector(failedToEnter)),
                (.fullScreenWindowDidFailToExit, #selector(failedToExit)),
                (NSWindow.willCloseNotification, #selector(detach)),
                (NSWindow.didChangeScreenNotification, #selector(screenChanged)),
                (NSWindow.didChangeBackingPropertiesNotification, #selector(screenChanged)),
                (NSWindow.didChangeOcclusionStateNotification, #selector(spaceChanged)),
                (NSWindow.didBecomeKeyNotification, #selector(spaceChanged))
            ]
            for (name, selector) in notifications {
                center.addObserver(self, selector: selector, name: name, object: window)
            }
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(spaceChanged),
                name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        }

        @objc func detach() {
            NotificationCenter.default.removeObserver(self)
            NSWorkspace.shared.notificationCenter.removeObserver(self)
            observedWindow = nil
            phase = .normal
            activeSpace = false
            state.detach()
        }

        private func prepare() {
            let screen = observedWindow?.screen
            let capture = capture
            let mirror: (@MainActor () throws -> WallpaperMirrorSession)? = makeMirror.map { factory in
                {
                    guard let screen else { throw WallpaperError("无法确定全屏壁纸所在的显示器。") }
                    return try factory(screen)
                }
            }
            state.prepare(mirror: mirror) {
                guard let screen else { throw WallpaperError("无法确定全屏壁纸所在的显示器。") }
                return try await capture(screen)
            }
        }

        @objc private func willEnter() {
            phase = .entering
            activeSpace = false
            prepare()
        }
        @objc private func didEnter() {
            guard phase == .entering else { return }
            phase = .fullScreen
            activeSpace = observedWindow?.isOnActiveSpace == true
            if activeSpace { state.activate() } else { state.reset() }
        }
        @objc private func willExit() {
            guard phase == .fullScreen || phase == .entering else { return }
            phase = .exiting
        }
        @objc private func didExit() {
            guard phase == .exiting else { return }
            phase = .normal
            activeSpace = false
            state.reset()
        }
        @objc private func willRestoreNormalFrame() {
            guard phase == .exiting else { return }
            state.reset()
        }
        @objc private func failedToEnter() {
            guard phase == .entering else { return }
            phase = .normal
            activeSpace = false
            state.reset()
        }
        @objc private func failedToExit() {
            guard phase == .exiting else { return }
            phase = .fullScreen
            activeSpace = observedWindow?.isOnActiveSpace == true
            guard activeSpace else {
                state.reset()
                return
            }
            if !state.hasBackground {
                prepare()
                state.activate()
            }
        }
        @objc private func screenChanged() {
            guard phase == .fullScreen, activeSpace else { return }
            prepare()
            state.activate()
        }
        @objc private func spaceChanged() {
            guard phase == .fullScreen, let window = observedWindow else { return }
            let active = window.isOnActiveSpace
            guard active != activeSpace else { return }
            activeSpace = active
            if active {
                prepare()
                state.activate()
            } else {
                state.reset()
            }
        }
    }
}

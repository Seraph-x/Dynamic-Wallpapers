import AppKit

@MainActor
protocol ApplicationPresenting {
    var activationPolicy: NSApplication.ActivationPolicy { get }
    var isActive: Bool { get }
    func setActivationPolicy(_ policy: NSApplication.ActivationPolicy) -> Bool
    func activate(reportFailure: @escaping (Error) -> Void)
    func cancelActivation()
}

@MainActor
final class SystemApplicationPresentation: NSObject, ApplicationPresenting {
    private enum HandoffStage { case queued, yielding, returning }
    private let system: any NativeApplicationPresenting
    private let notifications: NotificationCenter
    private let workspaceNotifications: NotificationCenter
    private let handoffTimeout: TimeInterval
    private var needsMenuHandoff = false
    private var requestID: UUID?
    private var stage = HandoffStage.queued
    private var dockPID: pid_t?
    private var reportFailure: ((Error) -> Void)?

    init(system: (any NativeApplicationPresenting)? = nil,
         notifications: NotificationCenter = .default,
         workspaceNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter,
         handoffTimeout: TimeInterval = 5) {
        self.system = system ?? AppKitApplicationPresentation()
        self.notifications = notifications
        self.workspaceNotifications = workspaceNotifications
        self.handoffTimeout = handoffTimeout
        super.init()
    }
    var activationPolicy: NSApplication.ActivationPolicy { system.activationPolicy }
    var isActive: Bool { system.isActive }
    func setActivationPolicy(_ policy: NSApplication.ActivationPolicy) -> Bool {
        let previousPolicy = activationPolicy
        guard system.setActivationPolicy(policy) else { return false }
        if policy != .regular {
            needsMenuHandoff = false
            cancelActivation()
        } else if previousPolicy != .regular {
            needsMenuHandoff = system.isActive && !system.ownsMenuBar
        }
        return true
    }

    func activate(reportFailure: @escaping (Error) -> Void) {
        guard requestID == nil else { return }
        guard needsMenuHandoff, system.isActive, !system.ownsMenuBar else {
            needsMenuHandoff = false
            system.activate()
            return
        }
        let id = UUID()
        requestID = id
        stage = .queued
        self.reportFailure = reportFailure
        observeActivation()
        // Finish the window/menu action before yielding; no fixed activation delay.
        DispatchQueue.main.async { [weak self] in self?.beginHandoff(id: id) }
        DispatchQueue.main.asyncAfter(deadline: .now() + handoffTimeout) { [weak self] in
            guard let self, self.requestID == id else { return }
            self.advanceHandoff()
            if self.requestID == id { self.fail("Timed out waiting for native application menu ownership.") }
        }
    }

    func cancelActivation() {
        requestID = nil
        // Cancel this request; a later explicit open may still need the menu handoff.
        dockPID = nil
        reportFailure = nil
        notifications.removeObserver(self)
        workspaceNotifications.removeObserver(self)
    }

    private func observeActivation() {
        for name in [NSApplication.didResignActiveNotification, NSApplication.didBecomeActiveNotification] {
            notifications.addObserver(self, selector: #selector(activationChanged), name: name, object: nil)
        }
        notifications.addObserver(self, selector: #selector(applicationHidden),
                                  name: NSApplication.willHideNotification, object: nil)
        workspaceNotifications.addObserver(self, selector: #selector(workspaceActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }

    private func beginHandoff(id: UUID) {
        guard requestID == id else { return }
        guard activationPolicy == .regular, system.isActive,
              system.frontmostPID == system.processID else { cancelActivation(); return }
        guard !system.ownsMenuBar else { cancelActivation(); return }
        guard let dock = system.dockPID else { fail("System Dock is unavailable for menu activation."); return }
        dockPID = dock
        stage = .yielding
        guard system.activateDock(processID: dock) else {
            fail("System Dock rejected the menu activation handoff.")
            return
        }
    }

    @objc private func activationChanged() {
        guard let id = requestID else { return }
        // didResignActive is delivered within AppKit's deactivation stack.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.requestID == id else { return }
            self.advanceHandoff()
        }
    }

    @objc private func workspaceActivated(_ notification: Notification) {
        guard requestID != nil else { return }
        if let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
           application.processIdentifier != system.processID, application.processIdentifier != dockPID {
            // Preserve the user's activation event even if the Dock request completes before queued work.
            cancelActivation()
            return
        }
        activationChanged()
    }

    @objc private func applicationHidden() { cancelActivation() }

    private func advanceHandoff() {
        guard requestID != nil else { return }
        guard activationPolicy == .regular else { cancelActivation(); return }
        if let frontmost = system.frontmostPID, frontmost != system.processID, frontmost != dockPID {
            // A user-selected application supersedes our pending activation.
            cancelActivation()
            return
        }
        if system.isActive && system.ownsMenuBar { cancelActivation(); return }
        if stage == .yielding, !system.isActive, system.frontmostPID == dockPID {
            stage = .returning
            system.activate()
        }
    }

    private func fail(_ description: String) {
        let callback = reportFailure
        cancelActivation()
        callback?(NSError(domain: "NativeApplicationMenu", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: description]))
    }

    deinit {
        notifications.removeObserver(self)
        workspaceNotifications.removeObserver(self)
    }
}

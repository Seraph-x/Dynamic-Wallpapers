import AppKit
import Carbon

enum ApplicationLaunchOrigin: Equatable {
    case manual, login

    init(event: NSAppleEventDescriptor?) {
        // The native accessor coerces both typeType and typeEnumerated login markers.
        guard let event,
              event.eventClass == AEEventClass(kCoreEventClass),
              event.eventID == AEEventID(kAEOpenApplication),
              let marker = event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData)),
              marker.enumCodeValue == OSType(keyAELaunchedAsLogInItem) else {
            self = .manual
            return
        }
        self = .login
    }
}

@MainActor
final class MainWindowCoordinator {
    private var opener: (() -> Void)?
    private var pendingOpen = false
    private let activate: () -> Void

    init(activate: @escaping () -> Void) { self.activate = activate }

    func installOpener(_ opener: @escaping () -> Void) {
        self.opener = opener
        if pendingOpen { open() }
    }

    func open() {
        // Reopen can arrive before SwiftUI has installed the menu bar label's environment.
        guard let opener else { pendingOpen = true; return }
        pendingOpen = false
        opener()
        activate()
    }
}

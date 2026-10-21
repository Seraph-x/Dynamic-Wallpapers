import AppKit
import IOKit
import IOKit.pwr_mgt
import WallpaperCore

/// A locked session can legitimately display a screen saver. Only physical
/// display/lid and system sleep state prevent playback here.
@MainActor
public final class ScreenSaverPowerMonitor: ScreenSaverPowerObserving {
    public var onChange: ((ScreenSaverPowerState) -> Void)?
    public var onError: ((Error) -> Void)?
    private let center: NotificationCenter
    private let displaySleeping: () -> Bool
    private var state = ScreenSaverPowerState()
    private var tokens: [NSObjectProtocol] = []
    private var lid: ScreenSaverLidObservation?

    public init(displayID: @escaping () -> CGDirectDisplayID = { CGMainDisplayID() }) {
        center = NSWorkspace.shared.notificationCenter
        displaySleeping = { CGDisplayIsAsleep(displayID()) != 0 }
    }

    init(center: NotificationCenter, displaySleeping: @escaping () -> Bool) {
        self.center = center
        self.displaySleeping = displaySleeping
    }

    public func start() throws -> ScreenSaverPowerState {
        stop()
        do {
            let observation = try ScreenSaverLidObservation()
            lid = observation
            observation.onChange = { [weak self] closed in
                self?.update { $0.lidClosed = closed }
            }
            state = ScreenSaverPowerState(lidClosed: try observation.isClosed(),
                                         displaySleeping: displaySleeping())
            observe(NSWorkspace.willSleepNotification) { $0.systemSleeping = true }
            observe(NSWorkspace.didWakeNotification) { [displaySleeping] in
                $0.systemSleeping = false
                $0.displaySleeping = displaySleeping()
            }
            observe(NSWorkspace.screensDidSleepNotification) { $0.displaySleeping = true }
            observe(NSWorkspace.screensDidWakeNotification) { $0.displaySleeping = false }
            return state
        } catch {
            stop()
            throw error
        }
    }

    public func stop() {
        tokens.forEach(center.removeObserver)
        tokens.removeAll()
        lid = nil
    }

    private func observe(_ name: Notification.Name, change: @escaping (inout ScreenSaverPowerState) -> Void) {
        tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            // The observer and IOKit source run on the main thread. Revoke the
            // player before returning from a sleep notification, without a Task hop.
            MainActor.assumeIsolated { self?.update(change) }
        })
    }

    private func update(_ change: (inout ScreenSaverPowerState) -> Void) {
        change(&state)
        onChange?(state)
    }

    deinit { tokens.forEach(center.removeObserver) }
}

/// IOPMrootDomain emits clamshell changes even when another process prevents
/// system sleep. Its source must therefore be observed separately from NSWorkspace.
final class ScreenSaverLidObservation {
    // IOPM.h: iokit_family_msg(sub_iokit_powermanagement, 0x100).
    // Swift cannot import this function-like C macro.
    private static let clamshellStateChange: UInt32 = 0xe003_4100
    var onChange: (@MainActor (Bool) -> Void)?
    private var root: io_service_t = 0
    private var notification: io_object_t = 0
    private var port: IONotificationPortRef?
    private var source: CFRunLoopSource?

    init() throws {
        root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { throw WallpaperError("Screen saver power service is unavailable") }
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            throw WallpaperError("Cannot create screen saver lid notification port")
        }
        self.port = port
        guard let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() else {
            throw WallpaperError("Screen saver lid notification source is unavailable")
        }
        self.source = source
        let status = IOServiceAddInterestNotification(port, root, kIOGeneralInterest, { context, _, message, argument in
            guard let context else { return }
            let observation = Unmanaged<ScreenSaverLidObservation>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { observation.receive(message: message, argument: argument) }
        }, Unmanaged.passUnretained(self).toOpaque(), &notification)
        guard status == KERN_SUCCESS else {
            throw WallpaperError("Cannot observe screen saver lid changes: IOKit status \(status)")
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    @MainActor
    func receive(message: UInt32, argument: UnsafeMutableRawPointer?) {
        guard message == Self.clamshellStateChange else { return }
        // The argument encodes the lid state at notification time. Reading the
        // registry again could skip a close/open pair queued on the run loop.
        let closed = UInt(bitPattern: argument) & UInt(kClamshellStateBit) != 0
        onChange?(closed)
    }

    func isClosed() throws -> Bool {
        guard let value = IORegistryEntryCreateCFProperty(root, kAppleClamshellStateKey as CFString,
                                                         kCFAllocatorDefault, 0)?.takeRetainedValue() else {
            // Desktop Macs do not publish a clamshell property because they have no lid.
            return false
        }
        guard CFGetTypeID(value) == CFBooleanGetTypeID() else {
            throw WallpaperError("Screen saver lid state has an invalid IOKit value")
        }
        return CFBooleanGetValue((value as! CFBoolean))
    }

    deinit {
        if notification != 0 { IOObjectRelease(notification) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let port { IONotificationPortDestroy(port) }
        if root != 0 { IOObjectRelease(root) }
    }
}

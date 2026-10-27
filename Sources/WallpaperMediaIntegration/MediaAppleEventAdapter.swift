import Carbon
import Foundation
import WallpaperCore

/// A synchronous, queue-confined adapter. PID addressing never launches an app.
struct MediaAppleEventAdapter {
    let source: SystemMediaSource
    let processID: pid_t
    let timeout: TimeInterval

    func authorization(request: Bool) throws -> SystemMediaReadResult? {
        let target = NSAppleEventDescriptor(processIdentifier: processID)
        guard let descriptor = target.aeDesc else { throw SystemMediaError.invalidResponse("Missing target descriptor") }
        let code = AEDeterminePermissionToAutomateTarget(descriptor, typeWildCard, typeWildCard, request)
        switch code {
        case noErr: return nil
        case -1744: return .authorizationRequired // errAEEventWouldRequireUserConsent
        case -1743: return .authorizationDenied // errAEEventNotPermitted
        case OSStatus(procNotFound): return .applicationNotRunning
        default: throw SystemMediaError.appleEvent(code: code, message: "Could not determine Automation permission")
        }
    }

    func read() throws -> SystemMediaReadResult {
        let track: NSAppleEventDescriptor
        do { track = try get(MediaAE.currentTrack) }
        catch SystemMediaError.appleEvent(code: -1728, message: _) { return .noCurrentItem }
        if track.descriptorType == typeNull || (track.descriptorType == typeType && track.typeCodeValue == MediaAE.code("msng")) {
            return .noCurrentItem
        }
        guard track.descriptorType == typeObjectSpecifier else {
            throw SystemMediaError.invalidResponse("Current track must be an object specifier")
        }
        var values: [OSType: NSAppleEventDescriptor] = [:]
        for property in [MediaAE.identity(for: source), MediaAE.name, MediaAE.artist, MediaAE.album, MediaAE.duration] {
            values[property] = try get(property, container: track)
        }
        if source == .music { values[MediaAE.albumArtist] = try get(MediaAE.albumArtist, container: track) }
        values[MediaAE.playerState] = try get(MediaAE.playerState)
        values[MediaAE.position] = try get(MediaAE.position)
        let result = try MediaSnapshotDecoder.decode(source: source, values: values)
        // Metadata reads address the returned stable track object, but timeline
        // reads address the player. Never publish a mixture across a track change.
        let current = try get(MediaAE.currentTrack)
        let identity = try get(MediaAE.identity(for: source), container: current)
        let currentID = try MediaSnapshotDecoder.text(MediaAE.identity(for: source), [MediaAE.identity(for: source): identity])
        guard currentID == result.trackID else { throw SystemMediaError.trackChangedDuringRead }
        return .current(result)
    }

    func perform(_ command: SystemMediaCommand) throws {
        _ = try send(eventClass: MediaAE.eventClass(for: source), eventID: MediaAE.eventID(for: command))
    }

    private func get(_ property: OSType, container: NSAppleEventDescriptor = .null()) throws -> NSAppleEventDescriptor {
        let specifier = NSAppleEventDescriptor.record()
        specifier.setDescriptor(NSAppleEventDescriptor(typeCode: typeProperty), forKeyword: AEKeyword(keyAEDesiredClass))
        specifier.setDescriptor(NSAppleEventDescriptor(enumCode: OSType(formPropertyID)), forKeyword: AEKeyword(keyAEKeyForm))
        specifier.setDescriptor(NSAppleEventDescriptor(typeCode: property), forKeyword: AEKeyword(keyAEKeyData))
        specifier.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        guard let object = specifier.coerce(toDescriptorType: typeObjectSpecifier) else {
            throw SystemMediaError.invalidResponse("Could not construct property object specifier")
        }
        let reply = try send(eventClass: AEEventClass(kAECoreSuite), eventID: AEEventID(kAEGetData), directObject: object)
        guard let value = reply.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) else {
            throw SystemMediaError.invalidResponse("Apple Event reply has no result")
        }
        return value
    }

    private func send(eventClass: AEEventClass, eventID: AEEventID,
                      directObject: NSAppleEventDescriptor? = nil) throws -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(eventClass: eventClass, eventID: eventID,
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: processID),
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        if let directObject { event.setParam(directObject, forKeyword: AEKeyword(keyDirectObject)) }
        let reply: NSAppleEventDescriptor
        do { reply = try event.sendEvent(options: [.waitForReply, .neverInteract], timeout: timeout) }
        catch {
            let failure = error as NSError
            throw SystemMediaError.appleEvent(code: Int32(truncatingIfNeeded: failure.code), message: failure.localizedDescription)
        }
        if let error = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber)), error.int32Value != 0 {
            let message = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorString))?.stringValue ?? "Target application rejected the event"
            throw SystemMediaError.appleEvent(code: error.int32Value, message: message)
        }
        return reply
    }
}

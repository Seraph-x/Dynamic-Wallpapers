import Carbon
import Foundation
import WallpaperCore

enum MediaSnapshotDecoder {
    static func decode(source: SystemMediaSource, values: [OSType: NSAppleEventDescriptor]) throws -> SystemMediaSnapshot {
        let stateDescriptor = try required(MediaAE.playerState, values)
        guard stateDescriptor.descriptorType == typeEnumerated else {
            throw SystemMediaError.invalidResponse("Playback state must be an enumeration")
        }
        let state: SystemMediaPlaybackState
        switch stateDescriptor.enumCodeValue {
        case MediaAE.code("kPSS"): state = .stopped
        case MediaAE.code("kPSP"): state = .playing
        case MediaAE.code("kPSp"): state = .paused
        case MediaAE.code("kPSF") where source == .music: state = .fastForwarding
        case MediaAE.code("kPSR") where source == .music: state = .rewinding
        default: throw SystemMediaError.invalidResponse("Unknown playback state")
        }
        return try SystemMediaSnapshot(source: source,
            trackID: text(MediaAE.identity(for: source), values), state: state,
            title: text(MediaAE.name, values), artist: text(MediaAE.artist, values),
            album: text(MediaAE.album, values),
            albumArtist: source == .music ? text(MediaAE.albumArtist, values) : nil,
            position: number(MediaAE.position, values),
            duration: number(MediaAE.duration, values) / (source == .spotify ? 1000 : 1))
    }

    static func text(_ key: OSType, _ values: [OSType: NSAppleEventDescriptor]) throws -> String {
        let descriptor = try required(key, values)
        guard [typeUnicodeText, typeUTF8Text, typeUTF16ExternalRepresentation, typeChar].contains(descriptor.descriptorType),
              let value = descriptor.stringValue else {
            throw SystemMediaError.invalidResponse("Metadata \(key) must be text")
        }
        return value
    }

    private static func required(_ key: OSType, _ values: [OSType: NSAppleEventDescriptor]) throws -> NSAppleEventDescriptor {
        guard let value = values[key] else { throw SystemMediaError.invalidResponse("Missing property \(key)") }
        return value
    }

    private static func number(_ key: OSType, _ values: [OSType: NSAppleEventDescriptor]) throws -> Double {
        let value = try required(key, values)
        guard [typeSInt16, typeSInt32, typeSInt64, typeIEEE32BitFloatingPoint, typeIEEE64BitFloatingPoint].contains(value.descriptorType) else {
            throw SystemMediaError.invalidResponse("Timeline \(key) must be numeric")
        }
        guard let data = value.coerce(toDescriptorType: typeIEEE64BitFloatingPoint), data.data.count == 8 else {
            throw SystemMediaError.invalidResponse("Invalid numeric descriptor")
        }
        return data.doubleValue
    }
}

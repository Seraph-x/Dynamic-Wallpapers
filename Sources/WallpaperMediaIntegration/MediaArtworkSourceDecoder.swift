import Carbon
import Foundation

enum MediaArtworkSourceDecoder {
    private static func isMissing(_ value: NSAppleEventDescriptor) -> Bool {
        value.descriptorType == typeNull || (value.descriptorType == typeType && value.typeCodeValue == MediaAE.code("msng"))
    }

    static func decodeMusic(_ value: NSAppleEventDescriptor) throws -> SystemMediaArtworkSource {
        if isMissing(value) { return .unavailable }
        // Music declares raw data as any, returning its original encoded format.
        // Reject scalar/collection descriptors; ImageIO validates the actual binary
        // format later, so a new provider image descriptor needs no format allowlist.
        let nonBinaryTypes: Set<OSType> = [typeUnicodeText, typeUTF8Text, typeChar, typeSInt16,
            typeSInt32, typeSInt64, typeUInt32, typeIEEE32BitFloatingPoint, typeIEEE64BitFloatingPoint,
            typeBoolean, typeType, typeEnumerated, typeObjectSpecifier, typeAEList, typeAERecord]
        guard !nonBinaryTypes.contains(value.descriptorType), !value.data.isEmpty else {
            throw SystemMediaError.invalidResponse("Music raw artwork is not encoded image data")
        }
        return .embedded(value.data)
    }

    static func decodeSpotify(_ value: NSAppleEventDescriptor) throws -> SystemMediaArtworkSource {
        if isMissing(value) { return .unavailable }
        guard [typeUnicodeText, typeUTF8Text, typeChar].contains(value.descriptorType),
              let text = value.stringValue else {
            throw SystemMediaError.invalidResponse("Spotify artwork URL must be text")
        }
        return text.isEmpty ? .unavailable : .remote(try SystemMediaArtworkURL(text))
    }
}

import AppKit
import Carbon

private func cc(_ value: String) -> OSType { value.utf8.reduce(0) { ($0 << 8) | OSType($1) } }

@MainActor
final class Fixture: NSObject, NSApplicationDelegate {
    private let directory: URL
    private let source: String
    private var index = 0
    private var playing = true
    private var lastMode = ""
    private var trackReads = 0
    private var receipts: [String] = []

    init(directory: URL, source: String) { self.directory = directory; self.source = source }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let manager = NSAppleEventManager.shared()
        manager.setEventHandler(self, andSelector: #selector(getData(_:reply:)),
            forEventClass: cc("core"), andEventID: cc("getd"))
        for eventClass in [source == "spotify" ? "spfy" : "hook"] {
            for eventID in ["Play", "Paus", "PlPs", "Next", "Prev"] {
                manager.setEventHandler(self, andSelector: #selector(control(_:reply:)),
                    forEventClass: cc(eventClass), andEventID: cc(eventID))
            }
        }
        do { try String(ProcessInfo.processInfo.processIdentifier).write(
            to: directory.appendingPathComponent("ready"), atomically: true, encoding: .utf8) }
        catch { fputs("FIXTURE ready error: \(error)\n", stderr); exit(1) }
    }

    private func mode() throws -> String {
        let value = try String(contentsOf: directory.appendingPathComponent("mode"), encoding: .utf8)
        if value != lastMode { trackReads = 0; lastMode = value }
        return value
    }

    private func track(_ number: Int) -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: cc(source == "spotify" ? "spTr" : "cTrk")), forKeyword: AEKeyword(keyAEDesiredClass))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: OSType(formUniqueID)), forKeyword: AEKeyword(keyAEKeyForm))
        record.setDescriptor(NSAppleEventDescriptor(string: "owned-\(number)"), forKeyword: AEKeyword(keyAEKeyData))
        record.setDescriptor(.null(), forKeyword: AEKeyword(keyAEContainer))
        return record.coerce(toDescriptorType: typeObjectSpecifier)!
    }

    @objc private func getData(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        do {
            let mode = try mode()
            guard let direct = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)),
                  direct.descriptorType == typeObjectSpecifier,
                  direct.forKeyword(AEKeyword(keyAEDesiredClass))?.typeCodeValue == typeProperty,
                  direct.forKeyword(AEKeyword(keyAEKeyForm))?.enumCodeValue == OSType(formPropertyID),
                  let key = direct.forKeyword(AEKeyword(keyAEKeyData)), key.descriptorType == typeType else {
                throw FixtureError.invalidRequest
            }
            let property = key.typeCodeValue
            if mode == "error" { fail(reply, code: -50, message: "Owned fixture explicit read error"); return }
            if mode == "timeout" { Thread.sleep(forTimeInterval: 0.5) }
            var trackIndex = index
            if let container = direct.forKeyword(AEKeyword(keyAEContainer)), container.descriptorType == typeObjectSpecifier {
                let id = container.forKeyword(AEKeyword(keyAEKeyData))?.stringValue
                guard id == "owned-0" || id == "owned-1" else { throw FixtureError.invalidRequest }
                trackIndex = id == "owned-0" ? 0 : 1
            }
            let value: NSAppleEventDescriptor
            switch property {
            case cc("pTrk"):
                trackReads += 1
                if mode == "missing" { value = .null() }
                else { value = track(mode == "track-change" && trackReads > 1 ? 1 - index : index) }
            case cc("pPlS"): value = NSAppleEventDescriptor(enumCode: cc(playing ? "kPSP" : "kPSp"))
            case cc("pPos"): value = NSAppleEventDescriptor(double: 12.5)
            case cc("pPIS") where source == "music": value = NSAppleEventDescriptor(string: "owned-\(trackIndex)")
            case cc("ID  ") where source == "spotify": value = NSAppleEventDescriptor(string: "owned-\(trackIndex)")
            case cc("pnam"): value = NSAppleEventDescriptor(string: trackIndex == 0 ? "Owned 雪 \"é🎵" : "Owned second")
            case cc("pArt"): value = NSAppleEventDescriptor(string: "Owned Artist")
            case cc("pAlb"): value = NSAppleEventDescriptor(string: "Owned Album")
            case cc("pAlA") where source == "music": value = NSAppleEventDescriptor(string: "Owned Ensemble")
            case cc("pDur"):
                value = mode == "malformed" ? NSAppleEventDescriptor(string: "invalid")
                    : NSAppleEventDescriptor(double: source == "spotify" ? 180_250 : 180.25)
            default: throw FixtureError.invalidRequest
            }
            reply.setParam(value, forKeyword: AEKeyword(keyDirectObject))
        } catch { fail(reply, code: -50, message: "Owned fixture request error: \(error)") }
    }

    @objc private func control(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        do {
            if try mode() == "transport-error" { fail(reply, code: -1708, message: "Owned fixture rejected transport"); return }
            let code = event.eventID
            switch code {
            case cc("Play"): playing = true
            case cc("Paus"): playing = false
            case cc("PlPs"): playing.toggle()
            case cc("Next"): index = 1 - index
            case cc("Prev"): index = 1 - index
            default: throw FixtureError.invalidRequest
            }
            receipts.append(String(bytes: [UInt8(code >> 24), UInt8((code >> 16) & 255), UInt8((code >> 8) & 255), UInt8(code & 255)], encoding: .ascii)!)
            try JSONSerialization.data(withJSONObject: receipts).write(to: directory.appendingPathComponent("receipts.json"), options: .atomic)
        } catch { fail(reply, code: -50, message: "Owned fixture transport error: \(error)") }
    }

    private func fail(_ reply: NSAppleEventDescriptor, code: Int32, message: String) {
        reply.setParam(NSAppleEventDescriptor(int32: code), forKeyword: AEKeyword(keyErrorNumber))
        reply.setParam(NSAppleEventDescriptor(string: message), forKeyword: AEKeyword(keyErrorString))
    }
    enum FixtureError: Error { case invalidRequest }
}

@main
struct Main {
    @MainActor static func main() {
        guard CommandLine.arguments.count == 3 else { fputs("fixture needs directory and source\n", stderr); exit(2) }
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let delegate = Fixture(directory: URL(fileURLWithPath: CommandLine.arguments[1]), source: CommandLine.arguments[2])
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

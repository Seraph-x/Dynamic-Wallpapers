import Foundation
@testable import WallpaperApp

enum ProductMetadataTestSupport {
    static let product: ProductBundleMetadata = {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try! ProductBundleMetadata(bundle: makeBundle(in: directory, information: information()))
    }()

    static var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    static func configuration() throws -> [String: Any] {
        let data = try Data(contentsOf: root.appendingPathComponent("scripts/product-configuration.json"))
        guard let document = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return document
    }

    static func information() throws -> [String: Any] {
        let document = try configuration()
        guard let application = document["application"] as? [String: String],
              let screenSaver = document["screen_saver"] as? [String: String],
              let helpers = document["cef_helpers"] as? [[String: String]],
              let target = document["target"] as? [String: String],
              let languages = document["localizations"] as? [String],
              let development = document["development_localization"] as? String,
              let version = document["version"] as? String,
              let build = document["build"] as? String else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return [
            "CFBundleIdentifier": application["bundle_identifier"]!,
            "CFBundleName": application["display_name"]!,
            "CFBundleDisplayName": application["display_name"]!,
            "CFBundleExecutable": application["executable"]!,
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build,
            "CFBundleDevelopmentRegion": development,
            "CFBundleLocalizations": languages,
            "LSMinimumSystemVersion": target["minimum_macos"]!,
            "DWApplicationBundleIdentifier": application["bundle_identifier"]!,
            "DWScreenSaverBundleIdentifier": screenSaver["bundle_identifier"]!,
            "DWScreenSaverBundleName": screenSaver["bundle_name"]!,
            "DWCEFHelpers": helpers.map { helper in
                ["role": helper["role"]!, "suffix": helper["suffix"]!,
                 "bundleIdentifier": helper["bundle_identifier"]!]
            },
        ]
    }

    static func makeBundle(in directory: URL, information: [String: Any]) throws -> Bundle {
        let app = directory.appendingPathComponent("Fixture.app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: information, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        guard let bundle = Bundle(url: app) else { throw CocoaError(.fileReadCorruptFile) }
        return bundle
    }
}

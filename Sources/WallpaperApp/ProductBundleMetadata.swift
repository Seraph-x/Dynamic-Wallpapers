import Foundation

struct ProductBundleMetadata: Equatable, Sendable {
    struct CEFHelper: Equatable, Sendable {
        let role: String
        let suffix: String
        let bundleIdentifier: String
    }

    enum MetadataError: Error, Equatable, CustomStringConvertible {
        case missingOrInvalid(String)
        case inconsistent(String)

        var description: String {
            switch self {
            case .missingOrInvalid(let key): "Missing or invalid product bundle metadata: \(key)"
            case .inconsistent(let key): "Inconsistent product bundle metadata: \(key)"
            }
        }
    }

    let applicationBundleIdentifier: String
    let displayName: String
    let executable: String
    let version: String
    let build: String
    let screenSaverBundleIdentifier: String
    let screenSaverBundleName: String
    let cefHelpers: [CEFHelper]

    init(bundle: Bundle) throws {
        guard let info = bundle.infoDictionary else {
            throw MetadataError.missingOrInvalid("Info.plist")
        }
        func required(_ key: String) throws -> String {
            guard let value = info[key] as? String, !value.isEmpty else {
                throw MetadataError.missingOrInvalid(key)
            }
            return value
        }

        let applicationIdentifier = try required("CFBundleIdentifier")
        let configuredIdentifier = try required("DWApplicationBundleIdentifier")
        guard applicationIdentifier == configuredIdentifier ||
              ApplicationPaths.isValidationIdentifier(applicationIdentifier, configured: configuredIdentifier) else {
            throw MetadataError.inconsistent("DWApplicationBundleIdentifier")
        }
        let name = try required("CFBundleDisplayName")
        guard name == (try required("CFBundleName")) else {
            throw MetadataError.inconsistent("CFBundleName")
        }
        let saverIdentifier = try required("DWScreenSaverBundleIdentifier")
        guard saverIdentifier != applicationIdentifier else {
            throw MetadataError.inconsistent("DWScreenSaverBundleIdentifier")
        }
        let saverName = try required("DWScreenSaverBundleName")
        guard saverName.hasSuffix(".saver"), saverName != ".saver",
              !saverName.contains("/"), saverName != ".", saverName != ".." else {
            throw MetadataError.missingOrInvalid("DWScreenSaverBundleName")
        }
        guard let helperDocuments = info["DWCEFHelpers"] as? [[String: String]],
              !helperDocuments.isEmpty else {
            throw MetadataError.missingOrInvalid("DWCEFHelpers")
        }
        let helpers = try helperDocuments.map { document -> CEFHelper in
            guard let role = document["role"], !role.isEmpty,
                  let suffix = document["suffix"],
                  let identifier = document["bundleIdentifier"], !identifier.isEmpty else {
                throw MetadataError.missingOrInvalid("DWCEFHelpers")
            }
            return CEFHelper(role: role, suffix: suffix, bundleIdentifier: identifier)
        }
        guard Set(helpers.map(\.role)).count == helpers.count,
              Set(helpers.map(\.bundleIdentifier)).count == helpers.count else {
            throw MetadataError.inconsistent("DWCEFHelpers")
        }
        self.applicationBundleIdentifier = applicationIdentifier
        self.displayName = name
        self.executable = try required("CFBundleExecutable")
        self.version = try required("CFBundleShortVersionString")
        self.build = try required("CFBundleVersion")
        self.screenSaverBundleIdentifier = saverIdentifier
        self.screenSaverBundleName = saverName
        self.cefHelpers = helpers
    }
}

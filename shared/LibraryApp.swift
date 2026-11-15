import Foundation

/// An app that Nimbus installed and can refresh.
struct LibraryApp: Codable, Hashable, Identifiable {
    /// Bundle ID as installed, which includes the team ID.
    var bundleID: String
    var deviceUDID: String
    var name: String
    var version: String?
    /// File name of Nimbus's own copy of the IPA.
    var ipaFile: String
    var installedAt: Date
    var expiresAt: Date?
    /// Set for apps installed from a source, so Nimbus can show their icon and offer updates.
    var sourceURL: URL?
    /// Bundle ID of the app in the source, without the team ID.
    var sourceBundleID: String?
    /// `SourceApp.versionKey` of the release that's installed.
    var sourceVersion: String?
    var iconURL: URL?
    /// File names of tweaks to build into the app when it's signed, kept beside the IPAs.
    var tweaks: [String]? = nil

    var id: String { "\(deviceUDID)/\(bundleID)" }

    var ipaURL: URL { Library.ipaFolder.appendingPathComponent(ipaFile) }

    var tweakURLs: [URL] {
        (tweaks ?? []).map { Library.ipaFolder.appendingPathComponent($0) }
    }

    /// A tweak's name as the user named the file, without the prefix Nimbus stores it under.
    static func tweakName(_ file: String) -> String {
        // tweak-<id>-<name> from the Mac, local-tweak-<id>-<name> from the device itself.
        let bare = file.hasPrefix("local-") ? String(file.dropFirst("local-".count)) : file
        let parts = bare.split(separator: "-", maxSplits: 2)
        return parts.count == 3 && parts[0] == "tweak" ? String(parts[2]) : file
    }
}

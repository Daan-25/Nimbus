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

    var id: String { "\(deviceUDID)/\(bundleID)" }

    var ipaURL: URL { Library.ipaFolder.appendingPathComponent(ipaFile) }
}

import Foundation

/// One line of output from nimbus-helper.
struct HelperEvent: Decodable, Sendable {
    let event: String
    var message: String?
    var value: Double?
    var sms: Bool?
    var unknown: Bool?
    var numbers: [TrustedNumber]?
    var selectedNumberId: Int?
    var lastError: String?
    var teams: [Team]?
    var certificates: [Certificate]?
    var devices: [Device]?
    var clientInfo: String?
    var userAgent: String?
    var index: Int?
    var count: Int?
    var bundleId: String?
    var name: String?
    var version: String?
    var expires: String?
    var apps: [DeviceApp]?
    var teamId: String?
    var appIdsUsed: Int?
    var appIdsMax: Int?
    var appIdsAvailable: Int?
    /// Expiry dates of the apps Nimbus on the device refreshed itself, by bundle ID.
    var refreshed: [String: String]?
    /// The lowest iOS version an inspected IPA runs on.
    var minimumOs: String?

    static func decode(_ line: String) -> HelperEvent? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(HelperEvent.self, from: Data(line.utf8))
    }
}

struct Device: Decodable, Hashable, Identifiable, Sendable {
    let udid: String
    let name: String
    let connection: String
    var id: String { udid }
}

/// A sideloaded app on the device, installed by Nimbus or another tool.
struct DeviceApp: Decodable, Hashable, Identifiable, Sendable {
    let bundleId: String
    let name: String
    let version: String?
    var id: String { bundleId }
}

struct TrustedNumber: Decodable, Hashable, Identifiable, Sendable {
    let id: Int
    let number: String
}

struct Team: Decodable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String?
    let type: String?
}

struct Certificate: Decodable, Hashable, Identifiable, Sendable {
    let serial: String?
    let name: String?
    let machine: String?
    let expires: String?
    var id: String { serial ?? UUID().uuidString }
}

struct TwoFactorRequest: Sendable {
    let sms: Bool
    let unknown: Bool
    let numbers: [TrustedNumber]
    let selectedNumberId: Int?
    let lastError: String?
}

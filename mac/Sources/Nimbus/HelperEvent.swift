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

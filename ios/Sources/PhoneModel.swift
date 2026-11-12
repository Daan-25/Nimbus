import Foundation
import Observation

@MainActor
@Observable
final class PhoneModel {
    enum Connection: Equatable {
        /// The Mac hasn't set Nimbus up yet.
        case noPairingFile
        case checking
        /// The device doesn't answer, which nearly always means the VPN is off.
        case unreachable
        case connected(Device)
    }

    /// The address of this device as seen through LocalDevVPN.
    static let defaultAddress = "10.7.0.1"

    var connection = Connection.checking
    /// Sideloaded apps on this device; nil until loaded.
    var apps: [DeviceApp]?
    var error: String?

    var address = UserDefaults.standard.string(forKey: "deviceAddress") ?? PhoneModel.defaultAddress {
        didSet { UserDefaults.standard.set(address, forKey: "deviceAddress") }
    }

    private var isChecking = false

    // MARK: Files from the Mac

    /// The Mac puts the pairing file and its identity here. The folder also shows up in the Files app.
    static let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    private static let pairingFile = documents.appendingPathComponent("pairing.plist")
    private static let identityFile = documents.appendingPathComponent("identity.json")

    var hasPairingFile: Bool {
        FileManager.default.fileExists(atPath: Self.pairingFile.path)
    }

    /// Copies a pairing file the user picked into place.
    func importPairingFile(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            guard (try? PropertyListSerialization.propertyList(from: data, format: nil)) is [String: Any] else {
                error = "\(url.lastPathComponent) isn't a pairing file."
                return
            }
            try data.write(to: Self.pairingFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            error = nil
            Task { await check() }
        } catch {
            self.error = "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    // MARK: Connection

    /// Looks for this device through the VPN and loads its apps.
    func check() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        guard hasPairingFile else {
            connection = .noPairingFile
            apps = nil
            return
        }
        if case .connected = connection {} else { connection = .checking }
        configure()

        do {
            guard let device = try await Engine.runOnce("devices").devices?.first else {
                connection = .unreachable
                apps = nil
                return
            }
            connection = .connected(device)
            apps = try await Engine.runOnce("apps", args: [device.udid]).apps ?? []
            error = nil
        } catch {
            connection = .unreachable
            self.error = error.localizedDescription
        }
    }

    private func configure() {
        var config: [String: Any] = [
            "local_device": [
                "address": address.trimmingCharacters(in: .whitespaces),
                "pairing_file": Self.pairingFile.path,
            ]
        ]
        // The Mac's identity, so Nimbus signs in to Apple as that Mac.
        if let data = try? Data(contentsOf: Self.identityFile),
           let identity = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            config["client_info"] = identity["client_info"]
            config["user_agent"] = identity["user_agent"]
        }
        Engine.configure(config)
    }
}

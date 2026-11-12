import Foundation
import Observation
import UIKit

/// Where Nimbus on the device keeps its files.
enum Library {
    /// The Mac copies the apps to refresh here. The folder also shows up in the Files app.
    static let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    static let ipaFolder = documents.appendingPathComponent("IPAs", isDirectory: true)
    static let file = documents.appendingPathComponent("library.json")

    /// Keys and pairing files, out of sight of the Files app.
    static let support: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nimbus", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    static let pairingFile = support.appendingPathComponent("rp_pairing.plist")
    static let identityFile = support.appendingPathComponent("identity.json")
    /// The engine's signing key and the state that identifies the Mac to Apple.
    static let storage = support.appendingPathComponent("Storage", isDirectory: true)

    static func load() -> [LibraryApp] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([LibraryApp].self, from: data)) ?? []
    }

    /// The Mac leaves new files in Documents. Moves them to where they belong, so keys don't
    /// stay where the Files app shows them.
    static func takeInHandoff() {
        let files = FileManager.default
        for (name, target) in [("rp_pairing.plist", pairingFile), ("identity.json", identityFile)] {
            let source = documents.appendingPathComponent(name)
            guard files.fileExists(atPath: source.path) else { continue }
            try? files.removeItem(at: target)
            try? files.moveItem(at: source, to: target)
        }

        // Stored values for the engine, by key.
        let signing = documents.appendingPathComponent("signing.json")
        if let data = try? Data(contentsOf: signing),
           let values = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            for (key, value) in values where !key.contains("..") {
                let target = storage.appendingPathComponent(key)
                try? files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? Data(value.utf8).write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
        }
        try? files.removeItem(at: signing)
    }
}

@MainActor
@Observable
final class PhoneModel {
    enum Connection: Equatable {
        /// The Mac hasn't set Nimbus up yet.
        case noPairingFile
        case checking
        case unreachable
        case connected(Device)
    }

    enum Phase: Equatable {
        case idle, working, done, failed
    }

    /// The address of this device as seen through LocalDevVPN. A port can follow after a colon,
    /// for a device whose pairing service doesn't listen on the usual one.
    static let defaultAddress = "10.7.0.1"
    /// How long apps signed with a free Apple ID keep working.
    static let signatureLifetime: TimeInterval = 7 * 24 * 60 * 60
    static let refreshWindow: TimeInterval = 2 * 24 * 60 * 60

    private let defaults = UserDefaults.standard

    // MARK: Connection

    var connection = Connection.checking
    /// Sideloaded apps on this device; nil until loaded.
    var deviceApps: [DeviceApp]?
    var error: String?
    /// The steps of the last connection test; nil until one ran.
    var diagnosis: [String]?
    var isDiagnosing = false

    var address = UserDefaults.standard.string(forKey: "deviceAddress") ?? PhoneModel.defaultAddress {
        didSet { defaults.set(address, forKey: "deviceAddress") }
    }

    // MARK: Account

    var appleID = UserDefaults.standard.string(forKey: "appleID") ?? "" {
        didSet { defaults.set(appleID, forKey: "appleID") }
    }
    var password = ""
    var rememberPassword = UserDefaults.standard.bool(forKey: "rememberPassword") {
        didSet {
            defaults.set(rememberPassword, forKey: "rememberPassword")
            if !rememberPassword { Keychain.delete(for: normalizedAppleID) }
        }
    }

    // MARK: Apps

    /// The apps the Mac installed on this device, with the IPAs it copied over.
    var library: [LibraryApp] = []
    /// When apps expire that this device refreshed itself, by bundle ID. The Mac's list doesn't know.
    private var refreshedUntil = UserDefaults.standard.dictionary(forKey: "refreshedUntil") as? [String: Date] ?? [:] {
        didSet { defaults.set(refreshedUntil, forKey: "refreshedUntil") }
    }

    // MARK: Progress

    var phase = Phase.idle
    var status = ""
    var progress: Double?
    var log: [String] = []
    var twoFactor: TwoFactorRequest?
    var teams: [Team]?
    var certificates: [Certificate]?

    private var jobs: [LibraryApp] = []
    private var jobsFailed = 0
    private var isChecking = false
    private var started = false
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid

    // MARK: Derived state

    var normalizedAppleID: String {
        appleID.trimmingCharacters(in: .whitespaces).lowercased()
    }

    var hasCredentials: Bool {
        !normalizedAppleID.isEmpty && !password.isEmpty
    }

    var isBusy: Bool { phase == .working }

    var hasPairingFile: Bool {
        FileManager.default.fileExists(atPath: Library.pairingFile.path)
    }

    var isConnected: Bool {
        if case .connected = connection { return true }
        return false
    }

    /// Apps Nimbus can refresh: on the Mac's list, with their IPA here, and still on the device.
    var refreshableApps: [LibraryApp] {
        library
            .filter { FileManager.default.fileExists(atPath: $0.ipaURL.path) }
            .filter { app in deviceApps?.contains { $0.bundleId == app.bundleID } ?? true }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Sideloaded apps on the device that Nimbus has no IPA for.
    var otherApps: [DeviceApp] {
        let known = Set(refreshableApps.map(\.bundleID))
        return (deviceApps ?? []).filter { !known.contains($0.bundleId) }
    }

    func expiry(of app: LibraryApp) -> Date {
        let fromMac = app.expiresAt ?? app.installedAt.addingTimeInterval(Self.signatureLifetime)
        return max(fromMac, refreshedUntil[app.bundleID] ?? .distantPast)
    }

    private func isNimbusItself(_ app: LibraryApp) -> Bool {
        app.bundleID == Bundle.main.bundleIdentifier
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        if rememberPassword, let saved = Keychain.password(for: normalizedAppleID) {
            password = saved
        }
    }

    /// Looks for this device through the VPN and loads its apps.
    func check() async {
        guard !isChecking, !isBusy else { return }
        isChecking = true
        defer { isChecking = false }

        Library.takeInHandoff()
        library = Library.load()

        guard hasPairingFile else {
            connection = .noPairingFile
            deviceApps = nil
            return
        }
        if !isConnected { connection = .checking }
        configure()

        do {
            var reason: String?
            guard let device = try await Engine.runOnce("devices", log: { reason = $0 }).devices?.first else {
                connection = .unreachable
                deviceApps = nil
                error = reason
                return
            }
            connection = .connected(device)
            deviceApps = try await Engine.runOnce("apps", args: [device.udid]).apps ?? []
            error = nil
        } catch {
            connection = .unreachable
            self.error = error.localizedDescription
        }
    }

    /// Tests the connection step by step, to find out why it doesn't work.
    func diagnose() async {
        guard !isDiagnosing, !isBusy else { return }
        isDiagnosing = true
        defer { isDiagnosing = false }
        configure()
        var lines = ["Nimbus \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")"]
        lines += await Engine.log(of: "diagnose")
        diagnosis = lines
    }

    /// Copies a remote pairing file the user picked into place.
    func importPairingFile(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            // The older lockdown kind doesn't work from the device itself.
            guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  plist["private_key"] != nil, plist["identifier"] != nil
            else {
                error = "\(url.lastPathComponent) isn't a remote pairing file."
                return
            }
            try data.write(to: Library.pairingFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            error = nil
            Task { await check() }
        } catch {
            self.error = "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private func configure() {
        let parts = address.trimmingCharacters(in: .whitespaces).split(separator: ":", maxSplits: 1)
        var device: [String: Any] = [
            "address": parts.first.map(String.init) ?? Self.defaultAddress,
            "pairing_file": Library.pairingFile.path,
        ]
        if parts.count == 2, let port = Int(parts[1]) { device["port"] = port }
        var config: [String: Any] = ["local_device": device, "storage_dir": Library.storage.path]
        // The Mac's identity, so Nimbus signs in to Apple as that Mac.
        if let data = try? Data(contentsOf: Library.identityFile),
           let identity = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            config["client_info"] = identity["client_info"]
            config["user_agent"] = identity["user_agent"]
        }
        Engine.configure(config)
    }

    // MARK: Refreshing

    func refreshAll() {
        refresh(refreshableApps)
    }

    func refresh(_ apps: [LibraryApp]) {
        guard !isBusy, !apps.isEmpty else { return }
        guard hasCredentials else {
            return fail("Enter your Apple ID and password first.")
        }
        guard isConnected else {
            return fail("Turn on LocalDevVPN first.")
        }
        // Refreshing Nimbus itself restarts it, so it goes last.
        jobs = apps.filter { !isNimbusItself($0) } + apps.filter(isNimbusItself)
        jobsFailed = 0
        phase = .working
        status = "Starting…"
        progress = nil
        log = []
        configure()

        // iOS stops apps soon after they leave the screen; this asks for a little more time.
        UIApplication.shared.isIdleTimerDisabled = true
        backgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in
            Task { @MainActor in self?.endBackgroundTask() }
        }

        let request: [String: Any] = [
            "apple_id": normalizedAppleID,
            "password": password,
            "apps": jobs.map(\.ipaURL.path),
        ]
        Task {
            let succeeded = await Engine.run("install", request: request) { event in
                Task { @MainActor in self.handle(event) }
            }
            // Let the last events arrive before deciding how it ended.
            try? await Task.sleep(for: .milliseconds(200))
            if isBusy {
                if succeeded {
                    finish()
                } else {
                    phase = .idle
                    status = "Cancelled."
                }
            }
            UIApplication.shared.isIdleTimerDisabled = false
            endBackgroundTask()
            await check()
        }
    }

    func cancel() {
        Engine.cancel()
        twoFactor = nil
        teams = nil
        certificates = nil
        if isBusy {
            phase = .idle
            status = "Cancelled."
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: Prompt replies

    func submitCode(_ code: String) {
        twoFactor = nil
        status = "Checking code…"
        Engine.reply(["code": code])
    }

    func resendCode() {
        twoFactor = nil
        Engine.reply(["action": "resend"])
    }

    func sendToDevices() {
        twoFactor = nil
        Engine.reply(["action": "devices"])
    }

    func sendSMS(to number: TrustedNumber) {
        twoFactor = nil
        Engine.reply(["action": "sms", "number_id": number.id])
    }

    func choose(_ team: Team) {
        teams = nil
        Engine.reply(["team_id": team.id])
    }

    func revoke(_ serials: [String]) {
        certificates = nil
        Engine.reply(["serials": serials])
    }

    // MARK: Engine events

    private func handle(_ event: HelperEvent) {
        guard isBusy else { return }
        switch event.event {
        case "log":
            if let message = event.message {
                log.append(message)
                if !message.hasPrefix("Signing in as") { status = message }
            }
        case "progress":
            progress = event.value
        case "two_factor":
            status = "Waiting for verification code…"
            twoFactor = TwoFactorRequest(
                sms: event.sms ?? false,
                unknown: event.unknown ?? false,
                numbers: event.numbers ?? [],
                selectedNumberId: event.selectedNumberId,
                lastError: event.lastError
            )
        case "signed_in":
            status = "Signed in."
            log.append("Signed in.")
            if rememberPassword { Keychain.save(password, for: normalizedAppleID) }
        case "select_team":
            teams = event.teams ?? []
        case "revoke_certs":
            certificates = event.certificates ?? []
        case "installing":
            if let index = event.index, jobs.indices.contains(index) {
                let app = jobs[index]
                status = "Refreshing \(app.name)…"
                // Installing Nimbus over itself ends the app before it hears how it went.
                if isNimbusItself(app) {
                    refreshedUntil[app.bundleID] = Date.now.addingTimeInterval(Self.signatureLifetime)
                }
            }
        case "installed":
            if let index = event.index, jobs.indices.contains(index) {
                let expires = event.expires.flatMap { try? Date($0, strategy: .iso8601) }
                refreshedUntil[jobs[index].bundleID] = expires ?? Date.now.addingTimeInterval(Self.signatureLifetime)
            }
        case "app_failed":
            jobsFailed += 1
            if let index = event.index, jobs.indices.contains(index) {
                let app = jobs[index]
                if isNimbusItself(app) { refreshedUntil[app.bundleID] = nil }
                let message = "\(app.name): \(event.message ?? "failed")"
                log.append(message)
                if jobs.count > 1 { status = message }
            }
        case "done":
            finish()
        case "error":
            fail(event.message ?? "Unknown error")
        default:
            break
        }
    }

    private func finish() {
        let succeeded = jobs.count - jobsFailed
        phase = jobsFailed == 0 ? .done : .failed
        progress = 1
        if jobs.count == 1 {
            status = "\(jobs[0].name) is refreshed."
        } else {
            status = jobsFailed == 0
                ? "\(succeeded) apps are refreshed."
                : "\(succeeded) of \(jobs.count) apps are refreshed. See the log for details."
        }
    }

    private func fail(_ message: String) {
        phase = .failed
        status = message
        twoFactor = nil
        teams = nil
        certificates = nil
    }
}

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

    /// Apps this device installed itself. The Mac's list is replaced whenever the Mac copies
    /// its apps over, so these are kept apart; the Mac also leaves IPAs named local-… alone.
    private static let localFile = documents.appendingPathComponent("local-library.json")

    static func loadLocal() -> [LibraryApp] {
        guard let data = try? Data(contentsOf: localFile) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([LibraryApp].self, from: data)) ?? []
    }

    static func saveLocal(_ apps: [LibraryApp]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(apps).write(to: localFile, options: .atomic)
    }

    /// Copies an IPA the user picked into Nimbus's own folder, so it can be refreshed later.
    static func importIPA(_ url: URL) throws -> String {
        try FileManager.default.createDirectory(at: ipaFolder, withIntermediateDirectories: true)
        let name = "local-\(UUID().uuidString).ipa"
        try FileManager.default.copyItem(at: url, to: ipaFolder.appendingPathComponent(name))
        return name
    }

    static func deleteIPA(_ name: String) {
        try? FileManager.default.removeItem(at: ipaFolder.appendingPathComponent(name))
    }

    /// Tells the Mac which apps this device refreshed itself and until when they work, so the
    /// Mac doesn't refresh them again. The Mac reads this file.
    static func saveRefreshed(_ expiries: [String: Date]) {
        let formatter = ISO8601DateFormatter()
        let text = expiries.mapValues { formatter.string(from: $0) }
        guard let data = try? JSONSerialization.data(withJSONObject: text, options: [.sortedKeys]) else { return }
        try? data.write(to: documents.appendingPathComponent("refreshed.json"), options: .atomic)
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
    /// Minimum time between automatic refreshes, so a problem can never cause a burst of sign-ins.
    static let autoRefreshInterval: TimeInterval = 6 * 60 * 60

    /// One model for the screen and for the background task.
    static let shared = PhoneModel()

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

    /// A free Apple ID can have this many sideloaded apps on a device at once.
    static let freeAppSlots = 3

    /// The apps the Mac installed on this device, with the IPAs it copied over.
    var library: [LibraryApp] = []
    /// The apps this device installed itself, from .ipa files.
    var localLibrary = Library.loadLocal() {
        didSet { Library.saveLocal(localLibrary) }
    }
    /// The developer team of the Apple ID, known after the first sign-in on this device.
    private var teamID = UserDefaults.standard.string(forKey: "teamID") {
        didSet { defaults.set(teamID, forKey: "teamID") }
    }
    /// When apps expire that this device refreshed itself, by bundle ID. The Mac's list doesn't know.
    private var refreshedUntil = UserDefaults.standard.dictionary(forKey: "refreshedUntil") as? [String: Date] ?? [:] {
        didSet {
            defaults.set(refreshedUntil, forKey: "refreshedUntil")
            Library.saveRefreshed(refreshedUntil)
        }
    }

    // MARK: Automatic refresh

    var autoRefresh = UserDefaults.standard.object(forKey: "autoRefresh") as? Bool ?? true {
        didSet {
            defaults.set(autoRefresh, forKey: "autoRefresh")
            if autoRefresh { Notifier.requestPermission() }
            scheduleNextRefresh()
        }
    }
    private var lastAutoRefresh: Date? = UserDefaults.standard.object(forKey: "lastAutoRefresh") as? Date {
        didSet { defaults.set(lastAutoRefresh, forKey: "lastAutoRefresh") }
    }
    /// Set while refreshing without anyone at the screen to answer a prompt.
    private var isAutomatic = false

    // MARK: Progress

    var phase = Phase.idle
    var status = ""
    var progress: Double?
    var log: [String] = []
    var twoFactor: TwoFactorRequest?
    var teams: [Team]?
    var certificates: [Certificate]?

    private var jobs: [Job] = []
    private var jobsFailed = 0

    private struct Job {
        let ipaFile: String
        let name: String
        /// Set when refreshing an app that's already known; nil for a new .ipa.
        let existing: LibraryApp?

        var ipaURL: URL { Library.ipaFolder.appendingPathComponent(ipaFile) }
    }
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

    /// The Mac's apps and this device's own. When both know an app, the newer install counts.
    private var knownApps: [LibraryApp] {
        var byBundleID: [String: LibraryApp] = [:]
        for app in library + localLibrary {
            if let other = byBundleID[app.bundleID], other.installedAt > app.installedAt { continue }
            byBundleID[app.bundleID] = app
        }
        return Array(byBundleID.values)
    }

    func isLocal(_ app: LibraryApp) -> Bool {
        localLibrary.contains { $0.ipaFile == app.ipaFile }
    }

    /// Apps on this device signed by this Apple ID; nil when that isn't known yet.
    var usedAppSlots: Int? {
        guard let teamID, let deviceApps else { return nil }
        return deviceApps.filter { $0.bundleId.contains(teamID) }.count
    }

    /// Apps Nimbus can refresh: known, with their IPA here, and still on the device.
    var refreshableApps: [LibraryApp] {
        knownApps
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

    private func isNimbusItself(_ app: LibraryApp?) -> Bool {
        app != nil && app?.bundleID == Bundle.main.bundleIdentifier
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        if rememberPassword, let saved = Keychain.password(for: normalizedAppleID) {
            password = saved
        }
        if autoRefresh { Notifier.requestPermission() }
    }

    /// Looks for this device through the VPN and loads its apps. With `refreshIfDue`, also
    /// refreshes apps that are close to expiring.
    func check(refreshIfDue: Bool = true) async {
        guard !isChecking, !isBusy else { return }
        isChecking = true
        defer { isChecking = false }

        Library.takeInHandoff()
        library = Library.load()
        dropSupersededLocalApps()

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
            scheduleNextRefresh()
            if refreshIfDue, canAutoRefresh {
                lastAutoRefresh = .now
                refresh(refreshableApps)
            }
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
        Task { await run(jobs(for: apps), automatic: false) }
    }

    private func jobs(for apps: [LibraryApp]) -> [Job] {
        // Refreshing Nimbus itself restarts it, so it goes last.
        let ordered = apps.filter { !isNimbusItself($0) } + apps.filter { isNimbusItself($0) }
        return ordered.map { Job(ipaFile: $0.ipaFile, name: $0.name, existing: $0) }
    }

    // MARK: Installing

    /// Installs an .ipa file from this device: one the user picked, or opened with Nimbus.
    func add(_ url: URL) {
        Task { await install(url) }
    }

    private func install(_ url: URL) async {
        guard !isBusy else { return }
        guard hasCredentials else {
            return fail("Enter your Apple ID and password first.")
        }
        guard isConnected else {
            return fail("Turn on LocalDevVPN first.")
        }

        let access = url.startAccessingSecurityScopedResource()
        let copied = Result { try Library.importIPA(url) }
        if access { url.stopAccessingSecurityScopedResource() }
        guard case .success(let ipaFile) = copied else {
            return fail("Couldn't read \(url.lastPathComponent).")
        }
        let ipaURL = Library.ipaFolder.appendingPathComponent(ipaFile)

        // Check the file before signing in for it.
        phase = .working
        status = "Checking \(url.lastPathComponent)…"
        progress = nil
        let info: HelperEvent
        do {
            info = try await Engine.runOnce("inspect", args: [ipaURL.path])
        } catch {
            Library.deleteIPA(ipaFile)
            return fail("\(url.lastPathComponent) isn't a valid app (.ipa) file.")
        }
        phase = .idle
        let name = info.name ?? url.deletingPathExtension().lastPathComponent

        let systemVersion = UIDevice.current.systemVersion
        if let needed = info.minimumOs, needed.compare(systemVersion, options: .numeric) == .orderedDescending {
            Library.deleteIPA(ipaFile)
            return fail("\(name) needs iOS \(needed) or later. This device has iOS \(systemVersion).")
        }
        // An app that's already installed is replaced, so it doesn't need a free slot.
        if let teamID, let used = usedAppSlots, let bundleID = info.bundleId {
            let installedID = "\(bundleID).\(teamID)"
            let alreadyInstalled = deviceApps?.contains { $0.bundleId == installedID } ?? false
            if !alreadyInstalled && used >= Self.freeAppSlots {
                Library.deleteIPA(ipaFile)
                return fail("All \(Self.freeAppSlots) app slots on this device are in use. Remove an app first.")
            }
        }

        await run([Job(ipaFile: ipaFile, name: name, existing: nil)], automatic: false)
    }

    /// Removes an app from this device, which frees its slot. Its data goes with it.
    func uninstall(bundleID: String, name: String) {
        guard !isBusy, case .connected(let device) = connection else { return }
        phase = .working
        status = "Removing \(name)…"
        progress = nil
        Task {
            do {
                _ = try await Engine.runOnce("uninstall", args: [device.udid, bundleID])
                for app in localLibrary where app.bundleID == bundleID { Library.deleteIPA(app.ipaFile) }
                localLibrary.removeAll { $0.bundleID == bundleID }
                refreshedUntil[bundleID] = nil
                phase = .done
                status = "\(name) is removed."
            } catch {
                fail(error.localizedDescription)
            }
            await check(refreshIfDue: false)
        }
    }

    /// The Mac installed a newer copy of an app this device had added itself: the Mac's counts,
    /// so the device's copy can go.
    private func dropSupersededLocalApps() {
        let superseded = localLibrary.filter { local in
            library.contains { $0.bundleID == local.bundleID && $0.installedAt > local.installedAt }
        }
        guard !superseded.isEmpty else { return }
        for app in superseded { Library.deleteIPA(app.ipaFile) }
        localLibrary.removeAll { local in superseded.contains { $0.ipaFile == local.ipaFile } }
    }

    // MARK: Automatic refresh

    /// When the first app that Nimbus can refresh expires.
    var nextExpiry: Date? {
        refreshableApps.map(expiry(of:)).min()
    }

    private var isRefreshDue: Bool {
        guard let nextExpiry else { return false }
        return nextExpiry.timeIntervalSinceNow < Self.refreshWindow
    }

    /// Every app is refreshed at once, so it takes a single sign-in.
    private var canAutoRefresh: Bool {
        guard autoRefresh, hasCredentials, isConnected, !isBusy, isRefreshDue else { return false }
        if let last = lastAutoRefresh, Date.now.timeIntervalSince(last) < Self.autoRefreshInterval { return false }
        return true
    }

    /// Plans the background refresh and the warning for when it doesn't happen.
    private func scheduleNextRefresh() {
        guard autoRefresh, let nextExpiry else {
            BackgroundRefresh.schedule(at: nil)
            Notifier.scheduleExpiryWarning(for: nil)
            return
        }
        BackgroundRefresh.schedule(at: nextExpiry.addingTimeInterval(-Self.refreshWindow))
        Notifier.scheduleExpiryWarning(for: nextExpiry)
    }

    /// Runs when iOS gives Nimbus time in the background. Returns whether there was nothing
    /// to do or the refresh worked.
    func refreshInBackground() async -> Bool {
        start()
        await check(refreshIfDue: false)
        defer { scheduleNextRefresh() }
        guard autoRefresh, isRefreshDue else { return true }
        if let last = lastAutoRefresh, Date.now.timeIntervalSince(last) < Self.autoRefreshInterval { return true }
        guard hasCredentials else {
            Notifier.send(title: "Your apps expire soon", body: "Open Nimbus and turn on Remember password, so it can refresh them on its own.")
            return false
        }
        guard isConnected else {
            Notifier.send(title: "Your apps expire soon", body: "Turn on LocalDevVPN and open Nimbus to refresh them.")
            return false
        }
        lastAutoRefresh = .now
        await run(jobs(for: refreshableApps), automatic: true)
        return phase == .done
    }

    // MARK: Running the engine

    private func run(_ jobs: [Job], automatic: Bool) async {
        guard !isBusy, !jobs.isEmpty else { return }
        guard hasCredentials else {
            return fail("Enter your Apple ID and password first.")
        }
        guard isConnected else {
            return fail("Turn on LocalDevVPN first.")
        }
        isAutomatic = automatic
        self.jobs = jobs
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
        if isAutomatic {
            isAutomatic = false
            if phase == .done {
                Notifier.send(title: "Apps refreshed", body: status)
            } else if phase == .failed {
                Notifier.send(title: "Couldn't refresh your apps", body: status)
            }
        }
        // Copies of new apps that didn't get installed aren't worth keeping.
        for job in jobs where job.existing == nil && !localLibrary.contains(where: { $0.ipaFile == job.ipaFile }) {
            Library.deleteIPA(job.ipaFile)
        }
        UIApplication.shared.isIdleTimerDisabled = false
        endBackgroundTask()
        await check(refreshIfDue: false)
    }

    /// Nobody is there to answer a prompt during an automatic refresh, so it stops and asks
    /// for the app to be opened.
    private func stopAutomaticRefresh(_ reason: String) {
        Engine.cancel()
        fail(reason)
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
        case "two_factor" where isAutomatic:
            stopAutomaticRefresh("Apple asks for a verification code. Open Nimbus and tap Refresh All to enter it.")
        case "select_team" where isAutomatic, "revoke_certs" where isAutomatic:
            stopAutomaticRefresh("Apple needs an answer from you. Open Nimbus and tap Refresh All.")
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
                let job = jobs[index]
                status = "\(job.existing == nil ? "Installing" : "Refreshing") \(job.name)…"
                // Installing Nimbus over itself ends the app before it hears how it went.
                if let app = job.existing, isNimbusItself(app) {
                    refreshedUntil[app.bundleID] = Date.now.addingTimeInterval(Self.signatureLifetime)
                }
            }
        case "installed":
            if let index = event.index, jobs.indices.contains(index) { installed(jobs[index], event) }
        case "limits":
            if let teamID = event.teamId { self.teamID = teamID }
        case "app_failed":
            jobsFailed += 1
            if let index = event.index, jobs.indices.contains(index) {
                let job = jobs[index]
                if let app = job.existing, isNimbusItself(app) { refreshedUntil[app.bundleID] = nil }
                let message = "\(job.name): \(event.message ?? "failed")"
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

    private func installed(_ job: Job, _ event: HelperEvent) {
        let expires = event.expires.flatMap { try? Date($0, strategy: .iso8601) }
            ?? Date.now.addingTimeInterval(Self.signatureLifetime)
        if let app = job.existing {
            refreshedUntil[app.bundleID] = expires
            return
        }
        // A new app from an .ipa file on this device.
        guard let bundleID = event.bundleId, case .connected(let device) = connection else { return }
        for old in localLibrary where old.bundleID == bundleID && old.ipaFile != job.ipaFile {
            Library.deleteIPA(old.ipaFile)
        }
        localLibrary.removeAll { $0.bundleID == bundleID }
        localLibrary.append(LibraryApp(
            bundleID: bundleID,
            deviceUDID: device.udid,
            name: event.name ?? job.name,
            version: event.version,
            ipaFile: job.ipaFile,
            installedAt: .now,
            expiresAt: expires
        ))
        refreshedUntil[bundleID] = expires
    }

    private func finish() {
        let succeeded = jobs.count - jobsFailed
        phase = jobsFailed == 0 ? .done : .failed
        progress = 1
        if jobs.count == 1 {
            status = "\(jobs[0].name) is \(jobs[0].existing == nil ? "installed" : "refreshed")."
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

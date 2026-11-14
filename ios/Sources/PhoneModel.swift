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
    /// Where the shared code keeps the cache of sources.
    static var folder: URL { support }
    static let pairingFile = support.appendingPathComponent("rp_pairing.plist")
    static let identityFile = support.appendingPathComponent("identity.json")
    /// The engine's signing key and the state that identifies the Mac to Apple.
    static let storage = support.appendingPathComponent("Storage", isDirectory: true)
    /// Profiles of deactivated apps, kept to activate them again.
    static let profiles = support.appendingPathComponent("Profiles", isDirectory: true)
    /// The data of archived apps, by bundle ID.
    static let archive = support.appendingPathComponent("Archive", isDirectory: true)
    /// Each app as it was signed, to put an archived app back without signing in.
    static let signed = support.appendingPathComponent("Signed", isDirectory: true)

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

    // MARK: Sources

    var sources = SourceLoader.loadCache() {
        didSet { SourceLoader.saveCache(sources) }
    }
    /// Why a source couldn't be reloaded, by source address.
    var sourceErrors: [URL: String] = [:]
    var isLoadingSources = false
    private var lastSourcesReload = Date.distantPast
    private var download: Download?
    /// Identifies the running download, so a cancelled one can't continue into an install.
    private var downloadID: UUID?

    enum SourceAppState {
        case available, installed, updateAvailable
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
        /// Set when installing an app from a source.
        var origin: Origin?

        var ipaURL: URL { Library.ipaFolder.appendingPathComponent(ipaFile) }
    }
    private var isChecking = false
    private var started = false
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid

    private struct Origin {
        let sourceURL: URL
        let bundleID: String
        let version: String?
        let iconURL: URL?
    }

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
        // Deactivated apps count too: the device counts what's installed.
        return deviceApps.filter { $0.bundleId.contains(teamID) }.count
    }

    /// False for an app that's deactivated: on the device with its data, but not usable.
    func isActive(_ bundleID: String) -> Bool {
        deviceApps?.first { $0.bundleId == bundleID }?.active != false
    }

    /// The apps a refresh of everything covers. Refreshing a deactivated app would activate
    /// it, which is for the user to decide.
    private var appsToRefresh: [LibraryApp] {
        refreshableApps.filter { isActive($0.bundleID) }
    }

    /// Apps Nimbus can refresh: known, with their IPA here, and still on the device.
    var refreshableApps: [LibraryApp] {
        knownApps
            .filter { FileManager.default.fileExists(atPath: $0.ipaURL.path) }
            .filter { app in deviceApps?.contains { $0.bundleId == app.bundleID } ?? true }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Apps that are off the device with their data kept here, ready to put back.
    var archivedApps: [LibraryApp] {
        guard let deviceApps else { return [] }
        return knownApps
            .filter { FileManager.default.fileExists(atPath: $0.ipaURL.path) }
            .filter { app in !deviceApps.contains { $0.bundleId == app.bundleID } }
            .filter { FileManager.default.fileExists(atPath: Library.archive.appendingPathComponent($0.bundleID).path) }
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
            if Date.now.timeIntervalSince(lastSourcesReload) > Self.autoRefreshInterval {
                Task { await reloadSources() }
            }
            if refreshIfDue, canAutoRefresh {
                lastAutoRefresh = .now
                refresh(appsToRefresh)
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
        var config: [String: Any] = [
            "local_device": device,
            "storage_dir": Library.storage.path,
            // The developer disk image the Mac copied over, to mount it for JIT.
            "ddi_dir": Library.documents.appendingPathComponent("DDI", isDirectory: true).path,
        ]
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
        refresh(appsToRefresh)
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

        if let problem = problem(installing: name, bundleID: info.bundleId, minimumOS: info.minimumOs) {
            Library.deleteIPA(ipaFile)
            return fail(problem)
        }

        await run([Job(ipaFile: ipaFile, name: name, existing: nil)], automatic: false)
    }

    /// Says why an app can't be installed on this device, to find out before signing in for it.
    private func problem(installing name: String, bundleID: String?, minimumOS: String?) -> String? {
        let systemVersion = UIDevice.current.systemVersion
        if let minimumOS, minimumOS.compare(systemVersion, options: .numeric) == .orderedDescending {
            return "\(name) needs iOS \(minimumOS) or later. This device has iOS \(systemVersion)."
        }
        // An app that's already installed is replaced, so it doesn't need a free slot.
        if let teamID, let used = usedAppSlots, let bundleID {
            let installedID = "\(bundleID).\(teamID)"
            let alreadyInstalled = deviceApps?.contains { $0.bundleId == installedID } ?? false
            if !alreadyInstalled && used >= Self.freeAppSlots {
                return "All \(Self.freeAppSlots) app slots on this device are in use. Remove an app first."
            }
        }
        return nil
    }

    // MARK: Sources

    func state(of app: SourceApp, in source: Source) -> SourceAppState {
        let mine = refreshableApps.first { $0.sourceBundleID == app.bundleID && $0.sourceURL == source.url }
        if let mine {
            return mine.sourceVersion == app.versionKey ? .installed : .updateAvailable
        }
        if let teamID, deviceApps?.contains(where: { $0.bundleId == "\(app.bundleID).\(teamID)" }) == true {
            return .installed
        }
        return .available
    }

    /// The page of an app that came from a source, if that source is still added.
    func sourceApp(for app: LibraryApp) -> (source: Source, app: SourceApp)? {
        guard let url = app.sourceURL, let bundleID = app.sourceBundleID,
              let source = sources.first(where: { $0.url == url }),
              let found = source.apps.first(where: { $0.bundleID == bundleID })
        else { return nil }
        return (source, found)
    }

    /// The newer release of an app that was installed from a source, if there is one.
    func update(for app: LibraryApp) -> (source: Source, app: SourceApp)? {
        guard let url = app.sourceURL, let bundleID = app.sourceBundleID,
              let source = sources.first(where: { $0.url == url }),
              let latest = source.apps.first(where: { $0.bundleID == bundleID }),
              latest.versionKey != app.sourceVersion
        else { return nil }
        return (source, latest)
    }

    /// Downloads an app from a source and installs it. Also used to update an installed app.
    func install(_ app: SourceApp, from source: Source) {
        guard !isBusy else { return }
        guard hasCredentials else {
            return fail("Enter your Apple ID and password first.")
        }
        guard isConnected else {
            return fail("Turn on LocalDevVPN first.")
        }
        if let problem = problem(installing: app.name, bundleID: app.bundleID, minimumOS: app.minOSVersion) {
            return fail(problem)
        }

        try? FileManager.default.createDirectory(at: Library.ipaFolder, withIntermediateDirectories: true)
        let ipaFile = "local-\(UUID().uuidString).ipa"
        let id = UUID()
        downloadID = id
        phase = .working
        status = "Downloading \(app.name)…"
        progress = 0
        log = []
        UIApplication.shared.isIdleTimerDisabled = true
        download = Download(
            app.downloadURL,
            to: Library.ipaFolder.appendingPathComponent(ipaFile),
            onProgress: { [weak self] in
                if self?.downloadID == id { self?.progress = $0 }
            },
            completion: { [weak self] result in
                Task { await self?.downloaded(result, id: id, ipaFile: ipaFile, app: app, source: source) }
            }
        )
    }

    private func downloaded(_ result: Result<Void, Error>, id: UUID, ipaFile: String, app: SourceApp, source: Source) async {
        let file = Library.ipaFolder.appendingPathComponent(ipaFile)
        // Cancelled while downloading.
        guard downloadID == id else { return Library.deleteIPA(ipaFile) }
        download = nil
        UIApplication.shared.isIdleTimerDisabled = false
        if case .failure(let error) = result {
            downloadID = nil
            return fail("Couldn't download \(app.name): \(error.localizedDescription)")
        }
        status = "Checking \(app.name)…"
        progress = nil
        if let expected = app.sha256 {
            let actual = await Library.sha256(of: file)
            // Cancelled while checking.
            guard downloadID == id else { return Library.deleteIPA(ipaFile) }
            guard actual == expected else {
                downloadID = nil
                Library.deleteIPA(ipaFile)
                return fail("The download of \(app.name) doesn't match the checksum in its source, so Nimbus didn't install it.")
            }
        }
        let valid = (try? await Engine.runOnce("inspect", args: [file.path])) != nil
        guard downloadID == id else { return Library.deleteIPA(ipaFile) }
        downloadID = nil
        guard valid else {
            Library.deleteIPA(ipaFile)
            return fail("The download of \(app.name) isn't a valid app (.ipa) file.")
        }
        phase = .idle
        let origin = Origin(sourceURL: source.url, bundleID: app.bundleID, version: app.versionKey, iconURL: app.iconURL)
        await run([Job(ipaFile: ipaFile, name: app.name, existing: nil, origin: origin)], automatic: false)
    }

    func addSource(_ url: URL) async throws {
        guard !sources.contains(where: { $0.url == url }) else { return }
        let source = try await SourceLoader.load(url)
        if !sources.contains(where: { $0.url == url }) { sources.append(source) }
    }

    func removeSource(_ source: Source) {
        sources.removeAll { $0.url == source.url }
        sourceErrors[source.url] = nil
    }

    func reloadSources() async {
        guard !isLoadingSources else { return }
        isLoadingSources = true
        defer { isLoadingSources = false }
        lastSourcesReload = .now
        for url in sources.map(\.url) {
            do {
                let fresh = try await SourceLoader.load(url)
                // The source can be removed while it loads.
                guard let index = sources.firstIndex(where: { $0.url == url }) else { continue }
                if sources[index] != fresh { sources[index] = fresh }
                sourceErrors[url] = nil
            } catch {
                if sources.contains(where: { $0.url == url }) { sourceErrors[url] = error.localizedDescription }
            }
        }
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

    // MARK: Archiving

    /// Archived apps that are being installed afresh and still need their data back.
    private var dataToRestore: Set<String> = []

    /// Keeps an app's data in Nimbus and takes the app off the device, which frees its slot.
    func archive(_ app: LibraryApp) {
        guard !isBusy, case .connected(let device) = connection else { return }
        phase = .working
        status = "Archiving \(app.name)…"
        progress = nil
        configure()
        Task {
            do {
                _ = try await Engine.runOnce("archive", args: [device.udid, app.bundleID, Library.archive.path])
                phase = .done
                status = "\(app.name) is archived. Its data is kept in Nimbus, and its slot is free."
            } catch {
                fail(error.localizedDescription)
            }
            await check(refreshIfDue: false)
        }
    }

    /// Puts an archived app back with its data. From the copy that was kept when it was signed
    /// that takes no sign-in; when that copy is too old, the app is signed again first.
    func restore(_ app: LibraryApp) {
        guard !isBusy, case .connected(let device) = connection else { return }
        if let used = usedAppSlots, used >= Self.freeAppSlots {
            return fail("All \(Self.freeAppSlots) app slots on this device are in use. Archive or remove an app first.")
        }
        phase = .working
        status = "Restoring \(app.name)…"
        progress = nil
        configure()
        Task {
            do {
                _ = try await Engine.runOnce(
                    "unarchive",
                    args: [device.udid, app.bundleID, Library.archive.path, Library.signed.path]
                )
                phase = .done
                status = "\(app.name) is back, with its data."
                await check(refreshIfDue: false)
            } catch {
                // No signed copy that's still good: sign it again, then put the data back.
                phase = .idle
                dataToRestore.insert(app.bundleID)
                refresh([app])
            }
        }
    }

    /// After an archived app was installed afresh, puts its data back.
    private func restoreData(of bundleID: String, on udid: String) async {
        let folder = Library.archive.appendingPathComponent(bundleID)
        // The engine runs one thing at a time, so this waits for the install to finish.
        do {
            _ = try await Engine.runOnce("restore", args: [udid, bundleID, folder.path])
            try? FileManager.default.removeItem(at: folder)
        } catch {
            log.append("Couldn't put the data of \(bundleID) back: \(error.localizedDescription)")
        }
    }

    // MARK: Deactivating

    /// Takes an app's profile off the device. The app and its data stay, but it won't open.
    /// It still counts towards the three apps a free Apple ID allows.
    func deactivate(bundleID: String, name: String) {
        guard !isBusy, case .connected(let device) = connection else { return }
        phase = .working
        status = "Deactivating \(name)…"
        progress = nil
        configure()
        Task {
            do {
                _ = try await Engine.runOnce("deactivate", args: [device.udid, bundleID, Library.profiles.path])
                phase = .done
                status = "\(name) is deactivated. It won't open until you activate it; its data is kept."
            } catch {
                fail(error.localizedDescription)
            }
            await check(refreshIfDue: false)
        }
    }

    /// Puts an app's profile back. When Nimbus has no usable profile left, refreshing the app
    /// gives it a new one, which needs the app's .ipa.
    func activate(bundleID: String, name: String) {
        guard !isBusy, case .connected(let device) = connection else { return }
        phase = .working
        status = "Activating \(name)…"
        progress = nil
        configure()
        Task {
            do {
                _ = try await Engine.runOnce("activate", args: [device.udid, bundleID, Library.profiles.path])
                phase = .done
                status = "\(name) is activated."
                await check(refreshIfDue: false)
            } catch {
                phase = .idle
                if let app = refreshableApps.first(where: { $0.bundleID == bundleID }) {
                    refresh([app])
                } else {
                    fail(error.localizedDescription)
                }
            }
        }
    }

    // MARK: JIT

    /// Starts an app with JIT enabled, by attaching to it as its debugger for a moment.
    func enableJIT(bundleID: String, name: String) {
        guard !isBusy, case .connected(let device) = connection else { return }
        jobs = []
        phase = .working
        status = "Starting \(name) with JIT…"
        progress = nil
        log = []
        configure()
        // The app comes to the front, which puts Nimbus in the background while it still
        // has to answer the app's requests. This asks iOS for the time to do that.
        backgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in
            Task { @MainActor in self?.endBackgroundTask() }
        }
        Task {
            await Engine.run("jit", args: [device.udid, bundleID]) { event in
                Task { @MainActor in self.handle(event) }
            }
            try? await Task.sleep(for: .milliseconds(200))
            if isBusy {
                phase = .idle
                status = "Cancelled."
            }
            endBackgroundTask()
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
        appsToRefresh.map(expiry(of:)).min()
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
        await run(jobs(for: appsToRefresh), automatic: true)
        return phase == .done
    }

    /// Runs when the Refresh All Apps action in Shortcuts does. Returns whether it worked and
    /// what to tell the user.
    func refreshFromShortcut(onlyWhenNeeded: Bool) async -> (succeeded: Bool, message: String) {
        start()
        guard !isBusy else { return (false, "Nimbus is already busy.") }
        await check(refreshIfDue: false)
        defer { scheduleNextRefresh() }

        guard hasCredentials else {
            return (false, "Open Nimbus, enter your Apple ID and turn on Remember password.")
        }
        guard isConnected else {
            return (false, "Nimbus can't reach this device. Turn on LocalDevVPN first.")
        }
        let apps = appsToRefresh
        guard !apps.isEmpty else {
            return (true, "Nimbus has no apps to refresh.")
        }
        if onlyWhenNeeded {
            guard isRefreshDue, let nextExpiry else {
                return (true, "Your apps are fine for now. Nothing to refresh.")
            }
            // An automation that fires often shouldn't sign in often.
            if let last = lastAutoRefresh, Date.now.timeIntervalSince(last) < Self.autoRefreshInterval {
                return (true, "Nimbus tried a short while ago. The first app expires \(nextExpiry.formatted(.relative(presentation: .named))).")
            }
        }
        lastAutoRefresh = .now
        await run(jobs(for: apps), automatic: true)
        return (phase == .done, status)
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
            "signed_cache": Library.signed.path,
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
        if download != nil { UIApplication.shared.isIdleTimerDisabled = false }
        download?.cancel()
        download = nil
        downloadID = nil
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
        case "jit":
            // The last log line says how it went.
            phase = .done
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
            // An archived app that had to be signed again still needs its data back.
            if dataToRestore.remove(app.bundleID) != nil, case .connected(let device) = connection {
                Task { await restoreData(of: app.bundleID, on: device.udid) }
            }
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
            expiresAt: expires,
            sourceURL: job.origin?.sourceURL,
            sourceBundleID: job.origin?.bundleID,
            sourceVersion: job.origin?.version,
            iconURL: job.origin?.iconURL
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

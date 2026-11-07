import AppKit
import Observation
import ServiceManagement
import UserNotifications

@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case idle, working, done, failed
    }

    /// A free Apple ID can have this many sideloaded apps on a device at once.
    static let freeAppSlots = 3
    /// Apps are refreshed automatically once they expire within this time.
    static let refreshWindow: TimeInterval = 2 * 24 * 60 * 60
    /// Minimum time between automatic refreshes, so a problem can never cause a burst of sign-ins.
    static let autoRefreshInterval: TimeInterval = 6 * 60 * 60
    /// How long apps signed with a free Apple ID keep working.
    static let signatureLifetime: TimeInterval = 7 * 24 * 60 * 60

    private let defaults = UserDefaults.standard

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
    var identity = ""
    var teamID = UserDefaults.standard.string(forKey: "teamID") {
        didSet { defaults.set(teamID, forKey: "teamID") }
    }

    // MARK: Devices and apps

    var devices: [Device] = []
    var selectedUDID: String? {
        didSet {
            if oldValue != selectedUDID {
                deviceApps = nil
                Task { await refreshDeviceApps() }
            }
        }
    }
    var library = Library.load() {
        didSet { Library.save(library) }
    }
    /// Sideloaded apps on the selected device; nil until loaded.
    var deviceApps: [DeviceApp]?

    var appIDsAvailable: Int? = UserDefaults.standard.object(forKey: "appIDsAvailable") as? Int {
        didSet { defaults.set(appIDsAvailable, forKey: "appIDsAvailable") }
    }
    var appIDsMax: Int? = UserDefaults.standard.object(forKey: "appIDsMax") as? Int {
        didSet { defaults.set(appIDsMax, forKey: "appIDsMax") }
    }

    // MARK: Settings

    var autoRefresh = UserDefaults.standard.object(forKey: "autoRefresh") as? Bool ?? true {
        didSet {
            defaults.set(autoRefresh, forKey: "autoRefresh")
            if autoRefresh { requestNotificationPermission() }
        }
    }
    var openAtLogin = SMAppService.mainApp.status == .enabled

    // MARK: Progress

    var phase = Phase.idle
    var status = ""
    var progress: Double?
    var log: [String] = []
    /// Increases whenever Nimbus needs the user, so the window can come to the front.
    var attentionRequests = 0

    var twoFactor: TwoFactorRequest?
    var teams: [Team]?
    var certificates: [Certificate]?

    /// Apple blocks sign-ins for a while after a 429. Each new attempt restarts that clock,
    /// so Nimbus holds off until the block has likely passed.
    var rateLimitedUntil: Date? = UserDefaults.standard.object(forKey: "rateLimitedUntil") as? Date {
        didSet { defaults.set(rateLimitedUntil, forKey: "rateLimitedUntil") }
    }
    private var lastAutoRefresh: Date? = UserDefaults.standard.object(forKey: "lastAutoRefresh") as? Date {
        didSet { defaults.set(lastAutoRefresh, forKey: "lastAutoRefresh") }
    }

    private var helper: Helper?
    /// The jobs of the running install, in the order they were sent to the helper.
    private var jobs: [Job] = []
    private var jobsFailed = 0
    private var isAutomatic = false
    /// The device of the running install; the picker can change while it runs.
    private var runningUDID: String?
    private var started = false

    private struct Job {
        let ipaFile: String
        let name: String
        /// Set when refreshing an app that's already in the library.
        let existing: LibraryApp?
    }

    // MARK: Derived state

    var normalizedAppleID: String {
        appleID.trimmingCharacters(in: .whitespaces).lowercased()
    }

    var selectedDevice: Device? {
        devices.first { $0.udid == selectedUDID }
    }

    var isRateLimited: Bool {
        guard let until = rateLimitedUntil else { return false }
        return until > .now
    }

    var hasCredentials: Bool {
        !normalizedAppleID.isEmpty && !password.isEmpty
    }

    var isBusy: Bool { phase == .working }

    /// Apps Nimbus installed on the selected device.
    var libraryAppsOnDevice: [LibraryApp] {
        library.filter { $0.deviceUDID == selectedUDID }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Sideloaded apps on the selected device that another tool installed.
    var otherAppsOnDevice: [DeviceApp] {
        let managed = Set(libraryAppsOnDevice.map(\.bundleID))
        return (deviceApps ?? []).filter { !managed.contains($0.bundleId) }
    }

    func isInstalled(_ app: LibraryApp) -> Bool? {
        deviceApps.map { $0.contains { $0.bundleId == app.bundleID } }
    }

    /// Apps on the selected device signed by this account. Only known for free accounts,
    /// which are the ones limited to 3 apps; Apple reports an app ID limit only for those.
    var usedAppSlots: Int? {
        guard let teamID, appIDsMax != nil, let deviceApps else { return nil }
        return deviceApps.filter { $0.bundleId.contains(teamID) }.count
    }

    var nextExpiry: Date? {
        library.map(expiry(of:)).min()
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        if autoRefresh { requestNotificationPermission() }

        if rememberPassword, let saved = Keychain.password(for: normalizedAppleID) {
            password = saved
        }
        Task {
            if let event = try? await Helper.runOnce(["client-info"]) {
                identity = event.clientInfo ?? ""
            }
        }
        Task {
            var lastAppsCheck = Date.distantPast
            while !Task.isCancelled {
                if !isBusy {
                    let previous = selectedDevice
                    await refreshDevices()
                    // Check the apps when a device appears, and every minute after that.
                    if selectedDevice != previous || Date.now.timeIntervalSince(lastAppsCheck) > 60 {
                        await refreshDeviceApps()
                        lastAppsCheck = .now
                    }
                    autoRefreshIfNeeded()
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func refreshDevices() async {
        guard let event = try? await Helper.runOnce(["devices"]) else { return }
        devices = event.devices ?? []
        if selectedDevice == nil { selectedUDID = devices.first?.udid }
    }

    func refreshDeviceApps() async {
        guard let udid = selectedUDID else { return }
        guard let event = try? await Helper.runOnce(["apps", udid]), selectedUDID == udid else { return }
        deviceApps = event.apps ?? []
    }

    // MARK: Actions

    func add(_ url: URL) {
        guard !isBusy else { return }
        guard hasCredentials else {
            return fail("Enter your Apple ID and password first.")
        }
        guard let info = IPAInfo.read(url) else {
            return fail("\(url.lastPathComponent) isn't a valid app (.ipa) file.")
        }

        // An app that's already installed is replaced, so it doesn't need a free slot.
        if let teamID, let used = usedAppSlots {
            let installedID = "\(info.bundleID).\(teamID)"
            let alreadyInstalled = deviceApps?.contains { $0.bundleId == installedID } ?? false
            if !alreadyInstalled && used >= Self.freeAppSlots {
                return fail("All \(Self.freeAppSlots) app slots on \(selectedDevice?.name ?? "your device") are in use. Remove an app first.")
            }
        }

        let ipaFile: String
        do {
            ipaFile = try Library.importIPA(url)
        } catch {
            return fail("Couldn't copy \(url.lastPathComponent): \(error.localizedDescription)")
        }
        run([Job(ipaFile: ipaFile, name: info.name, existing: nil)], automatic: false)
    }

    func refresh(_ apps: [LibraryApp], automatic: Bool = false) {
        guard !isBusy, !apps.isEmpty else { return }
        guard hasCredentials else {
            return fail("Enter your Apple ID and password first.")
        }
        run(apps.map { Job(ipaFile: $0.ipaFile, name: $0.name, existing: $0) }, automatic: automatic)
    }

    func refreshAll() {
        refresh(libraryAppsOnDevice.filter { isInstalled($0) != false })
    }

    func forget(_ app: LibraryApp) {
        library.removeAll { $0.id == app.id }
        if !library.contains(where: { $0.ipaFile == app.ipaFile }) {
            Library.deleteIPA(app.ipaFile)
        }
    }

    func uninstall(bundleID: String, name: String) {
        guard !isBusy, let udid = selectedUDID else { return }
        phase = .working
        status = "Removing \(name)…"
        progress = nil
        Task {
            do {
                _ = try await Helper.runOnce(["uninstall", udid, bundleID])
                if let app = library.first(where: { $0.bundleID == bundleID && $0.deviceUDID == udid }) {
                    forget(app)
                }
                phase = .done
                status = "\(name) is removed."
            } catch {
                fail(error.localizedDescription)
            }
            await refreshDeviceApps()
        }
    }

    func setOpenAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            status = "Couldn't change the login item: \(error.localizedDescription)"
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }

    func clearRateLimit() {
        rateLimitedUntil = nil
    }

    func cancel() {
        helper?.cancel()
        helper = nil
        twoFactor = nil
        teams = nil
        certificates = nil
        if isBusy {
            cleanUpNewIPAs()
            phase = .idle
            status = "Cancelled."
        }
    }

    // MARK: Automatic refresh

    private func autoRefreshIfNeeded() {
        guard autoRefresh, !isBusy, hasCredentials, !isRateLimited, selectedDevice != nil else { return }
        if let last = lastAutoRefresh, Date.now.timeIntervalSince(last) < Self.autoRefreshInterval {
            return
        }
        let apps = libraryAppsOnDevice.filter { isInstalled($0) == true }
        let deadline = Date.now.addingTimeInterval(Self.refreshWindow)
        // Refresh every app at once, so it takes a single sign-in.
        guard apps.contains(where: { expiry(of: $0) < deadline }) else { return }
        lastAutoRefresh = .now
        refresh(apps, automatic: true)
    }

    func expiry(of app: LibraryApp) -> Date {
        app.expiresAt ?? app.installedAt.addingTimeInterval(Self.signatureLifetime)
    }

    // MARK: Running the helper

    private func run(_ jobs: [Job], automatic: Bool) {
        guard let device = selectedDevice else {
            cleanUp(jobs)
            return fail("Connect your iPhone or iPad first.")
        }
        guard !isRateLimited else {
            cleanUp(jobs)
            return fail("Apple is limiting sign-ins. Wait until the block has passed, or choose Try anyway.")
        }
        self.jobs = jobs
        runningUDID = device.udid
        jobsFailed = 0
        isAutomatic = automatic
        phase = .working
        status = automatic ? "Refreshing apps automatically…" : "Starting…"
        progress = nil
        log = []

        do {
            let helper = try Helper(arguments: ["install"])
            self.helper = helper
            try helper.start(
                onEvent: { [weak self] in self?.handle($0) },
                onLog: { [weak self] in self?.log.append($0) },
                onExit: { [weak self] code in self?.helperExited(code) }
            )
            helper.send([
                "apple_id": normalizedAppleID,
                "password": password,
                "apps": jobs.map { Library.ipaFolder.appendingPathComponent($0.ipaFile).path },
                "udid": device.udid,
            ])
        } catch {
            fail(error.localizedDescription)
        }
    }

    // MARK: Prompt replies

    func submitCode(_ code: String) {
        twoFactor = nil
        status = "Checking code…"
        helper?.send(["code": code])
    }

    func resendCode() {
        twoFactor = nil
        helper?.send(["action": "resend"])
    }

    func sendToDevices() {
        twoFactor = nil
        helper?.send(["action": "devices"])
    }

    func sendSMS(to number: TrustedNumber) {
        twoFactor = nil
        helper?.send(["action": "sms", "number_id": number.id])
    }

    func choose(_ team: Team) {
        teams = nil
        helper?.send(["team_id": team.id])
    }

    func revoke(_ serials: [String]) {
        certificates = nil
        helper?.send(["serials": serials])
    }

    // MARK: Helper events

    private func handle(_ event: HelperEvent) {
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
            needAttention("Enter the verification code to refresh your apps.")
        case "signed_in":
            status = "Signed in."
            log.append("Signed in.")
            if rememberPassword { Keychain.save(password, for: normalizedAppleID) }
        case "select_team":
            teams = event.teams ?? []
            needAttention("Choose a developer team.")
        case "revoke_certs":
            certificates = event.certificates ?? []
            needAttention("Choose a certificate to revoke.")
        case "installing":
            if let index = event.index, jobs.indices.contains(index) {
                let verb = jobs[index].existing == nil ? "Installing" : "Refreshing"
                status = "\(verb) \(jobs[index].name)…"
            }
        case "installed":
            if let index = event.index, jobs.indices.contains(index) { installed(jobs[index], event) }
        case "app_failed":
            jobsFailed += 1
            if let index = event.index, jobs.indices.contains(index) {
                let message = "\(jobs[index].name): \(event.message ?? "failed")"
                log.append(message)
                if jobs.count > 1 { status = message }
            }
        case "limits":
            if let teamID = event.teamId { self.teamID = teamID }
            appIDsAvailable = event.appIdsAvailable
            appIDsMax = event.appIdsMax
        case "done":
            finish()
        case "error":
            fail(event.message ?? "Unknown error")
        default:
            break
        }
    }

    private func installed(_ job: Job, _ event: HelperEvent) {
        guard let bundleID = event.bundleId, let udid = runningUDID else { return }
        let expires = event.expires.flatMap { try? Date($0, strategy: .iso8601) }
        let app = LibraryApp(
            bundleID: bundleID,
            deviceUDID: udid,
            name: event.name ?? job.name,
            version: event.version,
            ipaFile: job.ipaFile,
            installedAt: .now,
            expiresAt: expires
        )
        // The app was forgotten while it was being refreshed.
        if job.existing != nil && !library.contains(where: { $0.id == app.id }) { return }
        if let old = library.firstIndex(where: { $0.id == app.id }) {
            let previousFile = library[old].ipaFile
            library[old] = app
            if previousFile != app.ipaFile && !library.contains(where: { $0.ipaFile == previousFile }) {
                Library.deleteIPA(previousFile)
            }
        } else {
            library.append(app)
        }
    }

    private func finish() {
        cleanUpNewIPAs()
        let succeeded = jobs.count - jobsFailed
        phase = jobsFailed == 0 ? .done : .failed
        progress = 1
        if jobs.count == 1 {
            let verb = jobs[0].existing == nil ? "installed" : "refreshed"
            status = "\(jobs[0].name) is \(verb)."
        } else {
            status = jobsFailed == 0
                ? "\(succeeded) apps are refreshed."
                : "\(succeeded) of \(jobs.count) apps are refreshed. See the log for details."
        }
        if isAutomatic {
            notify(title: "Apps refreshed", body: status)
            isAutomatic = false
        } else {
            NSSound(named: "Glass")?.play()
        }
        Task { await refreshDeviceApps() }
    }

    private func fail(_ message: String) {
        cleanUpNewIPAs()
        phase = .failed
        status = message
        twoFactor = nil
        teams = nil
        certificates = nil
        if message.contains("429") {
            rateLimitedUntil = Date.now.addingTimeInterval(60 * 60)
        }
        if isAutomatic {
            notify(title: "Couldn't refresh your apps", body: message)
            isAutomatic = false
        }
    }

    private func helperExited(_ code: Int32) {
        helper = nil
        if isBusy {
            fail("nimbus-helper stopped unexpectedly (exit code \(code)). See the log for details.")
        }
    }

    /// Removes IPA copies of new apps that didn't make it into the library.
    private func cleanUpNewIPAs() {
        cleanUp(jobs.filter { $0.existing == nil })
    }

    private func cleanUp(_ jobs: [Job]) {
        for job in jobs where !library.contains(where: { $0.ipaFile == job.ipaFile }) {
            Library.deleteIPA(job.ipaFile)
        }
    }

    // MARK: Attention and notifications

    private func needAttention(_ message: String) {
        attentionRequests += 1
        NSApp.activate(ignoringOtherApps: true)
        NSApp.requestUserAttention(.criticalRequest)
        if isAutomatic { notify(title: "Nimbus needs you", body: message) }
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

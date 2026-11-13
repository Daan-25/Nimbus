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
    /// Bundle ID of Nimbus for iPhone, before the team ID is added.
    static let phoneAppBundleID = "io.github.daan-25.nimbus.ios"
    /// Nimbus for iPhone, which comes inside the Mac app when it was built with it.
    static let phoneAppIPA = Bundle.main.url(forResource: "Nimbus-iOS", withExtension: "ipa")

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
                phoneManagedApps = [:]
                lastPhoneStatus = .distantPast
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

    // MARK: Sources

    var sources = SourceLoader.loadCache() {
        didSet { SourceLoader.saveCache(sources) }
    }
    /// Why a source couldn't be reloaded, by source address.
    var sourceErrors: [URL: String] = [:]
    var isLoadingSources = false
    private var lastSourcesReload = Date.distantPast

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
    private var download: Download?
    /// Identifies the running download, so a cancelled one can't continue into an install.
    private var downloadID: UUID?
    /// The jobs of the running install, in the order they were sent to the helper.
    private var jobs: [Job] = []
    private var jobsFailed = 0
    private var isAutomatic = false
    /// The device of the running install; the picker can change while it runs.
    private var runningUDID: String?
    /// Installed bundle ID of Nimbus for iPhone, when it still has to be set up after this install.
    private var phoneAppToSetUp: String?
    private var setupUDID: String?
    private var lastPhoneStatus = Date.distantPast
    /// When apps expire that Nimbus on the selected device installed and looks after itself, by bundle ID.
    var phoneManagedApps: [String: Date] = [:]
    private var started = false

    private struct Job {
        let ipaFile: String
        let name: String
        /// Set when refreshing an app that's already in the library.
        let existing: LibraryApp?
        /// Set when installing an app from a source.
        var origin: Origin?
        /// Nimbus for iPhone gets its pairing file once it's installed.
        var isPhoneApp = false
    }

    private struct Origin {
        let sourceURL: URL
        let bundleID: String
        let version: String?
        let iconURL: URL?
    }

    enum SourceAppState {
        case available, installed, updateAvailable
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
        // Deactivated apps don't count.
        return deviceApps.filter { $0.bundleId.contains(teamID) && $0.active != false }.count
    }

    /// False for an app that's deactivated: on the device with its data, but not usable.
    func isActive(_ bundleID: String) -> Bool {
        deviceApps?.first { $0.bundleId == bundleID }?.active != false
    }

    func isPhoneApp(_ app: LibraryApp) -> Bool {
        app.bundleID.hasPrefix(Self.phoneAppBundleID + ".")
    }

    /// Whether to offer Nimbus for iPhone for the selected device.
    var canInstallPhoneApp: Bool {
        Self.phoneAppIPA != nil && selectedDevice != nil && !libraryAppsOnDevice.contains {
            isPhoneApp($0) && isInstalled($0) != false
        }
    }

    var nextExpiry: Date? {
        library.map(expiry(of:)).min()
    }

    func state(of app: SourceApp, in source: Source) -> SourceAppState {
        let mine = libraryAppsOnDevice.first { $0.sourceBundleID == app.bundleID && $0.sourceURL == source.url }
        if let mine, isInstalled(mine) != false {
            return mine.sourceVersion == app.versionKey ? .installed : .updateAvailable
        }
        if let teamID, deviceApps?.contains(where: { $0.bundleId == "\(app.bundleID).\(teamID)" }) == true {
            return .installed
        }
        return .available
    }

    /// The newer release of an app that was installed from a source, if there is one.
    func update(for app: LibraryApp) -> (source: Source, app: SourceApp)? {
        guard let url = app.sourceURL, let bundleID = app.sourceBundleID, isInstalled(app) != false,
              let source = sources.first(where: { $0.url == url }),
              let latest = source.apps.first(where: { $0.bundleID == bundleID }),
              latest.versionKey != app.sourceVersion
        else { return nil }
        return (source, latest)
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
                    await learnFromPhone()
                    autoRefreshIfNeeded()
                }
                // Nimbus can run for days, so look for app updates now and then.
                if Date.now.timeIntervalSince(lastSourcesReload) > Self.autoRefreshInterval {
                    await reloadSources()
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

    /// Installs Nimbus for iPhone on the selected device and gives it its pairing file.
    func installPhoneApp() {
        guard let url = Self.phoneAppIPA else { return }
        add(url, isPhoneApp: true)
    }

    func add(_ url: URL, isPhoneApp: Bool = false) {
        guard !isBusy else { return }
        guard hasCredentials else {
            return fail("Enter your Apple ID and password first.")
        }
        guard let info = IPAInfo.read(url) else {
            return fail("\(url.lastPathComponent) isn't a valid app (.ipa) file.")
        }

        if let problem = slotProblem(for: info.bundleID) {
            return fail(problem)
        }

        let ipaFile: String
        do {
            ipaFile = try Library.importIPA(url)
        } catch {
            return fail("Couldn't copy \(url.lastPathComponent): \(error.localizedDescription)")
        }
        run([Job(ipaFile: ipaFile, name: info.name, existing: nil, isPhoneApp: isPhoneApp)], automatic: false)
    }

    /// Says why an app can't be installed when every app slot is taken.
    private func slotProblem(for bundleID: String) -> String? {
        guard let teamID, let used = usedAppSlots else { return nil }
        // An app that's already installed is replaced, so it doesn't need a free slot.
        let installedID = "\(bundleID).\(teamID)"
        let alreadyInstalled = deviceApps?.contains { $0.bundleId == installedID } ?? false
        guard !alreadyInstalled && used >= Self.freeAppSlots else { return nil }
        return "All \(Self.freeAppSlots) app slots on \(selectedDevice?.name ?? "your device") are in use. Remove an app first."
    }

    /// Downloads an app from a source and installs it. Also used to update an installed app.
    func install(_ app: SourceApp, from source: Source) {
        guard !isBusy else { return }
        guard hasCredentials else {
            return fail("Enter your Apple ID and password first.")
        }
        guard selectedDevice != nil else {
            return fail("Connect your iPhone or iPad first.")
        }
        guard !isRateLimited else {
            return fail("Apple is limiting sign-ins. Wait until the block has passed, or choose Try anyway.")
        }
        if let problem = slotProblem(for: app.bundleID) {
            return fail(problem)
        }

        let ipaFile = UUID().uuidString + ".ipa"
        let id = UUID()
        downloadID = id
        phase = .working
        status = "Downloading \(app.name)…"
        progress = 0
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
        if case .failure(let error) = result {
            downloadID = nil
            return fail("Couldn't download \(app.name): \(error.localizedDescription)")
        }
        if let expected = app.sha256 {
            status = "Checking \(app.name)…"
            progress = nil
            let actual = await Library.sha256(of: file)
            // Cancelled while checking.
            guard downloadID == id else { return Library.deleteIPA(ipaFile) }
            guard actual == expected else {
                downloadID = nil
                Library.deleteIPA(ipaFile)
                return fail("The download of \(app.name) doesn't match the checksum in its source, so Nimbus didn't install it.")
            }
        }
        downloadID = nil
        guard IPAInfo.read(file) != nil else {
            Library.deleteIPA(ipaFile)
            return fail("The download of \(app.name) isn't a valid app (.ipa) file.")
        }
        let origin = Origin(sourceURL: source.url, bundleID: app.bundleID, version: app.versionKey, iconURL: app.iconURL)
        run([Job(ipaFile: ipaFile, name: app.name, existing: nil, origin: origin)], automatic: false)
    }

    // MARK: Sources

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

    // MARK: Refreshing

    func refresh(_ apps: [LibraryApp], automatic: Bool = false) {
        guard !isBusy, !apps.isEmpty else { return }
        guard hasCredentials else {
            return fail("Enter your Apple ID and password first.")
        }
        // Nimbus for iPhone comes with this Mac app, so a refresh also brings it up to date.
        if let newest = Self.phoneAppIPA {
            for app in apps where isPhoneApp(app) {
                Library.replaceIPA(app.ipaFile, with: newest)
            }
        }
        run(apps.map { Job(ipaFile: $0.ipaFile, name: $0.name, existing: $0) }, automatic: automatic)
    }

    func refreshAll() {
        // Refreshing a deactivated app would activate it and take up a slot.
        refresh(libraryAppsOnDevice.filter { isInstalled($0) != false && isActive($0.bundleID) })
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

    /// Takes an app's profile off the device. The app and its data stay, but it won't open and
    /// no longer counts towards the three apps a free Apple ID allows.
    func deactivate(bundleID: String, name: String) {
        guard !isBusy, let udid = selectedUDID else { return }
        phase = .working
        status = "Deactivating \(name)…"
        progress = nil
        Task {
            do {
                _ = try await Helper.runOnce(["deactivate", udid, bundleID, Library.profilesFolder.path])
                phase = .done
                status = "\(name) is deactivated. Its data is kept, and a slot is free."
            } catch {
                fail(error.localizedDescription)
            }
            await refreshDeviceApps()
        }
    }

    /// Puts an app's profile back. When Nimbus has no usable profile left, refreshing the app
    /// gives it a new one, which needs the app's .ipa.
    func activate(bundleID: String, name: String) {
        guard !isBusy, let udid = selectedUDID else { return }
        if let used = usedAppSlots, used >= Self.freeAppSlots {
            return fail("All \(Self.freeAppSlots) app slots on \(selectedDevice?.name ?? "your device") are in use. Deactivate or remove an app first.")
        }
        phase = .working
        status = "Activating \(name)…"
        progress = nil
        Task {
            do {
                _ = try await Helper.runOnce(["activate", udid, bundleID, Library.profilesFolder.path])
                phase = .done
                status = "\(name) is activated."
                await refreshDeviceApps()
            } catch {
                phase = .idle
                if let app = library.first(where: { $0.bundleID == bundleID && $0.deviceUDID == udid }) {
                    refresh([app])
                } else {
                    fail(error.localizedDescription)
                }
            }
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
        download?.cancel()
        download = nil
        downloadID = nil
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

    /// Nimbus on the device refreshes apps too. Asks it which, so this Mac doesn't sign in
    /// to refresh apps that are fine.
    private func learnFromPhone() async {
        guard let udid = selectedUDID, Date.now.timeIntervalSince(lastPhoneStatus) > 10 * 60,
              let phoneApp = libraryAppsOnDevice.first(where: { isPhoneApp($0) }), isInstalled(phoneApp) != false
        else { return }
        lastPhoneStatus = .now
        guard let status = try? await Helper.runOnce(["phone-status", udid, phoneApp.bundleID]), selectedUDID == udid else { return }
        let refreshed = status.refreshed ?? [:]

        var managed: [String: Date] = [:]
        for app in status.local ?? [] {
            let dates = [app.expiresAt, refreshed[app.bundleID]].compactMap { $0.flatMap { try? Date($0, strategy: .iso8601) } }
            managed[app.bundleID] = dates.max() ?? .distantPast
        }
        phoneManagedApps = managed

        for (bundleID, text) in refreshed {
            guard let expires = try? Date(text, strategy: .iso8601),
                  let index = library.firstIndex(where: { $0.deviceUDID == udid && $0.bundleID == bundleID }),
                  expires > expiry(of: library[index])
            else { continue }
            library[index].expiresAt = expires
        }
    }

    private func autoRefreshIfNeeded() {
        guard autoRefresh, !isBusy, hasCredentials, !isRateLimited, selectedDevice != nil else { return }
        if let last = lastAutoRefresh, Date.now.timeIntervalSince(last) < Self.autoRefreshInterval {
            return
        }
        let apps = libraryAppsOnDevice.filter { isInstalled($0) == true && isActive($0.bundleID) }
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
        phoneAppToSetUp = nil
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
                onExit: { [weak self, weak helper] code in self?.helperExited(code, helper) }
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

    // MARK: JIT

    /// Starts an app on the device with JIT enabled, by attaching to it as its debugger for a moment.
    func enableJIT(bundleID: String, name: String) {
        guard !isBusy, let udid = selectedUDID else { return }
        phase = .working
        status = "Starting \(name) with JIT…"
        progress = nil
        log = []
        do {
            let helper = try Helper(arguments: ["jit", udid, bundleID])
            self.helper = helper
            try helper.start(
                onEvent: { [weak self] event in
                    switch event.event {
                    case "log":
                        if let message = event.message {
                            self?.log.append(message)
                            self?.status = message
                        }
                    case "jit":
                        // The last log line says how it went.
                        self?.phase = .done
                    case "error":
                        self?.fail(event.message ?? "Unknown error")
                    default:
                        break
                    }
                },
                onLog: { [weak self] in self?.log.append($0) },
                onExit: { [weak self, weak helper] code in self?.helperExited(code, helper) }
            )
        } catch {
            fail(error.localizedDescription)
        }
    }

    // MARK: Nimbus for iPhone

    /// Sends the pairing file again, for when Nimbus on the device lost it or it stopped working.
    func setUpPhoneApp(_ app: LibraryApp) {
        guard !isBusy else { return }
        log = []
        setUpPhoneApp(bundleID: app.bundleID, udid: app.deviceUDID)
    }

    private func setUpPhoneApp(bundleID: String, udid: String) {
        phase = .working
        status = "Setting up Nimbus on your device…"
        progress = nil
        do {
            var arguments = ["setup-phone", udid, bundleID]
            // With the Apple ID, the Mac also hands over its signing key for that account.
            if !normalizedAppleID.isEmpty { arguments.append(normalizedAppleID) }
            let helper = try Helper(arguments: arguments)
            setupUDID = udid
            self.helper = helper
            try helper.start(
                onEvent: { [weak self] in self?.handleSetup($0) },
                onLog: { [weak self] in self?.log.append($0) },
                onExit: { [weak self, weak helper] code in self?.helperExited(code, helper) }
            )
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func handleSetup(_ event: HelperEvent) {
        switch event.event {
        case "log":
            if let message = event.message {
                log.append(message)
                status = message
                if message.contains("Trust") { needAttention(message) }
            }
        case "phone_ready":
            let ready = "Nimbus is on your device. Install LocalDevVPN from the App Store there, turn it on, then open Nimbus."
            if let udid = setupUDID, syncPhone(udid: udid, then: ready) { return }
            phase = .done
            status = ready
            NSSound(named: "Glass")?.play()
        case "error":
            // The app itself is installed; only the pairing file is missing.
            fail("Nimbus is installed, but setting it up failed: \(event.message ?? "Unknown error")\n\nChoose Set Up Again from the app's menu to retry.")
        default:
            break
        }
    }

    /// Copies the apps this Mac installed on a device to Nimbus on that device, so it can
    /// refresh them without the Mac. Returns false when there's nothing to do.
    /// `finalStatus` is shown once the copy is done, or when it fails, since what came before worked.
    @discardableResult
    private func syncPhone(udid: String, then finalStatus: String) -> Bool {
        let apps = library.filter { $0.deviceUDID == udid }
        guard let phoneApp = apps.first(where: { isPhoneApp($0) }) else { return false }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(apps) else { return false }
        let files = Set(apps.map(\.ipaFile)).map {
            ["path": Library.ipaFolder.appendingPathComponent($0).path, "name": $0]
        }

        do {
            let helper = try Helper(arguments: ["sync-phone", udid, phoneApp.bundleID])
            self.helper = helper
            phase = .working
            status = "Copying your apps to Nimbus on your device…"
            progress = nil
            let finish: @MainActor (String?) -> Void = { [weak self] problem in
                guard let self, self.helper === helper else { return }
                self.helper = nil
                if let problem { self.log.append("Couldn't copy your apps to your device: \(problem)") }
                self.phase = .done
                self.progress = 1
                self.status = finalStatus
                NSSound(named: "Glass")?.play()
            }
            try helper.start(
                onEvent: { [weak self] event in
                    switch event.event {
                    case "progress": self?.progress = event.value
                    case "done": finish(nil)
                    case "error": finish(event.message ?? "Unknown error")
                    default: break
                    }
                },
                onLog: { [weak self] in self?.log.append($0) },
                onExit: { code in if code != 0 { finish("nimbus-helper stopped (exit code \(code)).") } }
            )
            helper.send(["library": String(decoding: data, as: UTF8.self), "files": files])
            return true
        } catch {
            return false
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
        // Also after a refresh, so one click brings the app, its pairing file and its signing key up to date.
        if job.isPhoneApp || job.existing.map(isPhoneApp) == true { phoneAppToSetUp = bundleID }
        let expires = event.expires.flatMap { try? Date($0, strategy: .iso8601) }
        let app = LibraryApp(
            bundleID: bundleID,
            deviceUDID: udid,
            name: event.name ?? job.name,
            version: event.version,
            ipaFile: job.ipaFile,
            installedAt: .now,
            expiresAt: expires,
            // A refresh keeps the link to the source; an .ipa the user picked has none.
            sourceURL: job.origin?.sourceURL ?? job.existing?.sourceURL,
            sourceBundleID: job.origin?.bundleID ?? job.existing?.sourceBundleID,
            sourceVersion: job.origin?.version ?? job.existing?.sourceVersion,
            iconURL: job.origin?.iconURL ?? job.existing?.iconURL
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
        if let bundleID = phoneAppToSetUp, let udid = runningUDID {
            phoneAppToSetUp = nil
            Task { await refreshDeviceApps() }
            return setUpPhoneApp(bundleID: bundleID, udid: udid)
        }
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
        Task { await refreshDeviceApps() }
        if isAutomatic {
            notify(title: "Apps refreshed", body: status)
            isAutomatic = false
        } else if let udid = runningUDID, jobsFailed == 0, syncPhone(udid: udid, then: status) {
            // The sound plays once the apps are copied.
        } else {
            NSSound(named: "Glass")?.play()
        }
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

    private func helperExited(_ code: Int32, _ exited: Helper?) {
        // Setting up Nimbus for iPhone starts a second helper before the first one has exited.
        guard exited === helper else { return }
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

import AppKit
import Observation

@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case idle, working, done, failed
    }

    var appleID = UserDefaults.standard.string(forKey: "appleID") ?? "" {
        didSet { UserDefaults.standard.set(appleID, forKey: "appleID") }
    }
    var password = ""
    var rememberPassword = UserDefaults.standard.bool(forKey: "rememberPassword") {
        didSet {
            UserDefaults.standard.set(rememberPassword, forKey: "rememberPassword")
            if !rememberPassword { Keychain.delete(for: normalizedAppleID) }
        }
    }

    var devices: [Device] = []
    var selectedUDID: String?
    var ipaURL: URL?
    var identity = ""

    var phase = Phase.idle
    var status = ""
    var progress: Double?
    var log: [String] = []

    var twoFactor: TwoFactorRequest?
    var teams: [Team]?
    var certificates: [Certificate]?

    /// Apple blocks sign-ins for a while after a 429. Each new attempt restarts that clock,
    /// so Nimbus holds off until the block has likely passed.
    var rateLimitedUntil: Date? = UserDefaults.standard.object(forKey: "rateLimitedUntil") as? Date {
        didSet { UserDefaults.standard.set(rateLimitedUntil, forKey: "rateLimitedUntil") }
    }

    private var helper: Helper?
    private var devicePolling: Task<Void, Never>?

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

    var canInstall: Bool {
        phase != .working && !normalizedAppleID.isEmpty && !password.isEmpty
            && selectedDevice != nil && ipaURL != nil && !isRateLimited
    }

    func start() {
        if rememberPassword, let saved = Keychain.password(for: normalizedAppleID) {
            password = saved
        }
        Task {
            if let event = try? await Helper.runOnce(["client-info"]) {
                identity = event.clientInfo ?? ""
            }
        }
        devicePolling = Task {
            while !Task.isCancelled {
                if phase != .working { await refreshDevices() }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func refreshDevices() async {
        guard let event = try? await Helper.runOnce(["devices"]) else { return }
        devices = event.devices ?? []
        if selectedDevice == nil { selectedUDID = devices.first?.udid }
    }

    func install() {
        guard canInstall, let ipaURL, let device = selectedDevice else { return }
        phase = .working
        status = "Starting…"
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
                "ipa": ipaURL.path,
                "udid": device.udid,
            ])
        } catch {
            fail(error.localizedDescription)
        }
    }

    func cancel() {
        helper?.cancel()
        helper = nil
        twoFactor = nil
        teams = nil
        certificates = nil
        if phase == .working {
            phase = .idle
            status = "Cancelled."
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

    func clearRateLimit() {
        rateLimitedUntil = nil
    }

    // MARK: Helper events

    private func handle(_ event: HelperEvent) {
        switch event.event {
        case "log":
            if let message = event.message {
                status = message
                log.append(message)
            }
        case "progress":
            progress = event.value
            status = "Installing…"
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
        case "done":
            phase = .done
            progress = 1
            status = "\(ipaURL?.deletingPathExtension().lastPathComponent ?? "The app") is installed on \(selectedDevice?.name ?? "your device")."
            NSSound(named: "Glass")?.play()
            NSApp.requestUserAttention(.informationalRequest)
        case "error":
            fail(event.message ?? "Unknown error")
        default:
            break
        }
    }

    private func fail(_ message: String) {
        phase = .failed
        status = message
        twoFactor = nil
        teams = nil
        certificates = nil
        if message.contains("429") {
            rateLimitedUntil = Date.now.addingTimeInterval(60 * 60)
        }
    }

    private func helperExited(_ code: Int32) {
        helper = nil
        if phase == .working {
            fail("nimbus-helper stopped unexpectedly (exit code \(code)). See the log for details.")
        }
    }
}

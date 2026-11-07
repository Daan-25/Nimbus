import SwiftUI

struct TwoFactorSheet: View {
    @Environment(AppModel.self) private var model
    let request: TwoFactorRequest
    @State private var code = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Verification code", systemImage: "lock.iphone")
                .font(.title2.bold())

            Text(request.sms
                 ? "Enter the code Apple sent by text message."
                 : "Enter the 6-digit code shown on one of your Apple devices.")
                .foregroundStyle(.secondary)

            if let error = request.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }

            TextField("123456", text: $code)
                .font(.system(.title, design: .monospaced))
                .multilineTextAlignment(.center)
                .textContentType(.oneTimeCode)
                .focused($focused)
                .onChange(of: code) {
                    code = String(code.filter(\.isNumber).prefix(6))
                    if code.count == 6 { model.submitCode(code) }
                }

            HStack {
                Menu("Didn't get a code?") {
                    Button("Send again") { model.resendCode() }
                    if !request.sms || request.unknown {
                        Button("Send to my Apple devices") { model.sendToDevices() }
                    }
                    ForEach(request.numbers) { number in
                        Button("Text \(number.number)") { model.sendSMS(to: number) }
                    }
                }
                .fixedSize()
                Spacer()
                Button("Cancel", role: .cancel) { model.cancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Continue") { model.submitCode(code) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(code.count != 6)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear { focused = true }
    }
}

struct TeamSheet: View {
    @Environment(AppModel.self) private var model
    let teams: [Team]
    @State private var selection: Team.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose a team").font(.title2.bold())
            Text("Your Apple ID belongs to more than one developer team. Nimbus remembers your choice.")
                .foregroundStyle(.secondary)
            List(teams, selection: $selection) { team in
                VStack(alignment: .leading) {
                    Text(team.name ?? team.id)
                    Text([team.type, team.id].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 180)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.cancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Continue") {
                    if let team = teams.first(where: { $0.id == selection }) { model.choose(team) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear { selection = teams.first?.id }
    }
}

struct CertificatesSheet: View {
    @Environment(AppModel.self) private var model
    let certificates: [Certificate]
    @State private var selection = Set<String>()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Too many certificates").font(.title2.bold())
            Text("Your Apple ID has reached its limit of development certificates. Choose one to revoke. Apps signed with it stop opening until you reinstall them.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List(certificates, selection: $selection) { certificate in
                VStack(alignment: .leading) {
                    Text(certificate.machine ?? certificate.name ?? "Unknown")
                    Text([certificate.name, certificate.expires.map { "expires \($0.prefix(10))" }]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(certificate.serial ?? "")
            }
            .frame(height: 180)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.cancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Revoke") { model.revoke(Array(selection)) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}

struct LogSheet: View {
    @Environment(\.dismiss) private var dismiss
    let lines: [String]

    var body: some View {
        VStack(alignment: .trailing, spacing: 12) {
            ScrollView {
                Text(lines.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 640, height: 400)
            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
    }
}

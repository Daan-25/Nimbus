import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var showLog = false
    @State private var choosingIPA = false
    @State private var dropTargeted = false

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Apple ID", text: $model.appleID)
                        .textContentType(.username)
                    SecureField("Password", text: $model.password)
                        .textContentType(.password)
                    Toggle("Remember password in Keychain", isOn: $model.rememberPassword)
                } header: {
                    Text("Account")
                } footer: {
                    if !model.identity.isEmpty {
                        Label("Signs in as this Mac, so accounts with Advanced Data Protection work.", systemImage: "lock.shield")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help(model.identity)
                    }
                }

                Section("Device") {
                    if model.devices.isEmpty {
                        Label("Connect your iPhone or iPad with a cable and unlock it.", systemImage: "cable.connector")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Install on", selection: $model.selectedUDID) {
                            ForEach(model.devices) { device in
                                Text("\(device.name) · \(device.connection == "usb" ? "USB" : "Wi-Fi")")
                                    .tag(Optional(device.udid))
                            }
                        }
                    }
                }

                Section("App") {
                    ipaDropZone
                }

                if model.isRateLimited, let until = model.rateLimitedUntil {
                    Section {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Apple is limiting sign-ins")
                                    .font(.headline)
                                Text("Trying again before \(until.formatted(date: .omitted, time: .shortened)) would only extend the block.")
                                    .foregroundStyle(.secondary)
                                Button("Try anyway") { model.clearRateLimit() }
                                    .buttonStyle(.link)
                            }
                        } icon: {
                            Image(systemName: "hourglass").foregroundStyle(.orange)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            footer
        }
        .task { model.start() }
        .fileImporter(isPresented: $choosingIPA, allowedContentTypes: [.ipa]) { result in
            if case .success(let url) = result { model.ipaURL = url }
        }
        .sheet(isPresented: Binding(get: { model.twoFactor != nil }, set: { if !$0 && model.twoFactor != nil { model.cancel() } })) {
            if let request = model.twoFactor { TwoFactorSheet(request: request) }
        }
        .sheet(isPresented: Binding(get: { model.teams != nil }, set: { if !$0 && model.teams != nil { model.cancel() } })) {
            TeamSheet(teams: model.teams ?? [])
        }
        .sheet(isPresented: Binding(get: { model.certificates != nil }, set: { if !$0 && model.certificates != nil { model.cancel() } })) {
            CertificatesSheet(certificates: model.certificates ?? [])
        }
        .sheet(isPresented: $showLog) {
            LogSheet(lines: model.log)
        }
    }

    private var ipaDropZone: some View {
        Button { choosingIPA = true } label: {
            HStack(spacing: 12) {
                Image(systemName: model.ipaURL == nil ? "square.and.arrow.down" : "app.badge.checkmark")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading) {
                    Text(model.ipaURL?.lastPathComponent ?? "Choose an .ipa file")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(model.ipaURL == nil ? "Or drop it here" : "Click to choose another")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                    .foregroundStyle(dropTargeted ? Color.accentColor : .secondary.opacity(0.5))
            )
        }
        .buttonStyle(.plain)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { $0.pathExtension.lowercased() == "ipa" }) else { return false }
            model.ipaURL = url
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.phase != .idle || !model.status.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    statusIcon
                    Text(model.status)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                if model.phase == .working {
                    if let progress = model.progress {
                        ProgressView(value: progress)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
            }
            HStack {
                Button("Log") { showLog = true }
                    .disabled(model.log.isEmpty)
                Spacer()
                if model.phase == .working {
                    Button("Cancel", role: .cancel) { model.cancel() }
                }
                Button("Install") { model.install() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canInstall)
            }
        }
        .padding()
    }

    @ViewBuilder private var statusIcon: some View {
        switch model.phase {
        case .working: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .idle: Image(systemName: "info.circle").foregroundStyle(.secondary)
        }
    }
}

extension UTType {
    static let ipa = UTType(filenameExtension: "ipa") ?? .data
}

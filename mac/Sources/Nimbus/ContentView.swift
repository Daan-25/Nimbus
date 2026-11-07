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
                accountSection
                deviceSection
                appsSection
                if model.isRateLimited { rateLimitSection }
                settingsSection
            }
            .formStyle(.grouped)
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first(where: { $0.pathExtension.lowercased() == "ipa" }) else { return false }
                model.add(url)
                return true
            } isTargeted: { dropTargeted = $0 }
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                        .padding(6)
                        .allowsHitTesting(false)
                }
            }

            Divider()
            footer
        }
        .task { model.start() }
        .fileImporter(isPresented: $choosingIPA, allowedContentTypes: [.ipa]) { result in
            if case .success(let url) = result {
                let access = url.startAccessingSecurityScopedResource()
                model.add(url)
                if access { url.stopAccessingSecurityScopedResource() }
            }
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

    // MARK: Sections

    private var accountSection: some View {
        @Bindable var model = model
        return Section {
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
    }

    private var deviceSection: some View {
        @Bindable var model = model
        return Section("Device") {
            if model.devices.isEmpty {
                Label("Connect your iPhone or iPad with a cable and unlock it.", systemImage: "cable.connector")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Device", selection: $model.selectedUDID) {
                    ForEach(model.devices) { device in
                        Text("\(device.name) · \(device.connection == "usb" ? "USB" : "Wi-Fi")")
                            .tag(Optional(device.udid))
                    }
                }
                if let used = model.usedAppSlots {
                    LabeledContent("App slots") {
                        Text("\(used) of \(AppModel.freeAppSlots) used")
                            .foregroundStyle(used >= AppModel.freeAppSlots ? .orange : .secondary)
                    }
                    .help("A free Apple ID can have \(AppModel.freeAppSlots) sideloaded apps on a device at once, AltStore and other tools included.")
                }
                if let available = model.appIDsAvailable, let max = model.appIDsMax {
                    LabeledContent("App IDs this week") {
                        Text("\(available) of \(max) left")
                            .foregroundStyle(available <= 1 ? .orange : .secondary)
                    }
                    .help("Every new app uses an app ID. A free Apple ID can create \(max) a week. Refreshing doesn't use new ones.")
                }
            }
        }
    }

    private var appsSection: some View {
        Section {
            if model.libraryAppsOnDevice.isEmpty && model.otherAppsOnDevice.isEmpty {
                Text("Add an app with the button below, or drop an .ipa file on this window.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.libraryAppsOnDevice) { app in
                LibraryAppRow(app: app)
            }
            ForEach(model.otherAppsOnDevice) { app in
                OtherAppRow(app: app)
            }
            HStack {
                Button("Add App…", systemImage: "plus") { choosingIPA = true }
                Spacer()
                Button("Refresh All", systemImage: "arrow.clockwise") { model.refreshAll() }
                    .disabled(model.libraryAppsOnDevice.isEmpty || model.isRateLimited)
            }
            .disabled(model.isBusy || model.selectedDevice == nil)
        } header: {
            Text("Apps")
        }
    }

    private var rateLimitSection: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Apple is limiting sign-ins")
                        .font(.headline)
                    if let until = model.rateLimitedUntil {
                        Text("Trying again before \(until.formatted(date: .omitted, time: .shortened)) would only extend the block.")
                            .foregroundStyle(.secondary)
                    }
                    Button("Try anyway") { model.clearRateLimit() }
                        .buttonStyle(.link)
                }
            } icon: {
                Image(systemName: "hourglass").foregroundStyle(.orange)
            }
        }
    }

    private var settingsSection: some View {
        @Bindable var model = model
        return Section {
            Toggle("Refresh apps automatically", isOn: $model.autoRefresh)
            Toggle("Open Nimbus at login", isOn: Binding(get: { model.openAtLogin }, set: { model.setOpenAtLogin($0) }))
        } header: {
            Text("Automatic refresh")
        } footer: {
            Text(model.rememberPassword
                 ? "Nimbus refreshes your apps two days before they expire, while it's running and your device is connected. Over Wi-Fi, too, if you turned on \"Show this iPhone when on Wi-Fi\" in Finder."
                 : "Turn on \"Remember password in Keychain\" so Nimbus can refresh on its own.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.status.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    statusIcon
                    Text(model.status)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                if model.isBusy {
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
                if model.isBusy {
                    Button("Cancel", role: .cancel) { model.cancel() }
                }
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

// MARK: Rows

private struct LibraryAppRow: View {
    @Environment(AppModel.self) private var model
    let app: LibraryApp

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "app.fill")
                .font(.title)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                expiry
                    .font(.caption)
            }
            Spacer()
            Button("Refresh") { model.refresh([app]) }
                .disabled(model.isBusy || model.isRateLimited)
            Menu {
                Button("Remove from Device…") {
                    if confirmRemoval(of: app.name) { model.uninstall(bundleID: app.bundleID, name: app.name) }
                }
                    .disabled(model.isBusy || model.isInstalled(app) == false)
                Button("Forget") { model.forget(app) }
                    .disabled(model.isBusy)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([app.ipaURL]) }
        }
    }

    @ViewBuilder private var expiry: some View {
        if model.isInstalled(app) == false {
            Text("Not on this device anymore").foregroundStyle(.secondary)
        } else {
            let expires = model.expiry(of: app)
            if expires < .now {
                Text("Expired. Refresh to use it again.").foregroundStyle(.red)
            } else {
                Text("Expires \(expires.formatted(.relative(presentation: .named)))")
                    .foregroundStyle(expires.timeIntervalSinceNow < AppModel.refreshWindow ? .orange : .secondary)
            }
        }
    }
}

private struct OtherAppRow: View {
    @Environment(AppModel.self) private var model
    let app: DeviceApp

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "app.dashed")
                .font(.title)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                Text("Installed with another tool. Add its .ipa to refresh it with Nimbus.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("Remove from Device…") {
                    if confirmRemoval(of: app.name) { model.uninstall(bundleID: app.bundleId, name: app.name) }
                }
                    .disabled(model.isBusy)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}

@MainActor
private func confirmRemoval(of name: String) -> Bool {
    let alert = NSAlert()
    alert.messageText = "Remove \(name) from your device?"
    alert.informativeText = "The app and its data are deleted from your device."
    alert.addButton(withTitle: "Remove").hasDestructiveAction = true
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
}

extension UTType {
    static let ipa = UTType(filenameExtension: "ipa") ?? .data
}

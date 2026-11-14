import SwiftUI
import UniformTypeIdentifiers

@main
struct NimbusApp: App {
    @State private var model = PhoneModel.shared

    init() {
        BackgroundRefresh.register()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
        }
    }
}

struct ContentView: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var choosingPairingFile = false
    @State private var choosingIPA = false
    /// The app the user is about to remove from the device.
    @State private var removing: DeviceApp?
    /// The app the user is about to archive.
    @State private var archiving: LibraryApp?
    @State private var showLog = false
    @State private var tab = Tab.apps

    private enum Tab {
        case apps, browse, settings
    }

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack {
                List {
                    connectionSection
                    if !model.hasCredentials { accountHint }
                    if model.isConnected || !model.refreshableApps.isEmpty { appsSection }
                    if !model.status.isEmpty { statusSection }
                }
                .navigationTitle("Nimbus")
                .refreshable { await model.check() }
            }
            .tabItem { Label("Apps", systemImage: "square.grid.2x2") }
            .tag(Tab.apps)

            BrowseView()
                .tabItem { Label("Browse", systemImage: "shippingbox") }
                .tag(Tab.browse)

            NavigationStack {
                List {
                    accountSection
                    automaticSection
                    advancedSection
                }
                .navigationTitle("Settings")
            }
            .tabItem { Label("Settings", systemImage: "gear") }
            .tag(Tab.settings)
        }
        .task {
            model.start()
            await model.check()
        }
        // An .ipa opened with Nimbus from Files, Safari or the share sheet.
        .onOpenURL { url in
            if url.pathExtension.lowercased() == "ipa" {
                model.add(url)
            } else if url.scheme == "nimbus", url.host == "refresh" {
                // nimbus://refresh, for a shortcut or a link that opens Nimbus and refreshes.
                tab = .apps
                model.refreshAll()
            }
        }
        .confirmationDialog(
            "Archive \(model.pendingSwap?.archive.name ?? "an app") to make room?",
            isPresented: Binding(get: { model.pendingSwap != nil }, set: { if !$0 { model.pendingSwap = nil } }),
            titleVisibility: .visible
        ) {
            Button("Archive and Open") { model.confirmPendingSwap() }
        } message: {
            if let pending = model.pendingSwap {
                Text("All slots are in use. To open \(pending.open.name), Nimbus would archive \(pending.archive.name). That app shares data with its widgets or extensions, and that part of its data isn't saved.")
            }
        }
        .confirmationDialog(
            "Archive \(archiving?.name ?? "this app")?",
            isPresented: Binding(get: { archiving != nil }, set: { if !$0 { archiving = nil } }),
            titleVisibility: .visible
        ) {
            Button("Archive") {
                if let app = archiving { model.archive(app) }
                archiving = nil
            }
        } message: {
            Text("Nimbus saves the app's data and removes the app, which frees a slot. Restore puts the app and its data back. Data an app shares with its widgets or extensions isn't saved, and neither is anything it keeps in iCloud or the Keychain.")
        }
        .confirmationDialog(
            "Remove \(removing?.name ?? "this app") from this device?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let app = removing { model.uninstall(bundleID: app.bundleId, name: app.name) }
                removing = nil
            }
        } message: {
            Text("The app and its data are deleted.")
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active { Task { await model.check() } }
        }
        .fileImporter(isPresented: $choosingPairingFile, allowedContentTypes: [.propertyList, .xml, .data]) { result in
            if case .success(let url) = result { model.importPairingFile(url) }
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

    private var connectionSection: some View {
        Section("Connection") {
            connectionRow
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder private var connectionRow: some View {
        switch model.connection {
        case .noPairingFile:
            row("Not set up yet", "Connect this device to your Mac and install Nimbus from there. The Mac adds the pairing file Nimbus needs.",
                systemImage: "cable.connector", color: .orange)
        case .checking:
            HStack(spacing: 12) {
                ProgressView()
                Text("Looking for this device…")
            }
        case .unreachable:
            row("Can't reach this device",
                model.error == nil ? "Open LocalDevVPN and turn it on, then come back to Nimbus." : "The reason is below.",
                systemImage: "network.slash", color: .orange)
        case .connected(let device):
            row(device.name, "Connected", systemImage: "checkmark.circle.fill", color: .green)
        }
    }

    private func row(_ title: String, _ detail: String, systemImage: String, color: Color) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: systemImage).foregroundStyle(color)
        }
    }

    /// Shown on the Apps tab until there's an account to sign in with.
    private var accountHint: some View {
        Section {
            Button {
                tab = .settings
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enter your Apple ID")
                        Text("Nimbus needs it to install and refresh apps. It's under Settings.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "person.crop.circle.badge.exclamationmark")
                }
            }
            .foregroundStyle(.primary)
        }
    }

    private var accountSection: some View {
        @Bindable var model = model
        return Section {
            TextField("Apple ID", text: $model.appleID)
                .textContentType(.username)
                .keyboardType(.emailAddress)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            SecureField("Password", text: $model.password)
                .textContentType(.password)
            Toggle("Remember password", isOn: $model.rememberPassword)
        } header: {
            Text("Account")
        } footer: {
            Text("Your password goes only to Apple. Nimbus signs in the way your Mac does, so accounts with Advanced Data Protection work.")
        }
        .disabled(model.isBusy)
    }

    private var appsSection: some View {
        Section {
            if model.refreshableApps.isEmpty && model.otherApps.isEmpty && model.archivedApps.isEmpty {
                Text(model.deviceApps == nil ? "Loading…" : "No sideloaded apps on this device.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.refreshableApps) { app in
                HStack(spacing: 12) {
                    // An app from a source opens its page.
                    if let page = model.sourceApp(for: app) {
                        NavigationLink {
                            SourceAppPage(app: page.app, source: page.source)
                        } label: {
                            appLabel(app)
                        }
                    } else {
                        appLabel(app)
                        Spacer()
                    }
                    if !model.isActive(app.bundleID) {
                        Button("Activate") { model.activate(bundleID: app.bundleID, name: app.name) }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.isBusy || !model.isConnected)
                    } else if let update = model.update(for: app) {
                        // Updating signs the app again, so it also refreshes it.
                        Button("Update") { model.install(update.app, from: update.source) }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.isBusy || !model.isConnected)
                    } else {
                        Button("Refresh") { model.refresh([app]) }
                            .buttonStyle(.bordered)
                            .disabled(model.isBusy || !model.isConnected)
                    }
                }
                .swipeActions {
                    // Removing Nimbus from inside Nimbus would cut off the branch it sits on.
                    if app.bundleID != Bundle.main.bundleIdentifier {
                        removeButton(DeviceApp(bundleId: app.bundleID, name: app.name, version: app.version))
                        Button("Archive", systemImage: "archivebox") { archiving = app }
                            .tint(.blue)
                            .disabled(model.isBusy || !model.isConnected)
                        activationButton(bundleID: app.bundleID, name: app.name)
                    }
                }
                .swipeActions(edge: .leading) {
                    if app.bundleID != Bundle.main.bundleIdentifier {
                        Button("Open", systemImage: "arrow.up.forward.app") { model.launch(app) }
                            .tint(.green)
                            .disabled(model.isBusy || !model.isConnected)
                        jitButton(bundleID: app.bundleID, name: app.name)
                    }
                }
            }
            ForEach(model.archivedApps) { app in
                HStack(spacing: 12) {
                    AppIcon(url: app.iconURL)
                        .opacity(0.5)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name)
                        Text("Archived. Its data is kept, and it doesn't take up a slot.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    // Puts it back and opens it, archiving another app when all slots are in use.
                    Button("Open") { model.open(app) }
                        .buttonStyle(.bordered)
                        .disabled(model.isBusy || !model.isConnected)
                }
                .contentShape(Rectangle())
                .onTapGesture { if !model.isBusy && model.isConnected { model.open(app) } }
            }
            ForEach(model.otherApps) { app in
                HStack(spacing: 12) {
                    AppIcon(url: nil)
                        .opacity(0.4)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name)
                        Text(app.active == false
                             ? "Deactivated. It won't open until you activate it; its data is kept."
                             : "Nimbus has no .ipa file of this app. Add its .ipa to refresh it here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .swipeActions {
                    removeButton(app)
                    activationButton(bundleID: app.bundleId, name: app.name)
                }
                .swipeActions(edge: .leading) { jitButton(bundleID: app.bundleId, name: app.name) }
            }
            Button("Add App…", systemImage: "plus") { choosingIPA = true }
                .disabled(model.isBusy || !model.isConnected)
                .fileImporter(isPresented: $choosingIPA, allowedContentTypes: [.ipa]) { result in
                    if case .success(let url) = result { model.add(url) }
                }
            if model.refreshableApps.count > 1 {
                Button("Refresh All", systemImage: "arrow.clockwise") { model.refreshAll() }
                    .disabled(model.isBusy || !model.isConnected)
            }
        } header: {
            HStack {
                Text("Apps")
                Spacer()
                if let used = model.usedAppSlots {
                    Text("\(used) of \(PhoneModel.freeAppSlots) slots used")
                }
            }
        } footer: {
            Text("Find apps under Browse, add an .ipa file from this device, or open one with Nimbus from Files or Safari. Tap an archived app to open it: Nimbus puts it back and, when all slots are in use, archives the app you used least. Swipe an app left to remove, archive or deactivate it, or right to open it, also with JIT. Keep Nimbus open while it works; refreshing Nimbus itself closes it when it's done.")
        }
    }

    private func appLabel(_ app: LibraryApp) -> some View {
        HStack(spacing: 12) {
            AppIcon(url: app.iconURL)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                expiry(of: app).font(.caption)
            }
        }
    }

    /// Starts the app with JIT, for emulators and other apps that generate code.
    private func jitButton(bundleID: String, name: String) -> some View {
        Button("Open with JIT", systemImage: "bolt.fill") { model.enableJIT(bundleID: bundleID, name: name) }
            .tint(.yellow)
            .disabled(model.isBusy || !model.isConnected)
    }

    /// Deactivates an app, which keeps it from opening while its data stays, or activates it again.
    @ViewBuilder private func activationButton(bundleID: String, name: String) -> some View {
        if model.isActive(bundleID) {
            Button("Deactivate", systemImage: "pause.circle") { model.deactivate(bundleID: bundleID, name: name) }
                .tint(.indigo)
                .disabled(model.isBusy || !model.isConnected)
        } else {
            Button("Activate", systemImage: "play.circle") { model.activate(bundleID: bundleID, name: name) }
                .tint(.green)
                .disabled(model.isBusy || !model.isConnected)
        }
    }

    private func removeButton(_ app: DeviceApp) -> some View {
        Button("Remove", systemImage: "trash", role: .destructive) { removing = app }
            .disabled(model.isBusy || !model.isConnected)
    }

    private var automaticSection: some View {
        @Bindable var model = model
        return Section {
            Toggle("Refresh apps automatically", isOn: $model.autoRefresh)
        } header: {
            Text("Automatic refresh")
        } footer: {
            Text(model.rememberPassword
                 ? "Nimbus refreshes your apps two days before they expire: when you open it, and in the background when iOS gives it time. LocalDevVPN has to be on. If it can't, you get a notification a day before they expire. For a schedule of your own, add the Refresh All Apps action to an automation in the Shortcuts app."
                 : "Turn on Remember password so Nimbus can refresh on its own.")
        }
    }

    @ViewBuilder private func expiry(of app: LibraryApp) -> some View {
        let expires = model.expiry(of: app)
        if !model.isActive(app.bundleID) {
            Text("Deactivated. It won't open until you activate it; its data is kept.").foregroundStyle(.secondary)
        } else if expires < .now {
            Text("Expired. Refresh to use it again.").foregroundStyle(.red)
        } else {
            Text("Expires \(expires.formatted(.relative(presentation: .named)))")
                .foregroundStyle(expires.timeIntervalSinceNow < PhoneModel.refreshWindow ? .orange : .secondary)
        }
    }

    private var statusSection: some View {
        Section {
            HStack(alignment: .top, spacing: 10) {
                switch model.phase {
                case .working: ProgressView()
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                case .idle: Image(systemName: "info.circle").foregroundStyle(.secondary)
                }
                Text(model.status)
                    .textSelection(.enabled)
            }
            if model.isBusy {
                if let progress = model.progress {
                    ProgressView(value: progress)
                }
                Button("Cancel", role: .cancel) { model.cancel() }
            }
            if !model.log.isEmpty {
                Button("Show Log") { showLog = true }
            }
        }
    }

    private var advancedSection: some View {
        @Bindable var model = model
        return Section {
            LabeledContent("Device address") {
                TextField(PhoneModel.defaultAddress, text: $model.address)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit { Task { await model.check() } }
            }
            Button("Choose Pairing File…") { choosingPairingFile = true }
            Button {
                Task { await model.diagnose() }
            } label: {
                HStack {
                    Text("Test Connection")
                    if model.isDiagnosing {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(model.isDiagnosing || model.isBusy || !model.hasPairingFile)
            if let diagnosis = model.diagnosis {
                VStack(alignment: .leading, spacing: 8) {
                    Text(diagnosis.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Button("Copy", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = diagnosis.joined(separator: "\n")
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                }
            }
        } header: {
            Text("Advanced")
        }
    }
}

extension UTType {
    static let ipa = UTType("com.apple.itunes.ipa") ?? UTType(filenameExtension: "ipa") ?? .data
}

/// An app's icon from the web, with a placeholder until it's loaded or when there is none.
struct AppIcon: View {
    let url: URL?
    var size: CGFloat = 36

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Image(systemName: "app.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.tint)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
    }
}

// MARK: Sheets

struct TwoFactorSheet: View {
    @Environment(PhoneModel.self) private var model
    let request: TwoFactorRequest
    @State private var code = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("123456", text: $code)
                        .font(.system(.title, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .focused($focused)
                        .onChange(of: code) {
                            code = String(code.filter(\.isNumber).prefix(6))
                            if code.count == 6 { model.submitCode(code) }
                        }
                } header: {
                    Text(request.sms
                         ? "Enter the code Apple sent by text message."
                         : "Enter the 6-digit code. This device may show it itself: tap Allow, then type the code here.")
                } footer: {
                    if let error = request.lastError {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    }
                }
                Section("Didn't get a code?") {
                    Button("Send again") { model.resendCode() }
                    if !request.sms || request.unknown {
                        Button("Send to my Apple devices") { model.sendToDevices() }
                    }
                    ForEach(request.numbers) { number in
                        Button("Text \(number.number)") { model.sendSMS(to: number) }
                    }
                }
            }
            .navigationTitle("Verification code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.cancel() }
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }
}

struct TeamSheet: View {
    @Environment(PhoneModel.self) private var model
    let teams: [Team]

    var body: some View {
        NavigationStack {
            List(teams) { team in
                Button {
                    model.choose(team)
                } label: {
                    VStack(alignment: .leading) {
                        Text(team.name ?? team.id)
                        Text([team.type, team.id].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Choose a team")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.cancel() }
                }
            }
        }
    }
}

struct CertificatesSheet: View {
    @Environment(PhoneModel.self) private var model
    let certificates: [Certificate]
    @State private var selection = Set<String>()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(certificates) { certificate in
                        let serial = certificate.serial ?? ""
                        Button {
                            if selection.contains(serial) { selection.remove(serial) } else { selection.insert(serial) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(certificate.machine ?? certificate.name ?? "Unknown")
                                    Text([certificate.name, certificate.expires.map { "expires \($0.prefix(10))" }]
                                        .compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selection.contains(serial) { Image(systemName: "checkmark") }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                } footer: {
                    Text("Your Apple ID has reached its limit of development certificates. Choose one to revoke. Apps signed with it stop opening until they're refreshed.")
                }
            }
            .navigationTitle("Too many certificates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.cancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Revoke") { model.revoke(Array(selection)) }
                        .disabled(selection.isEmpty)
                }
            }
        }
    }
}

struct LogSheet: View {
    @Environment(\.dismiss) private var dismiss
    let lines: [String]

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(lines.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Copy") { UIPasteboard.general.string = lines.joined(separator: "\n") }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

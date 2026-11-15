import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var showLog = false
    @State private var choosingIPA = false
    @State private var page: Page? = .myApps

    enum Page: Hashable {
        case myApps, browse
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $page) {
                Section("Library") {
                    NavigationLink(value: Page.myApps) {
                        Label("My Apps", systemImage: "square.grid.2x2")
                    }
                    .badge(model.libraryAppsOnDevice.count + model.otherAppsOnDevice.count)
                    NavigationLink(value: Page.browse) {
                        Label("Browse", systemImage: "shippingbox")
                    }
                }
                Section("Device") {
                    DeviceSummary()
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            Group {
                switch page ?? .myApps {
                case .myApps:
                    MyAppsView(choosingIPA: $choosingIPA)
                case .browse:
                    BrowseView()
                }
            }
            // On the detail, not the window: a minimum size on the whole split view makes the
            // sidebar push the content out of the window for a moment when it slides in.
            .frame(minWidth: 520, minHeight: 540)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                DevicePicker()
            }
            if page != .browse {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Add App", systemImage: "plus") { choosingIPA = true }
                        .help("Install an .ipa file")
                        .disabled(model.isBusy || model.selectedDevice == nil)
                    Button("Refresh All", systemImage: "arrow.clockwise") { model.refreshAll() }
                        .help("Refresh every app with one sign-in")
                        .disabled(model.isBusy || model.libraryAppsOnDevice.isEmpty || model.isRateLimited || model.selectedDevice == nil)
                }
            }
        }
        .overlay(alignment: .bottom) {
            StatusBar(showLog: $showLog)
                .padding(.bottom, 16)
                .padding(.horizontal, 24)
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
}

// MARK: Device

/// Chooses the device to work with, in the toolbar.
private struct DevicePicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        if model.devices.isEmpty {
            Label("No device", systemImage: "iphone.slash")
                .foregroundStyle(.secondary)
                .help("Connect your iPhone or iPad with a cable and unlock it.")
        } else {
            // A menu instead of a picker: in the toolbar a picker shows only the icon, not the name.
            Menu {
                Picker("Device", selection: $model.selectedUDID) {
                    ForEach(model.devices) { device in
                        Label(device.name, systemImage: icon(of: device))
                            .tag(Optional(device.udid))
                    }
                }
                .pickerStyle(.inline)
            } label: {
                if let device = model.selectedDevice {
                    Label(device.name, systemImage: icon(of: device))
                        .labelStyle(.titleAndIcon)
                } else {
                    Label("Choose a device", systemImage: "iphone")
                        .labelStyle(.titleAndIcon)
                }
            }
            .fixedSize()
            .help("The device Nimbus works with")
        }
    }

    private func icon(of device: Device) -> String {
        device.connection == "usb" ? "cable.connector" : "wifi"
    }
}

/// The device's limits at a glance, in the sidebar.
private struct DeviceSummary: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let device = model.selectedDevice {
            VStack(alignment: .leading, spacing: 10) {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(device.name)
                            .lineLimit(1)
                        Text(device.connection == "usb" ? "Connected by cable" : "Connected over Wi-Fi")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "iphone")
                }
                if let available = model.appIDsAvailable, let max = model.appIDsMax {
                    meter("App IDs left", value: available, of: max, label: "\(available) of \(max)", warn: available <= 1)
                        .help("Every new app uses an app ID. A free Apple ID can create \(max) a week. Refreshing doesn't use new ones.")
                }
            }
            .padding(.vertical, 4)
        } else {
            Label("Connect your iPhone or iPad with a cable and unlock it.", systemImage: "cable.connector")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func meter(_ title: String, value: Int, of total: Int, label: String, warn: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(label)
                    .monospacedDigit()
                    .foregroundStyle(warn ? Palette.warm : .secondary)
            }
            .font(.caption)
            ProgressView(value: Double(min(value, total)), total: Double(max(total, 1)))
                .tint(warn ? Palette.warm : Palette.accent)
        }
    }
}

// MARK: My apps

private struct MyAppsView: View {
    @Environment(AppModel.self) private var model
    @Binding var choosingIPA: Bool
    @State private var dropTargeted = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if !model.hasCredentials { signInCard }
                if model.isRateLimited { rateLimitCard }
                if model.selectedDevice == nil { noDeviceCard }
                SkyHeader(
                    apps: skyApps,
                    usedSlots: model.usedAppSlots,
                    slots: AppModel.freeAppSlots,
                    lifetime: AppModel.signatureLifetime,
                    refreshWindow: AppModel.refreshWindow,
                    arcHeight: 124
                )
                .padding(.horizontal, 4)
                .padding(.bottom, 6)
                appsSection
                if model.canInstallPhoneApp { phoneAppCard }
            }
            .padding(24)
            // Room for the status bar, which floats over the bottom.
            .padding(.bottom, 64)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
        .background(SkyBackground())
        .navigationTitle("My Apps")
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { $0.pathExtension.lowercased() == "ipa" }) else { return false }
            model.add(url)
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Every app on the device whose expiry Nimbus knows: its own, and the ones Nimbus on
    /// the device refreshes.
    private var skyApps: [SkyApp] {
        let mine = model.libraryAppsOnDevice
            .filter { model.isInstalled($0) == true && model.isActive($0.bundleID) }
            .map { app in
                SkyApp(bundleID: app.bundleID, name: app.name, expires: model.expiry(of: app),
                       icon: model.icons[app.bundleID], iconURL: app.iconURL)
            }
        let phone = model.otherAppsOnDevice.compactMap { app -> SkyApp? in
            guard let expires = model.phoneManagedApps[app.bundleId], expires != .distantPast, app.active != false else { return nil }
            return SkyApp(bundleID: app.bundleId, name: app.name, expires: expires, icon: model.icons[app.bundleId], iconURL: nil)
        }
        return mine + phone
    }

    private var appsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeading("Apps")
            if model.libraryAppsOnDevice.isEmpty && model.otherAppsOnDevice.isEmpty {
                ContentUnavailableView {
                    Label("No Apps Yet", systemImage: "square.grid.2x2")
                } description: {
                    Text("Find an app under Browse, add an .ipa file with the + button, or drop one on this window.")
                } actions: {
                    Button("Add App…") { choosingIPA = true }
                        .glassButton(prominent: true)
                        .disabled(model.isBusy || model.selectedDevice == nil)
                }
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
                .glassCard()
            } else {
                VStack(spacing: 0) {
                    let apps = model.libraryAppsOnDevice
                    ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                        LibraryAppRow(app: app)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        if index < apps.count - 1 || !model.otherAppsOnDevice.isEmpty {
                            Divider().padding(.leading, 70)
                        }
                    }
                    let others = model.otherAppsOnDevice
                    ForEach(Array(others.enumerated()), id: \.element.id) { index, app in
                        OtherAppRow(app: app)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        if index < others.count - 1 {
                            Divider().padding(.leading, 70)
                        }
                    }
                }
                .glassCard()
            }
        }
    }

    private var signInCard: some View {
        card(symbol: "person.crop.circle.badge.exclamationmark", tint: .accentColor,
             title: "Sign in with your Apple ID",
             text: "Nimbus needs it to install and refresh apps. It signs in as this Mac, so accounts with Advanced Data Protection work.") {
            SettingsLink {
                Text("Open Settings…")
            }
            .glassButton(prominent: true)
        }
    }

    private var rateLimitCard: some View {
        card(symbol: "hourglass", tint: .orange,
             title: "Apple is limiting sign-ins",
             text: model.rateLimitedUntil.map { "Trying again before \($0.formatted(date: .omitted, time: .shortened)) would only extend the block." } ?? "") {
            Button("Try Anyway") { model.clearRateLimit() }
                .glassButton()
        }
    }

    private var noDeviceCard: some View {
        card(symbol: "cable.connector", tint: .secondary,
             title: "Connect your iPhone or iPad",
             text: "Use a cable and unlock it. After the first time, Wi-Fi works too, if you turned on \"Show this iPhone when on Wi-Fi\" in Finder.") {
            EmptyView()
        }
    }

    private var phoneAppCard: some View {
        card(symbol: "iphone.and.arrow.forward.inward", tint: .accentColor,
             title: "Nimbus for \(model.selectedDevice?.name ?? "your device")",
             text: "Install and refresh apps on the device itself, without this Mac. Uses one app slot.") {
            Button("Install") { model.installPhoneApp() }
                .glassButton(prominent: true)
                .disabled(model.isBusy || model.isRateLimited)
        }
    }

    private func card(symbol: String, tint: Color, title: String, text: String,
                      @ViewBuilder action: () -> some View) -> some View {
        HStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 26))
                .foregroundStyle(tint)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(text)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            action()
        }
        .padding(18)
        .glassCard()
    }
}

// MARK: Status

/// What Nimbus is doing, floating over the bottom of the window while there's something to say.
private struct StatusBar: View {
    @Environment(AppModel.self) private var model
    @Binding var showLog: Bool

    var body: some View {
        if !model.status.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 10) {
                    icon
                    Text(model.status)
                        .lineLimit(3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if !model.log.isEmpty {
                        Button("Log") { showLog = true }
                            .glassButton()
                    }
                    if model.isBusy {
                        Button("Cancel", role: .cancel) { model.cancel() }
                            .glassButton()
                    } else {
                        Button("Dismiss", systemImage: "xmark") { model.dismissStatus() }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                    }
                }
                if model.isBusy {
                    if let progress = model.progress {
                        ProgressView(value: progress)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(maxWidth: 680)
            .glassCard(cornerRadius: 22)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            // A finished job clears itself after a while; a failure stays until dismissed.
            .task(id: model.status) {
                guard model.phase == .done else { return }
                try? await Task.sleep(for: .seconds(8))
                if model.phase == .done { model.dismissStatus() }
            }
        }
    }

    @ViewBuilder private var icon: some View {
        switch model.phase {
        case .working: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .idle: Image(systemName: "info.circle").foregroundStyle(.secondary)
        }
    }
}

// MARK: Settings

/// Nimbus's settings window (⌘,): the account and automatic refresh.
struct SettingsView: View {
    var body: some View {
        TabView {
            AccountSettings()
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
            RefreshSettings()
                .tabItem { Label("Refresh", systemImage: "arrow.clockwise") }
        }
        .frame(width: 480)
    }
}

private struct AccountSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                TextField("Apple ID", text: $model.appleID)
                    .textContentType(.username)
                SecureField("Password", text: $model.password)
                    .textContentType(.password)
                Toggle("Remember password in Keychain", isOn: $model.rememberPassword)
            } footer: {
                Label("Your password goes only to Apple. Nimbus signs in as this Mac, so accounts with Advanced Data Protection work.", systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(model.identity)
            }
        }
        .formStyle(.grouped)
    }
}

private struct RefreshSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Refresh apps automatically", isOn: $model.autoRefresh)
                Toggle("Open Nimbus at login", isOn: Binding(get: { model.openAtLogin }, set: { model.setOpenAtLogin($0) }))
            } footer: {
                Text(model.rememberPassword
                     ? "Nimbus refreshes your apps two days before they expire, while it's running and your device is connected. Over Wi-Fi, too, if you turned on \"Show this iPhone when on Wi-Fi\" in Finder."
                     : "Turn on \"Remember password in Keychain\" under Account so Nimbus can refresh on its own.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Rows

private struct LibraryAppRow: View {
    @Environment(AppModel.self) private var model
    let app: LibraryApp
    @State private var showingTweaks = false

    var body: some View {
        HStack(spacing: 12) {
            AppIcon(url: app.iconURL, bundleID: app.bundleID, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name)
                    .font(.body.weight(.medium))
                expiry
                    .font(.caption)
            }
            Spacer()
            if model.isArchived(app) {
                Button("Restore") { model.restore(app) }
                    .glassButton(prominent: true)
                    .disabled(model.isBusy)
            } else if let update = model.update(for: app) {
                // Updating signs the app again, so it also refreshes it.
                Button("Update") { model.install(update.app, from: update.source) }
                    .glassButton(prominent: true)
                    .disabled(model.isBusy || model.isRateLimited)
                    .help(update.app.version.map { "Version \($0) is available." } ?? "A newer version is available.")
            } else if !model.isActive(app.bundleID) {
                Button("Activate") { model.activate(bundleID: app.bundleID, name: app.name) }
                    .glassButton()
                    .disabled(model.isBusy)
            } else {
                Button("Refresh") { model.refresh([app]) }
                    .glassButton()
                    .disabled(model.isBusy || model.isRateLimited)
            }
            Menu {
                Button("Open with JIT") { model.enableJIT(bundleID: app.bundleID, name: app.name) }
                    .disabled(model.isBusy || model.isInstalled(app) == false || model.isPhoneApp(app) || !model.isActive(app.bundleID))
                // Deactivating Nimbus on the device would stop it from activating anything again.
                if model.isActive(app.bundleID) && !model.isPhoneApp(app) {
                    Button("Deactivate") { model.deactivate(bundleID: app.bundleID, name: app.name) }
                        .disabled(model.isBusy || model.isInstalled(app) == false)
                }
                // Archiving Nimbus on the device would take away what puts apps back there.
                if !model.isPhoneApp(app) {
                    Button("Archive…") {
                        if confirmArchiving(of: app.name) { model.archive(app) }
                    }
                        .disabled(model.isBusy || model.isInstalled(app) != true)
                }
                Button("Remove from Device…") {
                    if confirmRemoval(of: app.name) { model.uninstall(bundleID: app.bundleID, name: app.name) }
                }
                    .disabled(model.isBusy || model.isInstalled(app) == false)
                if model.isPhoneApp(app) {
                    Button("Set Up Again") { model.setUpPhoneApp(app) }
                        .disabled(model.isBusy || model.isInstalled(app) == false)
                }
                if !model.isPhoneApp(app) {
                    Button("Tweaks…") { showingTweaks = true }
                }
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
        .sheet(isPresented: $showingTweaks) {
            TweaksSheet(appID: app.id)
        }
    }

    private var tweakCount: String {
        let count = app.tweaks?.count ?? 0
        return count == 0 ? "" : count == 1 ? " · 1 tweak" : " · \(count) tweaks"
    }

    @ViewBuilder private var expiry: some View {
        if model.isArchived(app) {
            Text("Archived. Its data is kept on this Mac, and it doesn't take up a slot.").foregroundStyle(.secondary)
        } else if model.isInstalled(app) == false {
            Text("Not on this device anymore").foregroundStyle(.secondary)
        } else if !model.isActive(app.bundleID) {
            Text("Deactivated. It won't open until you activate it; its data is kept.").foregroundStyle(.secondary)
        } else {
            let expires = model.expiry(of: app)
            if expires < .now {
                Text("Expired. Refresh to use it again.").foregroundStyle(.red)
            } else {
                Text((app.version.map { "\($0) · " } ?? "") + timeLeft(until: expires) + tweakCount)
                    .monospacedDigit()
                    .foregroundStyle(expires.timeIntervalSinceNow < AppModel.refreshWindow ? Palette.warm : .secondary)
            }
        }
    }
}

private struct OtherAppRow: View {
    @Environment(AppModel.self) private var model
    let app: DeviceApp

    /// Set when Nimbus on the device installed this app and refreshes it there.
    private var managedUntil: Date? {
        model.phoneManagedApps[app.bundleId]
    }

    @ViewBuilder private var detail: some View {
        if app.active == false {
            Text("Deactivated. It won't open until you activate it; its data is kept.").foregroundStyle(.secondary)
        } else if let expires = managedUntil {
            // The device didn't say when it expires.
            if expires == .distantPast {
                Text("Installed by Nimbus on the device, which refreshes it.").foregroundStyle(.secondary)
            } else if expires < .now {
                Text("Installed by Nimbus on the device. Expired; refresh it there.").foregroundStyle(.red)
            } else {
                Text((app.version.map { "\($0) · " } ?? "") + timeLeft(until: expires) + " · refreshed by Nimbus on the device")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("Installed with another tool. Add its .ipa to refresh it with Nimbus.")
                .foregroundStyle(.secondary)
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            if model.icons[app.bundleId] != nil {
                AppIcon(url: nil, bundleID: app.bundleId, size: 40)
            } else {
                Image(systemName: managedUntil == nil ? "app.dashed" : "iphone")
                    .font(.system(size: 26))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 40)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name)
                    .font(.body.weight(.medium))
                detail
                    .font(.caption)
            }
            Spacer()
            Menu {
                if app.active == false {
                    Button("Activate") { model.activate(bundleID: app.bundleId, name: app.name) }
                        .disabled(model.isBusy)
                } else {
                    Button("Deactivate") { model.deactivate(bundleID: app.bundleId, name: app.name) }
                        .disabled(model.isBusy)
                }
                Button("Open with JIT") { model.enableJIT(bundleID: app.bundleId, name: app.name) }
                    .disabled(model.isBusy || app.active == false)
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

/// The tweaks of one app: what's added, adding more, and taking them off.
private struct TweaksSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let appID: String
    @State private var choosing = false

    private var app: LibraryApp? {
        model.library.first { $0.id == appID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Tweaks for \(app?.name ?? "this app")")
                .font(.title2.bold())
            Text("A tweak is a library (.dylib) that the app loads when it starts. A .deb package works too: Nimbus takes the tweaks out of it. Nimbus builds tweaks into the app when it signs it, so they take effect at the next refresh and stay at every refresh after that. The app's own file isn't changed, so taking a tweak off undoes it.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List {
                let tweaks = app?.tweaks ?? []
                if tweaks.isEmpty {
                    Text("No tweaks yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(tweaks, id: \.self) { file in
                    HStack {
                        Image(systemName: "puzzlepiece.extension")
                            .foregroundStyle(.tint)
                        Text(LibraryApp.tweakName(file))
                        Spacer()
                        Button("Remove", role: .destructive) {
                            if let app { model.removeTweak(file, from: app) }
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .frame(height: 160)

            Label("Nimbus doesn't check what a tweak does. Only add tweaks you trust: a tweak can read everything the app can, and send it elsewhere. Tweaks made for jailbroken devices often need Substrate, and Nimbus refuses those, since they'd stop the app from starting.", systemImage: "exclamationmark.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Add Tweak…", systemImage: "plus") { choosing = true }
                    .disabled(model.isBusy)
                Spacer()
                Button("Refresh Now") {
                    if let app { model.refresh([app]) }
                    dismiss()
                }
                .disabled(model.isBusy || model.isRateLimited)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .fileImporter(isPresented: $choosing, allowedContentTypes: UTType.tweaks) { result in
            if case .success(let url) = result, let app { model.addTweak(url, to: app) }
        }
    }
}

@MainActor
private func confirmArchiving(of name: String) -> Bool {
    let alert = NSAlert()
    alert.messageText = "Archive \(name)?"
    alert.informativeText = "Nimbus saves the app's data on this Mac and removes the app from your device, which frees a slot. Restore puts the app and its data back.\n\nData an app shares with its widgets or extensions isn't saved, and neither is anything it keeps in iCloud or the Keychain."
    alert.addButton(withTitle: "Archive")
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
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
    /// Tweaks: a .dylib, or a .deb package with tweaks in it.
    static let tweaks = [UTType(filenameExtension: "dylib"), UTType(filenameExtension: "deb")].compactMap { $0 }

    static let ipa = UTType(filenameExtension: "ipa") ?? .data
}

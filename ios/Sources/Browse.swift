import SwiftUI

/// Lists the apps of every source, to install without finding an .ipa file yourself.
struct BrowseView: View {
    @Environment(PhoneModel.self) private var model
    @State private var search = ""
    @State private var addingSource = false

    var body: some View {
        NavigationStack {
            Group {
                if model.sources.isEmpty {
                    ContentUnavailableView {
                        Label("No Sources", systemImage: "shippingbox")
                    } description: {
                        Text("A source lists apps you can install, so you don't have to find an .ipa file yourself.")
                    } actions: {
                        Button("Add Source…") { addingSource = true }
                    }
                } else if !search.isEmpty && results.isEmpty {
                    ContentUnavailableView.search(text: search)
                } else {
                    list
                }
            }
            .navigationTitle("Browse")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Source", systemImage: "plus") { addingSource = true }
                }
            }
            .searchable(text: $search, prompt: "Search apps")
        }
        .sheet(isPresented: $addingSource) { AddSourceSheet() }
    }

    /// Every source with the apps that match the search. While searching, sources without a match are left out.
    private var results: [(source: Source, apps: [SourceApp])] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return model.sources.compactMap { source in
            guard !query.isEmpty else { return (source, source.apps) }
            let apps = source.apps.filter {
                $0.name.localizedCaseInsensitiveContains(query)
                    || ($0.developer ?? "").localizedCaseInsensitiveContains(query)
                    || ($0.subtitle ?? "").localizedCaseInsensitiveContains(query)
            }
            return apps.isEmpty ? nil : (source, apps)
        }
    }

    private var list: some View {
        List {
            if !model.isConnected || !model.hasCredentials {
                Section {
                    Label(model.hasCredentials
                          ? "Turn on LocalDevVPN to install apps."
                          : "Enter your Apple ID under Settings to install apps.",
                          systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(results, id: \.source.id) { source, apps in
                Section {
                    if let error = model.sourceErrors[source.url] {
                        Label("Couldn't reload this source: \(error)", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if apps.isEmpty {
                        Text("This source has no apps Nimbus can install.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(apps) { app in
                        SourceAppRow(app: app, source: source)
                    }
                } header: {
                    HStack {
                        Text(source.name)
                        Spacer()
                        Menu {
                            Button("Copy Address", systemImage: "doc.on.doc") {
                                UIPasteboard.general.string = source.url.absoluteString
                            }
                            Button("Remove Source", systemImage: "trash", role: .destructive) {
                                model.removeSource(source)
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
        }
        .refreshable { await model.reloadSources() }
    }
}

private struct SourceAppRow: View {
    @Environment(PhoneModel.self) private var model
    let app: SourceApp
    let source: Source

    var body: some View {
        // Tapping the row opens the app's page; the button installs straight from the list.
        NavigationLink {
            SourceAppPage(app: app, source: source)
        } label: {
            HStack(spacing: 12) {
                AppIcon(url: app.iconURL, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name)
                    if let line = app.subtitle ?? app.developer {
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Text(details)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer()
                SourceAppButton(app: app, source: source)
            }
        }
    }

    private var details: String {
        var parts: [String] = []
        if let version = app.version { parts.append("Version \(version)") }
        if let size = app.size, size > 0 { parts.append(Int64(size).formatted(.byteCount(style: .file))) }
        if let minimum = app.minOSVersion { parts.append("iOS \(minimum)+") }
        return parts.joined(separator: " · ")
    }
}

/// Installs or updates an app from a source, or says it's installed.
struct SourceAppButton: View {
    @Environment(PhoneModel.self) private var model
    let app: SourceApp
    let source: Source

    var body: some View {
        switch model.state(of: app, in: source) {
        case .available:
            Button("Get") { model.install(app, from: source) }
                .buttonStyle(.bordered)
                .disabled(!canInstall)
        case .updateAvailable:
            Button("Update") { model.install(app, from: source) }
                .buttonStyle(.borderedProminent)
                .disabled(!canInstall)
        case .installed:
            Text("Installed")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var canInstall: Bool {
        !model.isBusy && model.isConnected
    }
}

/// The page about one app, with what Nimbus is doing shown while it installs.
struct SourceAppPage: View {
    @Environment(PhoneModel.self) private var model
    let app: SourceApp
    let source: Source

    var body: some View {
        AppDetailView(app: app, source: source) {
            SourceAppButton(app: app, source: source)
        }
        .navigationTitle(app.name)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if model.isBusy || model.phase == .failed {
                HStack(spacing: 10) {
                    if model.isBusy {
                        ProgressView()
                    } else {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    }
                    Text(model.status)
                        .font(.footnote)
                        .lineLimit(3)
                    Spacer()
                }
                .padding()
                .background(.bar)
            }
        }
    }
}

struct AddSourceSheet: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var error: String?
    @State private var isLoading = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://example.com/apps.json", text: $address)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($focused)
                        .onSubmit { add(address) }
                } header: {
                    Text("Address")
                } footer: {
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    } else {
                        Text("Paste the address of an AltStore source. Only add sources you trust: Nimbus installs their apps as they are.")
                    }
                }
                if !suggestions.isEmpty {
                    Section("Suggestions") {
                        ForEach(suggestions, id: \.url) { suggestion in
                            Button(suggestion.name) { add(suggestion.url.absoluteString) }
                        }
                    }
                }
            }
            .disabled(isLoading)
            .navigationTitle("Add a source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isLoading {
                        ProgressView()
                    } else {
                        Button("Add") { add(address) }
                            .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }

    private var suggestions: [(name: String, url: URL)] {
        SourceLoader.suggestions.filter { suggestion in !model.sources.contains { $0.url == suggestion.url } }
    }

    private func add(_ text: String) {
        guard !isLoading else { return }
        guard let url = SourceLoader.parseURL(text) else {
            error = SourceError.invalidURL.localizedDescription
            return
        }
        guard !model.sources.contains(where: { $0.url == url }) else {
            error = "You already added this source."
            return
        }
        error = nil
        isLoading = true
        Task {
            do {
                try await model.addSource(url)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            isLoading = false
        }
    }
}

import SwiftUI

/// Lists the apps of every source, to install without finding an .ipa file yourself.
struct BrowseView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var addingSource = false
    /// The app whose page is open.
    @State private var showing: Shown?

    private struct Shown: Identifiable {
        let app: SourceApp
        let source: Source
        var id: String { "\(source.url.absoluteString)/\(app.bundleID)" }
    }

    var body: some View {
        VStack(spacing: 0) {
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
            if !model.sources.isEmpty {
                Divider()
                HStack {
                    Button("Add Source…", systemImage: "plus") { addingSource = true }
                    Spacer()
                    if model.isLoadingSources { ProgressView().controlSize(.small) }
                    Button("Reload", systemImage: "arrow.clockwise") {
                        Task { await model.reloadSources() }
                    }
                    .disabled(model.isLoadingSources)
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
            }
        }
        .searchable(text: $search, prompt: "Search apps")
        .sheet(isPresented: $addingSource) { AddSourceSheet() }
        .sheet(item: $showing) { shown in
            VStack(spacing: 0) {
                AppDetailView(app: shown.app, source: shown.source) {
                    SourceAppButton(app: shown.app, source: shown.source)
                }
                Divider()
                HStack {
                    Spacer()
                    Button("Done") { showing = nil }
                        .keyboardShortcut(.defaultAction)
                }
                .padding()
            }
            .frame(width: 560, height: 640)
        }
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
                            // Clicking the row opens the app's page; the button installs straight from the list.
                            .contentShape(Rectangle())
                            .onTapGesture { showing = Shown(app: app, source: source) }
                    }
                } header: {
                    SourceHeader(source: source)
                }
            }
        }
        .listStyle(.inset)
    }
}

private struct SourceHeader: View {
    @Environment(AppModel.self) private var model
    let source: Source

    var body: some View {
        HStack(spacing: 6) {
            Text(source.name)
                .font(.headline)
                .foregroundStyle(.primary)
            Text(source.apps.count == 1 ? "1 app" : "\(source.apps.count) apps")
                .foregroundStyle(.secondary)
            Spacer()
            Menu {
                Button("Copy Address") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(source.url.absoluteString, forType: .string)
                }
                Button("Remove Source") { model.removeSource(source) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .help(source.url.absoluteString)
    }
}

private struct SourceAppRow: View {
    @Environment(AppModel.self) private var model
    let app: SourceApp
    let source: Source

    var body: some View {
        HStack(spacing: 12) {
            AppIcon(url: app.iconURL, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                if let line = app.subtitle ?? app.developer {
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(details)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            SourceAppButton(app: app, source: source)
        }
        .padding(.vertical, 2)
    }

    private var details: String {
        var parts: [String] = []
        if app.subtitle != nil, let developer = app.developer { parts.append(developer) }
        if let version = app.version { parts.append("Version \(version)") }
        if let size = app.size, size > 0 { parts.append(Int64(size).formatted(.byteCount(style: .file))) }
        if let minimum = app.minOSVersion { parts.append("iOS \(minimum) or later") }
        return parts.joined(separator: " · ")
    }
}

/// Installs or updates an app from a source, or says it's installed.
struct SourceAppButton: View {
    @Environment(AppModel.self) private var model
    let app: SourceApp
    let source: Source

    var body: some View {
        switch model.state(of: app, in: source) {
        case .available:
            Button("Get") { model.install(app, from: source) }
                .disabled(!canInstall)
        case .updateAvailable:
            Button("Update") { model.install(app, from: source) }
                .disabled(!canInstall)
        case .installed:
            Text("Installed")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var canInstall: Bool {
        !model.isBusy && model.selectedDevice != nil && !model.isRateLimited
    }
}

/// An app's icon from the web, with a placeholder until it's loaded or when there is none.
struct AppIcon: View {
    let url: URL?
    var size: CGFloat = 30

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

struct AddSourceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var error: String?
    @State private var isLoading = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Add a source", systemImage: "shippingbox")
                .font(.title2.bold())

            Text("Paste the address of an AltStore source. Only add sources you trust: Nimbus installs their apps as they are.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("https://example.com/apps.json", text: $address)
                .focused($focused)
                .onSubmit { add(address) }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Suggestions")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(suggestions, id: \.url) { suggestion in
                        Button(suggestion.name) { add(suggestion.url.absoluteString) }
                            .buttonStyle(.link)
                    }
                }
            }

            HStack {
                if isLoading { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") { add(address) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 440)
        .disabled(isLoading)
        .onAppear { focused = true }
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

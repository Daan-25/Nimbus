import SwiftUI
import UniformTypeIdentifiers

@main
struct NimbusApp: App {
    @State private var model = PhoneModel()

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

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            List {
                Section {
                    connectionRow
                    if let error = model.error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Connection")
                }

                if case .connected = model.connection {
                    appsSection
                }

                Section {
                    LabeledContent("Device address") {
                        TextField(PhoneModel.defaultAddress, text: $model.address)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numbersAndPunctuation)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onSubmit { Task { await model.check() } }
                    }
                    Button("Choose Pairing File…") { choosingPairingFile = true }
                } header: {
                    Text("Advanced")
                } footer: {
                    Text("Nimbus for iPhone is an early version. It shows your sideloaded apps, and can't refresh them yet.")
                }
            }
            .navigationTitle("Nimbus")
            .refreshable { await model.check() }
        }
        .task { await model.check() }
        .onChange(of: scenePhase) {
            if scenePhase == .active { Task { await model.check() } }
        }
        .fileImporter(isPresented: $choosingPairingFile, allowedContentTypes: [.propertyList, .xml, .data]) { result in
            if case .success(let url) = result { model.importPairingFile(url) }
        }
    }

    @ViewBuilder private var connectionRow: some View {
        switch model.connection {
        case .noPairingFile:
            status("Not set up yet", "Connect this device to your Mac and install Nimbus from there. The Mac adds the pairing file Nimbus needs.",
                   systemImage: "cable.connector", color: .orange)
        case .checking:
            HStack(spacing: 12) {
                ProgressView()
                Text("Looking for this device…")
            }
        case .unreachable:
            status("Can't reach this device", "Open LocalDevVPN and turn it on, then come back to Nimbus.",
                   systemImage: "network.slash", color: .orange)
        case .connected(let device):
            status(device.name, "Connected", systemImage: "checkmark.circle.fill", color: .green)
        }
    }

    private func status(_ title: String, _ detail: String, systemImage: String, color: Color) -> some View {
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

    private var appsSection: some View {
        Section("Sideloaded apps") {
            if let apps = model.apps {
                if apps.isEmpty {
                    Text("No sideloaded apps on this device.")
                        .foregroundStyle(.secondary)
                }
                ForEach(apps) { app in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name)
                        Text([app.version.map { "Version \($0)" }, app.bundleId].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            } else {
                ProgressView()
            }
        }
    }
}

import SwiftUI

@main
struct NimbusApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("Nimbus", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 540, minHeight: 680)
        }
        .windowResizability(.contentMinSize)

        // Keeps Nimbus running after the window closes, so it can refresh apps in the background.
        MenuBarExtra {
            MenuBarContent()
                .environment(model)
        } label: {
            MenuBarLabel()
                .environment(model)
        }
    }
}

private struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: model.isBusy ? "arrow.triangle.2.circlepath.icloud" : "cloud")
            .task { model.start() }
            .onChange(of: model.attentionRequests) {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
    }
}

private struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if model.isBusy {
            Text(model.status)
        } else if let next = model.nextExpiry {
            Text(next < .now ? "Some apps have expired" : "Next app expires \(next.formatted(.relative(presentation: .named)))")
        }
        Button("Refresh All Apps") { model.refreshAll() }
            .disabled(model.isBusy || model.libraryAppsOnDevice.isEmpty || !model.hasCredentials || model.isRateLimited)
        Divider()
        Button("Open Nimbus") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Quit Nimbus") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

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
        Image(nsImage: Self.icon(busy: model.isBusy))
            .task { model.start() }
            .onChange(of: model.attentionRequests) {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
    }
}

extension MenuBarLabel {
    /// Nimbus's planet as a menu bar icon, which macOS colors to match the bar. While Nimbus
    /// is working, a moon sits next to it.
    static func icon(busy: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let black = CGColor(gray: 0, alpha: 1)
            // A little larger than the box: the ring is wide and flat, the bar is low.
            NimbusIcon.drawPlanet(in: context, rect: rect.insetBy(dx: -2, dy: -3), planet: black, ring: black, knockout: true)
            if busy {
                context.setFillColor(black)
                context.fillEllipse(in: CGRect(x: rect.maxX - 5, y: rect.maxY - 5, width: 4.5, height: 4.5))
            }
            return true
        }
        image.isTemplate = true
        return image
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

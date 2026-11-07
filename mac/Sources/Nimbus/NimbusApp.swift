import SwiftUI

@main
struct NimbusApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("Nimbus", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 520, minHeight: 640)
        }
        .windowResizability(.contentMinSize)
    }
}

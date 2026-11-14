import AppIntents

/// "Refresh All Apps" for the Shortcuts app, so a refresh can run from an automation: every
/// night, when the device starts charging, or with one tap from the Home Screen.
///
/// iOS runs the background task Nimbus asks for only when it feels like it. An automation
/// runs when you say.
struct RefreshAllAppsIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh All Apps"
    static let description = IntentDescription(
        "Refreshes the apps Nimbus looks after, so they keep working. LocalDevVPN has to be on, and Nimbus needs your remembered password."
    )

    /// Off for an automation that runs every day: each refresh signs in to Apple, and apps
    /// only need one about once a week.
    @Parameter(
        title: "Only When Needed",
        description: "Refresh only when an app expires within two days.",
        default: true
    )
    var onlyWhenNeeded: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Refresh all apps") {
            \.$onlyWhenNeeded
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = await PhoneModel.shared.refreshFromShortcut(onlyWhenNeeded: onlyWhenNeeded)
        guard outcome.succeeded else {
            throw RefreshFailure(message: outcome.message)
        }
        return .result(dialog: IntentDialog(stringLiteral: outcome.message))
    }
}

/// What Shortcuts shows when the refresh didn't work.
struct RefreshFailure: Error, CustomLocalizedStringResourceConvertible {
    let message: String

    var localizedStringResource: LocalizedStringResource {
        LocalizedStringResource(stringLiteral: message)
    }
}

/// Makes the action show up in Shortcuts and Spotlight without setting anything up.
struct NimbusShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RefreshAllAppsIntent(),
            phrases: [
                "Refresh my apps with \(.applicationName)",
                "Refresh all apps in \(.applicationName)",
            ],
            shortTitle: "Refresh All Apps",
            systemImageName: "arrow.clockwise"
        )
    }
}

/// An app Nimbus looks after, on the device or archived, for the Open App action.
struct NimbusAppEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "App"
    static let defaultQuery = NimbusAppQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct NimbusAppQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [NimbusAppEntity] {
        suggested().filter { identifiers.contains($0.id) }
    }

    @MainActor
    func suggestedEntities() async throws -> [NimbusAppEntity] {
        suggested()
    }

    @MainActor
    private func suggested() -> [NimbusAppEntity] {
        let model = PhoneModel.shared
        let apps = model.library.isEmpty ? Library.load() + Library.loadLocal() : model.refreshableApps + model.archivedApps
        var seen = Set<String>()
        return apps
            .filter { $0.bundleID != Bundle.main.bundleIdentifier && seen.insert($0.bundleID).inserted }
            .map { NimbusAppEntity(id: $0.bundleID, name: $0.name) }
    }
}

/// "Open App" for the Shortcuts app: opens an app Nimbus looks after, putting it back first
/// when it's archived. Added to the Home Screen, it works like the app's own icon, even for an
/// app that isn't on the device right now.
struct OpenAppIntent: AppIntent {
    static let title: LocalizedStringResource = "Open App"
    static let description = IntentDescription(
        "Opens an app Nimbus looks after. When it's archived, Nimbus puts it back first, archiving the app you used least when all slots are in use. LocalDevVPN has to be on."
    )

    @Parameter(title: "App")
    var app: NimbusAppEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$app)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = await PhoneModel.shared.openFromShortcut(app.id)
        guard outcome.succeeded else {
            throw RefreshFailure(message: outcome.message)
        }
        return .result(dialog: IntentDialog(stringLiteral: outcome.message))
    }
}

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

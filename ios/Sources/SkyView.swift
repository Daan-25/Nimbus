import SwiftUI

/// The top of the Apps tab.
struct SkyView: View {
    @Environment(PhoneModel.self) private var model

    var body: some View {
        SkyHeader(
            apps: model.refreshableApps.filter { model.isActive($0.bundleID) }.map { app in
                SkyApp(bundleID: app.bundleID, name: app.name, expires: model.expiry(of: app),
                       icon: model.icons[app.bundleID], iconURL: app.iconURL)
            },
            usedSlots: model.usedAppSlots,
            slots: PhoneModel.freeAppSlots,
            lifetime: PhoneModel.signatureLifetime,
            refreshWindow: PhoneModel.refreshWindow
        )
        .padding(.vertical, 8)
    }
}

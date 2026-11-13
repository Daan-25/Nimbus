import SwiftUI

/// A page about one app from a source: what it is, what it looks like and what's new.
/// `action` is the button that installs or updates it, which each app builds itself.
struct AppDetailView<Action: View>: View {
    let app: SourceApp
    let source: Source
    @ViewBuilder var action: Action

    @State private var showsAllNotes = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                if let screenshots = app.screenshots, !screenshots.isEmpty {
                    self.screenshots(screenshots)
                }
                if let about = app.about {
                    section("About") {
                        Text(about)
                            .textSelection(.enabled)
                    }
                }
                if app.releaseNotes != nil || app.releaseDate != nil {
                    whatsNew
                }
                information
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            AppIcon(url: app.iconURL, size: 88)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name)
                    .font(.title2.bold())
                if let line = app.subtitle ?? app.developer {
                    Text(line)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                action
            }
            .frame(minHeight: 88, alignment: .topLeading)
        }
    }

    private func screenshots(_ urls: [URL]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 12) {
                ForEach(urls, id: \.self) { url in
                    AsyncImage(url: url) { image in
                        image
                            .resizable()
                            .scaledToFit()
                    } placeholder: {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(.quaternary)
                            .frame(width: Self.screenshotHeight * 0.46)
                    }
                    .frame(height: Self.screenshotHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
            .padding(.horizontal)
        }
        .frame(height: Self.screenshotHeight)
        // The row runs to the edges of the page; only its first and last picture keep the margin.
        .padding(.horizontal, -16)
    }

    private static var screenshotHeight: CGFloat { 340 }

    private var whatsNew: some View {
        section("What's New") {
            HStack {
                if let version = app.version {
                    Text("Version \(version)")
                }
                Spacer()
                if let date = app.releaseDate {
                    Text(date.formatted(date: .abbreviated, time: .omitted))
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            if let notes = app.releaseNotes {
                Text(notes)
                    .lineLimit(showsAllNotes ? nil : 6)
                    .textSelection(.enabled)
                // Long notes start folded, so the rest of the page stays in reach.
                if !showsAllNotes && (notes.count > 300 || notes.filter(\.isNewline).count > 5) {
                    Button("More") { showsAllNotes = true }
                        .buttonStyle(.borderless)
                }
            }
        }
    }

    private var information: some View {
        section("Information") {
            VStack(spacing: 0) {
                row("Developer", app.developer)
                row("Version", app.versionKey)
                row("Size", app.size.flatMap { $0 > 0 ? Int64($0).formatted(.byteCount(style: .file)) : nil })
                row("Requires", app.minOSVersion.map { "iOS \($0) or later" })
                row("Source", source.name)
                row("Bundle ID", app.bundleID, isLast: true)
            }
        }
    }

    @ViewBuilder private func row(_ label: String, _ value: String?, isLast: Bool = false) -> some View {
        if let value {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 16)
                Text(value)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
            .font(.subheadline)
            .padding(.vertical, 8)
            if !isLast { Divider() }
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title3.bold())
            content()
        }
    }
}

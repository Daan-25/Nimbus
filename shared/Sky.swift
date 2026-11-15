import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

// MARK: Palette

/// Nimbus's colours: warm paper by day, a deep night sky in dark mode.
enum Palette {
    static let sky = dynamic(light: 0xF3EFE6, dark: 0x0D1220)
    static let card = dynamic(light: 0xFBF9F4, dark: 0x171D2E)
    static let line = dynamic(light: 0xD9D1C1, dark: 0x2C3552)
    /// The last days before an app expires, when Nimbus refreshes it.
    static let warm = dynamic(light: 0xC9741F, dark: 0xE9A54A)
    static let accent = dynamic(light: 0x2E5A88, dark: 0x9DBBE0)
    static let faint = dynamic(light: 0x8A8476, dark: 0x7D87A6)

    private static func components(_ hex: UInt32) -> (CGFloat, CGFloat, CGFloat) {
        (CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255)
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        #if canImport(UIKit)
        Color(UIColor { traits in
            let (r, g, b) = components(traits.userInterfaceStyle == .dark ? dark : light)
            return UIColor(red: r, green: g, blue: b, alpha: 1)
        })
        #else
        Color(NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let (r, g, b) = components(isDark ? dark : light)
            return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        })
        #endif
    }
}

// MARK: Icons

/// An app's home-screen icon, with the colour it gives off on average.
struct AppIconImage {
    let image: Image
    let color: Color

    init?(file: URL) {
        #if canImport(UIKit)
        guard let platformImage = UIImage(contentsOfFile: file.path), let cgImage = platformImage.cgImage else { return nil }
        image = Image(uiImage: platformImage)
        #else
        guard let platformImage = NSImage(contentsOf: file),
              let cgImage = platformImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        image = Image(nsImage: platformImage)
        #endif
        color = Self.averageColor(of: cgImage) ?? .gray
    }

    /// Draws the icon into a single pixel, which blends all its colours.
    private static func averageColor(of cgImage: CGImage) -> Color? {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let alpha = max(Double(pixel[3]) / 255, 0.01)
        return Color(
            red: Double(pixel[0]) / 255 / alpha,
            green: Double(pixel[1]) / 255 / alpha,
            blue: Double(pixel[2]) / 255 / alpha
        )
    }

    /// Every icon in a folder of <bundle ID>.png files, by bundle ID.
    static func load(from folder: URL) -> [String: AppIconImage] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var icons: [String: AppIconImage] = [:]
        for file in files where file.pathExtension == "png" {
            if let icon = AppIconImage(file: file) {
                icons[file.deletingPathExtension().lastPathComponent] = icon
            }
        }
        return icons
    }
}

// MARK: Sky

/// How long until an app expires, in plain words: "6 days left".
func timeLeft(until date: Date) -> String {
    let hours = Int(date.timeIntervalSinceNow / 3600)
    if hours < 24 { return hours <= 1 ? "Less than an hour left" : "\(hours) hours left" }
    let days = hours / 24
    return days == 1 ? "1 day left" : "\(days) days left"
}

/// An app as the sky shows it.
struct SkyApp {
    let bundleID: String
    let name: String
    let expires: Date
    let icon: AppIconImage?
    let iconURL: URL?
}

/// The state of the apps as weather, the slots in use, and every app as a body on an arc
/// that runs from today to seven days out. A refresh puts an app back at the far end.
struct SkyHeader: View {
    let apps: [SkyApp]
    /// Slots in use; nil when that isn't known.
    let usedSlots: Int?
    let slots: Int
    let lifetime: TimeInterval
    let refreshWindow: TimeInterval
    var arcHeight: CGFloat = 124

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                .font(.footnote)
                .foregroundStyle(Palette.faint)
            HStack(alignment: .center) {
                Text(weather.title)
                    .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                Spacer()
                slotView
            }
            Text(weather.detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SkyArc(bodies: planets, refreshFraction: refreshWindow / lifetime)
                .frame(height: arcHeight)
                .padding(.top, 14)
        }
    }

    private struct Weather {
        let title: String
        let detail: String
    }

    private var weather: Weather {
        let sorted = apps.sorted { $0.expires < $1.expires }
        guard let first = sorted.first else {
            return Weather(title: "Open sky", detail: "No apps yet. Find some under Browse.")
        }
        let expired = sorted.filter { $0.expires < .now }
        if !expired.isEmpty {
            let names = ListFormatter.localizedString(byJoining: expired.map(\.name))
            return Weather(title: "Stormy", detail: "\(names) \(expired.count == 1 ? "has" : "have") expired. Refresh to use \(expired.count == 1 ? "it" : "them") again.")
        }
        if first.expires.timeIntervalSinceNow < refreshWindow {
            let when = first.expires.formatted(.relative(presentation: .named))
            return Weather(title: "Clouds ahead", detail: "\(first.name) expires \(when). Nimbus refreshes it when it can.")
        }
        let days = Int(first.expires.timeIntervalSinceNow / 86_400)
        return Weather(title: "Clear", detail: "Every app is good for at least \(days) more \(days == 1 ? "day" : "days").")
    }

    /// The free Apple ID's slots on the device, filled for each one in use.
    @ViewBuilder private var slotView: some View {
        if let used = usedSlots {
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 4) {
                    ForEach(0..<slots, id: \.self) { index in
                        Capsule()
                            .strokeBorder(Palette.accent, lineWidth: 1.5)
                            .background(Capsule().fill(index < used ? Palette.accent : .clear))
                            .frame(width: 14, height: 22)
                    }
                }
                Text("\(used) of \(slots) slots")
                    .font(.caption2)
                    .foregroundStyle(Palette.faint)
            }
            .accessibilityElement()
            .accessibilityLabel("\(used) of \(slots) app slots in use")
        }
    }

    private var planets: [SkyArc.Planet] {
        apps.map { app in
            let remaining = app.expires.timeIntervalSinceNow
            return SkyArc.Planet(
                id: app.bundleID,
                name: app.name,
                position: min(max(remaining / lifetime, 0), 1),
                expired: remaining < 0,
                icon: app.icon,
                fallbackURL: app.iconURL
            )
        }
    }
}

/// The arc itself, with a body on it for each app.
struct SkyArc: View {
    struct Planet: Identifiable {
        let id: String
        let name: String
        /// 0 is expiring now, 1 is seven days out.
        let position: Double
        let expired: Bool
        let icon: AppIconImage?
        let fallbackURL: URL?
    }

    let bodies: [Planet]
    /// The part of the arc, from today, in which apps get refreshed.
    let refreshFraction: Double
    private let size: CGFloat = 34

    var body: some View {
        GeometryReader { proxy in
            let geometry = ArcGeometry(width: proxy.size.width, height: proxy.size.height, inset: size / 2 + 2)
            ZStack(alignment: .topLeading) {
                // The days, from today on the left to a week out on the right.
                geometry.path(from: 0, to: 1)
                    .stroke(Palette.line, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                geometry.path(from: 0, to: refreshFraction)
                    .stroke(Palette.warm, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                ForEach(0...7, id: \.self) { day in
                    let point = geometry.point(at: Double(day) / 7)
                    Circle()
                        .fill(Double(day) / 7 <= refreshFraction ? Palette.warm : Palette.line)
                        .frame(width: 4, height: 4)
                        .position(point)
                }
                Text("Today")
                    .position(x: geometry.point(at: 0).x, y: proxy.size.height - 6)
                Text("7 days")
                    .position(x: geometry.point(at: 1).x, y: proxy.size.height - 6)

                ForEach(placed(along: geometry), id: \.body.id) { placed in
                    planet(placed.body)
                        .position(geometry.point(at: placed.position))
                }
            }
            .font(.caption2)
            .foregroundStyle(Palette.faint)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(bodies.map(\.name).joined(separator: ", "))
    }

    private func planet(_ body: Planet) -> some View {
        Group {
            if let icon = body.icon {
                icon.image.resizable().scaledToFill()
            } else {
                AsyncImage(url: body.fallbackURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Palette.accent
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        // A gap in the sky's own colour keeps bodies that overlap apart.
        .padding(2.5)
        .background(Circle().fill(Palette.sky))
        .overlay(
            Circle().strokeBorder(body.expired ? Color.red : (body.icon?.color ?? Palette.accent).opacity(0.9), lineWidth: 1.5)
        )
    }

    private struct Placed {
        let body: Planet
        let position: Double
    }

    /// Spreads out bodies that would cover each other, keeping their order.
    private func placed(along geometry: ArcGeometry) -> [Placed] {
        // Apps that expire close together overlap a little, like coins in a row, so each stays
        // near its own day.
        let gap = Double(size * 0.62) / geometry.length
        var positions = bodies.sorted { $0.position < $1.position }.map { (body: $0, position: $0.position) }
        guard !positions.isEmpty else { return [] }
        for index in positions.indices.dropFirst() {
            positions[index].position = max(positions[index].position, positions[index - 1].position + gap)
        }
        // Pushed past the end: walk back from there.
        if let last = positions.indices.last, positions[last].position > 1 {
            positions[last].position = 1
            for index in positions.indices.dropLast().reversed() {
                positions[index].position = min(positions[index].position, positions[index + 1].position - gap)
            }
        }
        return positions.map { Placed(body: $0.body, position: min(max($0.position, 0), 1)) }
    }
}

/// A shallow circular arc across a rectangle, rising from the bottom corners.
private struct ArcGeometry {
    let center: CGPoint
    let radius: CGFloat
    /// Half the angle the arc spans.
    let halfAngle: Double

    init(width: CGFloat, height: CGFloat, inset: CGFloat) {
        let chord = width - inset * 2
        // A low arc, like the sky's path over a horizon, with room below its ends for labels.
        let bottom = height - 30
        let rise = min(bottom - inset, chord * 0.2)
        radius = (chord * chord / 4 + rise * rise) / (2 * rise)
        center = CGPoint(x: width / 2, y: bottom - rise + radius)
        halfAngle = asin(Double(chord / 2 / radius))
    }

    var length: Double { Double(radius) * halfAngle * 2 }

    /// A point on the arc; 0 is the left end, 1 the right.
    func point(at position: Double) -> CGPoint {
        let angle = -halfAngle + 2 * halfAngle * position
        return CGPoint(x: center.x + radius * CGFloat(sin(angle)), y: center.y - radius * CGFloat(cos(angle)))
    }

    func path(from start: Double, to end: Double) -> Path {
        Path { path in
            let steps = 48
            for step in 0...steps {
                let point = point(at: start + (end - start) * Double(step) / Double(steps))
                if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
    }
}

import CoreGraphics
import CoreText
import Foundation

/// The picture behind the icons in the disk image's window: space, with Nimbus on one
/// landing pad, Applications on the other, and a flight path between them.
///
/// Finder puts the icons on top. Their places here have to match scripts/dmg-settings.py.
enum DiskImageBackground {
    /// In points. The window shows the top of it; the picture is a little taller than the
    /// window so no edge can show.
    static let size = CGSize(width: 640, height: 440)
    /// Where the icons' centers are, measured from the top left as Finder does.
    static let appCenter = CGPoint(x: 170, y: 170)
    static let applicationsCenter = CGPoint(x: 470, y: 170)

    private static let colors = CGColorSpaceCreateDeviceRGB()

    private static func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(colorSpace: colors, components: [red, green, blue, alpha])!
    }

    /// Draws at `scale` pixels per point, with the origin at the bottom left.
    static func draw(in context: CGContext, scale: CGFloat) {
        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        let width = size.width, height = size.height

        // Space.
        let sky = CGGradient(colorsSpace: colors, colors: [color(0.13, 0.16, 0.34), color(0.04, 0.05, 0.13)] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(sky, start: CGPoint(x: 0, y: height), end: CGPoint(x: width * 0.3, y: 0),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

        // Stars, always the same ones.
        var seed: UInt64 = 20261113
        func random() -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat((seed >> 33) % 10_000) / 10_000
        }
        for _ in 0..<170 {
            let x = random() * width, y = random() * height
            let radius = 0.4 + random() * random() * 1.5
            context.setFillColor(color(1, 1, 1, 0.25 + random() * 0.65))
            context.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
        }
        // A few that twinkle.
        for (x, y, reach) in [(92.0, 396.0, 7.0), (566.0, 318.0, 5.0), (312.0, 408.0, 4.0), (604.0, 64.0, 6.0), (38.0, 150.0, 4.0)] {
            context.setStrokeColor(color(1, 1, 1, 0.8))
            context.setLineWidth(1)
            context.setLineCap(.round)
            context.move(to: CGPoint(x: x - reach, y: y))
            context.addLine(to: CGPoint(x: x + reach, y: y))
            context.move(to: CGPoint(x: x, y: y - reach))
            context.addLine(to: CGPoint(x: x, y: y + reach))
            context.strokePath()
        }

        // The ring of a planet too large to fit, sweeping through the window.
        context.saveGState()
        context.translateBy(x: width * 0.5, y: -height * 0.12)
        context.rotate(by: 9 * .pi / 180)
        let ring = CGRect(x: -width * 0.78, y: -height * 0.34, width: width * 1.56, height: height * 0.68)
        context.setStrokeColor(color(0.56, 0.71, 1, 0.10))
        context.setLineWidth(34)
        context.strokeEllipse(in: ring)
        context.setStrokeColor(color(0.56, 0.71, 1, 0.28))
        context.setLineWidth(1.5)
        context.strokeEllipse(in: ring.insetBy(dx: -17, dy: -17))
        context.strokeEllipse(in: ring.insetBy(dx: 17, dy: 17))
        context.restoreGState()

        // A small neighbour in the corner.
        NimbusIcon.drawPlanet(in: context, rect: CGRect(x: 548, y: 356, width: 78, height: 78),
                              planet: color(0.56, 0.71, 1, 0.55), ring: color(1, 1, 1, 0.35))

        // Landing pads. Finder writes the icons' names in black or white depending on the
        // Mac's appearance, so the pads are a blue that both can be read on.
        let app = CGPoint(x: appCenter.x, y: height - appCenter.y)
        let applications = CGPoint(x: applicationsCenter.x, y: height - applicationsCenter.y)
        for center in [app, applications] {
            let pad = CGRect(x: center.x - 84, y: center.y - 100, width: 168, height: 184)
            let shape = CGPath(roundedRect: pad, cornerWidth: 30, cornerHeight: 30, transform: nil)
            context.addPath(shape)
            context.setFillColor(color(0.36, 0.43, 0.72, 0.92))
            context.fillPath()
            context.addPath(shape)
            context.setStrokeColor(color(0.72, 0.82, 1, 0.55))
            context.setLineWidth(1)
            context.strokePath()
        }

        // The flight path from one pad to the other.
        let start = CGPoint(x: app.x + 96, y: app.y + 18)
        let end = CGPoint(x: applications.x - 104, y: applications.y + 18)
        let control = CGPoint(x: (start.x + end.x) / 2, y: start.y + 62)
        context.setStrokeColor(color(1, 1, 1, 0.9))
        context.setLineWidth(3)
        context.setLineCap(.round)
        context.setLineDash(phase: 0, lengths: [0.1, 10])
        context.move(to: start)
        context.addQuadCurve(to: end, control: control)
        context.strokePath()
        context.setLineDash(phase: 0, lengths: [])
        // The arrowhead follows the end of the curve.
        let angle = atan2(end.y - control.y, end.x - control.x)
        context.saveGState()
        context.translateBy(x: end.x + 7, y: end.y - 7)
        context.rotate(by: angle)
        context.setLineJoin(.round)
        context.move(to: CGPoint(x: -11, y: 8))
        context.addLine(to: CGPoint(x: 0, y: 0))
        context.addLine(to: CGPoint(x: -11, y: -8))
        context.strokePath()
        context.restoreGState()

        text("Drag Nimbus to Applications", size: 19, bold: true, color: color(1, 1, 1), centerX: width / 2, baseline: 132, in: context)
        text("First time opening it? macOS asks you to allow it under", size: 11.5, bold: false,
             color: color(0.72, 0.82, 1, 0.9), centerX: width / 2, baseline: 104, in: context)
        text("System Settings → Privacy & Security → Open Anyway.", size: 11.5, bold: false,
             color: color(0.72, 0.82, 1, 0.9), centerX: width / 2, baseline: 88, in: context)

        context.restoreGState()
    }

    private static func text(_ string: String, size: CGFloat, bold: Bool, color: CGColor, centerX: CGFloat, baseline: CGFloat, in context: CGContext) {
        var font = CTFontCreateUIFontForLanguage(.system, size, nil)!
        if bold, let heavier = CTFontCreateCopyWithSymbolicTraits(font, size, nil, .traitBold, .traitBold) {
            font = heavier
        }
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        context.textPosition = CGPoint(x: centerX - lineWidth / 2, y: baseline)
        CTLineDraw(line, context)
    }
}

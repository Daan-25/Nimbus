import CoreGraphics

/// Nimbus's icon: a planet with a ring. Drawn in code, so the app icons and the menu bar
/// icon come from one shape and scale to any size.
enum NimbusIcon {
    /// Draws the planet in the middle of `rect`. The ring goes behind the planet at the back
    /// and in front of it at the front.
    ///
    /// With `knockout`, the ring clears a gap where it crosses the planet. That keeps it
    /// visible when planet and ring have the same color, as in the menu bar.
    static func drawPlanet(in context: CGContext, rect: CGRect, planet: CGColor, ring: CGColor, knockout: Bool = false) {
        let unit = min(rect.width, rect.height)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = unit * 0.21
        let ringBox = CGRect(x: -unit * 0.40, y: -unit * 0.11, width: unit * 0.80, height: unit * 0.22)
        let lineWidth = unit * 0.06

        context.saveGState()
        context.translateBy(x: center.x, y: center.y)
        // Tilted, with the right side up.
        context.rotate(by: 20 * .pi / 180)
        context.setLineWidth(lineWidth)

        // The far half of the ring.
        context.setStrokeColor(ring)
        context.strokeEllipse(in: ringBox)

        context.setFillColor(planet)
        context.rotate(by: -20 * .pi / 180)
        context.fillEllipse(in: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2))
        context.rotate(by: 20 * .pi / 180)

        // The near half, over the planet: everything below the ring's long axis.
        context.clip(to: CGRect(x: -unit, y: -unit, width: unit * 2, height: unit))
        if knockout {
            context.setBlendMode(.clear)
            context.setLineWidth(lineWidth * 1.9)
            context.strokeEllipse(in: ringBox)
            context.setBlendMode(.normal)
            context.setLineWidth(lineWidth)
        }
        context.strokeEllipse(in: ringBox)
        context.restoreGState()
    }

    /// Draws the app icon in a square of `size`. On the Mac the icon is a rounded tile with
    /// room around it, as macOS icons are; on iOS it fills the square and the system rounds it.
    static func drawAppIcon(in context: CGContext, size: CGFloat, forMac: Bool) {
        let colors = CGColorSpaceCreateDeviceRGB()
        let top = CGColor(colorSpace: colors, components: [0.16, 0.20, 0.40, 1])!
        let bottom = CGColor(colorSpace: colors, components: [0.07, 0.09, 0.19, 1])!
        let tile = forMac
            ? CGRect(x: size * 0.098, y: size * 0.098, width: size * 0.804, height: size * 0.804)
            : CGRect(x: 0, y: 0, width: size, height: size)

        context.saveGState()
        if forMac {
            let shape = CGPath(roundedRect: tile, cornerWidth: tile.width * 0.2237, cornerHeight: tile.width * 0.2237, transform: nil)
            context.setShadow(offset: CGSize(width: 0, height: -size * 0.012), blur: size * 0.03,
                              color: CGColor(colorSpace: colors, components: [0, 0, 0, 0.35]))
            context.addPath(shape)
            context.setFillColor(bottom)
            context.fillPath()
            context.setShadow(offset: .zero, blur: 0, color: nil)
            context.addPath(shape)
            context.clip()
        }
        let gradient = CGGradient(colorsSpace: colors, colors: [top, bottom] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: tile.midX, y: tile.maxY), end: CGPoint(x: tile.midX, y: tile.minY), options: [])
        context.restoreGState()

        drawPlanet(
            in: context,
            rect: tile.insetBy(dx: tile.width * 0.04, dy: tile.width * 0.04),
            planet: CGColor(colorSpace: colors, components: [1, 1, 1, 1])!,
            ring: CGColor(colorSpace: colors, components: [0.56, 0.71, 1, 1])!
        )
    }
}

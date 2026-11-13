import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Renders Nimbus's icons as PNG files: the sizes a Mac icon needs, the one an iOS icon
/// needs, and a large menu bar icon to look at. See scripts/make-icons.sh.
@main
struct MakeIcons {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            print("Usage: make-icons FOLDER")
            exit(1)
        }
        let folder = URL(fileURLWithPath: CommandLine.arguments[1])
        let iconset = folder.appendingPathComponent("Nimbus.iconset")
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
                try write(size: points * scale, to: iconset.appendingPathComponent(name)) { context, size in
                    NimbusIcon.drawAppIcon(in: context, size: size, forMac: true)
                }
            }
        }
        // iOS icons have no transparency; the system rounds the corners.
        try write(size: 1024, opaque: true, to: folder.appendingPathComponent("ios-1024.png")) { context, size in
            NimbusIcon.drawAppIcon(in: context, size: size, forMac: false)
        }
        try write(size: 256, to: folder.appendingPathComponent("menu-bar-preview.png")) { context, size in
            let black = CGColor(gray: 0, alpha: 1)
            NimbusIcon.drawPlanet(in: context, rect: CGRect(x: 0, y: 0, width: size, height: size),
                                  planet: black, ring: black, knockout: true)
        }
    }

    static func write(size: Int, opaque: Bool = false, to url: URL, draw: (CGContext, CGFloat) -> Void) throws {
        let alpha = opaque ? CGImageAlphaInfo.noneSkipLast : CGImageAlphaInfo.premultipliedLast
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: alpha.rawValue)
        else { throw CocoaError(.fileWriteUnknown) }
        draw(context, CGFloat(size))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}

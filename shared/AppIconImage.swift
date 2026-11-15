import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// An app's icon as the device's home screen shows it.
struct AppIconImage {
    let image: Image

    init?(file: URL) {
        #if canImport(UIKit)
        guard let platformImage = UIImage(contentsOfFile: file.path) else { return nil }
        image = Image(uiImage: platformImage)
        #else
        guard let platformImage = NSImage(contentsOf: file) else { return nil }
        image = Image(nsImage: platformImage)
        #endif
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

/// How long until an app expires, in plain words: "6 days left".
func timeLeft(until date: Date) -> String {
    let hours = Int(date.timeIntervalSinceNow / 3600)
    if hours < 24 { return hours <= 1 ? "Less than an hour left" : "\(hours) hours left" }
    let days = hours / 24
    return days == 1 ? "1 day left" : "\(days) days left"
}

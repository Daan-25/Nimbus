import Foundation

/// Stores the apps Nimbus installed in ~/Library/Application Support/Nimbus.
enum Library {
    static let folder: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nimbus", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let ipaFolder: URL = {
        let url = folder.appendingPathComponent("IPAs", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private static let file = folder.appendingPathComponent("library.json")

    static func load() -> [LibraryApp] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([LibraryApp].self, from: data)) ?? []
    }

    static func save(_ apps: [LibraryApp]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(apps).write(to: file, options: .atomic)
    }

    /// Copies an IPA into the library, so it can still be refreshed after the original is gone.
    static func importIPA(_ url: URL) throws -> String {
        let name = UUID().uuidString + ".ipa"
        try FileManager.default.copyItem(at: url, to: ipaFolder.appendingPathComponent(name))
        return name
    }

    /// Replaces a stored IPA with a newer one, keeping its file name.
    static func replaceIPA(_ name: String, with url: URL) {
        let target = ipaFolder.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return }
        try? data.write(to: target, options: .atomic)
    }

    static func deleteIPA(_ name: String) {
        try? FileManager.default.removeItem(at: ipaFolder.appendingPathComponent(name))
    }
}

/// The parts of an IPA's Info.plist that Nimbus needs before installing.
struct IPAInfo {
    let bundleID: String
    let name: String

    /// Reads Payload/<App>.app/Info.plist without unpacking the whole archive.
    static func read(_ url: URL) -> IPAInfo? {
        guard let listing = run("/usr/bin/zipinfo", ["-1", url.path]),
              let entry = String(decoding: listing, as: UTF8.self)
                .split(separator: "\n")
                .map(String.init)
                .first(where: isMainInfoPlist),
              // unzip treats these characters as wildcards.
              let data = run("/usr/bin/unzip", ["-p", url.path, escapeWildcards(entry)]),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundleID = plist["CFBundleIdentifier"] as? String
        else { return nil }
        let name = plist["CFBundleDisplayName"] as? String ?? plist["CFBundleName"] as? String
            ?? url.deletingPathExtension().lastPathComponent
        return IPAInfo(bundleID: bundleID, name: name)
    }

    /// Matches Payload/<App>.app/Info.plist, not the Info.plist files of frameworks and extensions.
    private static func isMainInfoPlist(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 3 && parts[0] == "Payload" && parts[1].hasSuffix(".app") && parts[2] == "Info.plist"
    }

    private static func escapeWildcards(_ path: String) -> String {
        var escaped = ""
        for character in path {
            if "[]*?\\".contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }

    private static func run(_ tool: String, _ arguments: [String]) -> Data? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }
}

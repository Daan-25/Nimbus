import CryptoKit
import Foundation

/// An AltStore source: a JSON file on the web that lists apps and where to download them.
struct Source: Codable, Hashable, Identifiable {
    var url: URL
    var name: String
    var subtitle: String?
    var iconURL: URL?
    var apps: [SourceApp]

    var id: URL { url }
}

/// The newest version of an app in a source.
struct SourceApp: Codable, Hashable, Identifiable {
    /// Bundle ID as the developer ships it, without a team ID.
    var bundleID: String
    var name: String
    var developer: String?
    var subtitle: String?
    var iconURL: URL?
    var version: String?
    var build: String?
    var downloadURL: URL
    var size: Int?
    var sha256: String?
    var minOSVersion: String?
    /// What the app is, in the developer's words.
    var about: String?
    var screenshots: [URL]?
    /// What's new in this release.
    var releaseNotes: String?
    var releaseDate: Date?

    var id: String { bundleID }

    /// Identifies this release, to tell whether an installed app is out of date.
    var versionKey: String? {
        guard let version else { return build }
        return build.map { "\(version) (\($0))" } ?? version
    }
}

enum SourceError: LocalizedError {
    case invalidURL
    case notASource
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL: "That isn't a valid source address. It has to start with https://."
        case .notASource: "This address doesn't contain an AltStore source."
        case .http(let code): "The server answered with error \(code)."
        }
    }
}

enum SourceLoader {
    /// Sources Nimbus suggests when you add one.
    static let suggestions: [(name: String, url: URL)] = [
        ("AltStore", URL(string: "https://apps.altstore.io")!),
        ("SideStore Community", URL(string: "https://community-apps.sidestore.io/sidecommunity.json")!),
    ]

    /// Turns what the user typed or pasted into a source address. Accepts plain addresses and
    /// the altstore://source?url=… links that websites use for their "Add to AltStore" buttons.
    static func parseURL(_ text: String) -> URL? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let components = URLComponents(string: text),
           let scheme = components.scheme?.lowercased(), scheme == "altstore" || scheme == "sidestore",
           let inner = components.queryItems?.first(where: { $0.name == "url" })?.value {
            text = inner
        }
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), isSecure(url) else { return nil }
        return url
    }

    static func isSecure(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && !(url.host ?? "").isEmpty
    }

    static func load(_ url: URL) async throws -> Source {
        guard isSecure(url) else { throw SourceError.invalidURL }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SourceError.http(http.statusCode)
        }
        return try parse(data, url: url)
    }

    static func parse(_ data: Data, url: URL) throws -> Source {
        guard let raw = try? JSONDecoder().decode(RawSource.self, from: data), let rawApps = raw.apps else {
            throw SourceError.notASource
        }
        var seen = Set<String>()
        let apps = rawApps.compactMap { $0.value?.app(relativeTo: url) }.filter { seen.insert($0.bundleID).inserted }
        return Source(
            url: url,
            name: raw.name?.trimmed ?? url.host ?? url.absoluteString,
            subtitle: raw.subtitle?.trimmed,
            iconURL: secureURL(raw.iconURL, relativeTo: url),
            apps: apps
        )
    }

    fileprivate static func secureURL(_ text: String?, relativeTo base: URL) -> URL? {
        guard let text = text?.trimmed, let url = URL(string: text, relativeTo: base)?.absoluteURL, isSecure(url) else {
            return nil
        }
        return url
    }

    // MARK: Cache

    private static let file = Library.folder.appendingPathComponent("sources.json")

    static func loadCache() -> [Source] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([Source].self, from: data)) ?? []
    }

    static func saveCache(_ sources: [Source]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try? encoder.encode(sources).write(to: file, options: .atomic)
    }
}

// MARK: Source JSON

// Sources are written by hand and by many different tools, so every field is optional and
// an app Nimbus can't read is skipped instead of failing the whole source.

private struct RawSource: Decodable {
    var name: String?
    var subtitle: String?
    var iconURL: String?
    var apps: [Lossy<RawApp>]?
}

private struct RawApp: Decodable {
    var name: String?
    var bundleIdentifier: String?
    var developerName: String?
    var subtitle: String?
    var iconURL: String?
    var versions: [Lossy<RawVersion>]?
    var patreon: Lossy<[String: Lossy<String>]>?
    var localizedDescription: String?
    var screenshots: Lossy<RawScreenshots>?
    // Older sources list screenshots here.
    var screenshotURLs: [Lossy<String>]?
    var versionDate: String?
    var versionDescription: String?
    // Older sources describe the newest version on the app itself.
    var version: String?
    var downloadURL: String?
    var size: Lossy<Int>?
    var sha256: String?
    var minOSVersion: String?

    func app(relativeTo base: URL) -> SourceApp? {
        guard let bundleID = bundleIdentifier?.trimmed, let name = name?.trimmed else { return nil }
        // Apps for Patreon supporters need a Patreon sign-in to download, which Nimbus doesn't have.
        if patreon?.value != nil { return nil }
        // Versions are listed newest first.
        let newest = versions?.compactMap(\.value).first { $0.downloadURL != nil }
        guard let downloadURL = SourceLoader.secureURL(newest?.downloadURL ?? downloadURL, relativeTo: base) else {
            return nil
        }
        return SourceApp(
            bundleID: bundleID,
            name: name,
            developer: developerName?.trimmed,
            subtitle: subtitle?.trimmed,
            iconURL: SourceLoader.secureURL(iconURL, relativeTo: base),
            version: newest != nil ? newest?.version?.trimmed : version?.trimmed,
            build: newest?.buildVersion?.trimmed,
            downloadURL: downloadURL,
            size: newest != nil ? newest?.size?.value : size?.value,
            sha256: (newest != nil ? newest?.sha256 : sha256)?.trimmed?.lowercased(),
            minOSVersion: (newest != nil ? newest?.minOSVersion : minOSVersion)?.trimmed,
            about: localizedDescription?.trimmed,
            screenshots: screenshots(relativeTo: base),
            releaseNotes: (newest != nil ? newest?.localizedDescription : versionDescription)?.trimmed,
            releaseDate: (newest != nil ? newest?.date : versionDate).flatMap(Self.date)
        )
    }

    private func screenshots(relativeTo base: URL) -> [URL]? {
        let listed = screenshots?.value?.urls ?? []
        let texts = listed.isEmpty ? (screenshotURLs ?? []).compactMap(\.value) : listed
        let urls = texts.compactMap { SourceLoader.secureURL($0, relativeTo: base) }
        // A page shows a handful; some sources list dozens.
        return urls.isEmpty ? nil : Array(urls.prefix(10))
    }

    /// Sources write dates with or without a time and fractional seconds.
    private static func date(_ text: String) -> Date? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [
            [.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds], [.withFullDate],
        ] {
            formatter.formatOptions = options
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}

/// Screenshots come as a list or grouped by device, each one an address or an object with one.
private struct RawScreenshots: Decodable {
    var urls: [String]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let list = try? container.decode([Lossy<RawScreenshot>].self) {
            urls = list.compactMap(\.value?.url)
        } else if let groups = try? container.decode([String: Lossy<[Lossy<RawScreenshot>]>].self) {
            // iPhone screenshots first; they fit every screen Nimbus shows them on.
            let order = groups.keys.sorted { ($0.lowercased() == "iphone" ? 0 : 1, $0) < ($1.lowercased() == "iphone" ? 0 : 1, $1) }
            urls = order.flatMap { groups[$0]?.value ?? [] }.compactMap(\.value?.url)
        } else {
            urls = []
        }
    }
}

private struct RawScreenshot: Decodable {
    var url: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            url = text
        } else {
            url = try container.decode([String: Lossy<String>].self)["imageURL"]?.value ?? ""
        }
    }
}

private struct RawVersion: Decodable {
    var date: String?
    var localizedDescription: String?
    var version: String?
    var buildVersion: String?
    var downloadURL: String?
    var size: Lossy<Int>?
    var sha256: String?
    var minOSVersion: String?
}

/// Decodes to nil instead of failing when a value has an unexpected shape.
private struct Lossy<Value: Decodable>: Decodable {
    var value: Value?

    init(from decoder: Decoder) throws {
        value = try? decoder.singleValueContainer().decode(Value.self)
    }
}

private extension String {
    /// Without surrounding whitespace; nil when nothing is left.
    var trimmed: String? {
        let text = trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

// MARK: Downloads

/// Downloads a file while reporting progress.
final class Download {
    private let task: URLSessionDownloadTask
    private var observation: NSKeyValueObservation?

    /// `completion` runs on the main actor once the file is at `destination`, or with the error.
    @MainActor
    init(
        _ url: URL,
        to destination: URL,
        onProgress: @escaping @MainActor (Double) -> Void,
        completion: @escaping @MainActor (Result<Void, Error>) -> Void
    ) {
        task = URLSession.shared.downloadTask(with: url) { file, response, error in
            let result: Result<Void, Error>
            if let error {
                result = .failure(error)
            } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                result = .failure(SourceError.http(http.statusCode))
            } else if let file {
                // The temporary file is gone as soon as this handler returns.
                result = Result(catching: { try FileManager.default.moveItem(at: file, to: destination) })
            } else {
                result = .failure(URLError(.badServerResponse))
            }
            Task { @MainActor in completion(result) }
        }
        observation = task.progress.observe(\.fractionCompleted) { progress, _ in
            let fraction = progress.fractionCompleted
            Task { @MainActor in onProgress(fraction) }
        }
        task.resume()
    }

    func cancel() {
        observation = nil
        task.cancel()
    }
}

extension Library {
    /// SHA-256 of a file as lowercase hex, read in pieces so large apps don't fill memory.
    static func sha256(of url: URL) async -> String? {
        await Task.detached(priority: .userInitiated) {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }
}

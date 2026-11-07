import Foundation

enum HelperError: LocalizedError {
    case notFound
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notFound: "nimbus-helper is missing from the app bundle."
        case .failed(let message): message
        }
    }
}

/// Runs nimbus-helper and streams its events.
final class Helper: @unchecked Sendable {
    static var executableURL: URL? {
        if let override = ProcessInfo.processInfo.environment["NIMBUS_HELPER"] {
            return URL(fileURLWithPath: override)
        }
        return Bundle.main.url(forAuxiliaryExecutable: "nimbus-helper")
    }

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()

    init(arguments: [String]) throws {
        guard let url = Helper.executableURL else { throw HelperError.notFound }
        process.executableURL = url
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
    }

    /// Starts the helper. `onEvent` and `onLog` are called on the main actor.
    func start(
        onEvent: @escaping @MainActor (HelperEvent) -> Void,
        onLog: @escaping @MainActor (String) -> Void,
        onExit: @escaping @MainActor (Int32) -> Void
    ) throws {
        let stdout = output.fileHandleForReading
        let stderr = errors.fileHandleForReading
        let process = process

        try process.run()

        Task.detached {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    do {
                        for try await line in stdout.bytes.lines {
                            if let event = HelperEvent.decode(line) {
                                await onEvent(event)
                            }
                        }
                    } catch {}
                }
                group.addTask {
                    do {
                        for try await line in stderr.bytes.lines {
                            await onLog(line)
                        }
                    } catch {}
                }
            }
            process.waitUntilExit()
            await onExit(process.terminationStatus)
        }
    }

    func send(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        try? input.fileHandleForWriting.write(contentsOf: data)
    }

    func cancel() {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    /// Runs a command that prints a single event and exits.
    static func runOnce(_ arguments: [String]) async throws -> HelperEvent {
        guard let url = executableURL else { throw HelperError.notFound }
        return try await Task.detached {
            let process = Process()
            let output = Pipe()
            process.executableURL = url
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
            guard let event = lines.compactMap({ HelperEvent.decode(String($0)) }).last else {
                throw HelperError.failed("nimbus-helper gave no answer.")
            }
            if event.event == "error" { throw HelperError.failed(event.message ?? "Unknown error") }
            return event
        }.value
    }
}

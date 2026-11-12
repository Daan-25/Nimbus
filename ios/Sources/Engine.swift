import Foundation

/// Runs the Nimbus engine, which is linked into the app. The Mac app runs the same engine
/// as a separate tool; see core/src/ffi.rs.
enum Engine {
    enum Failure: LocalizedError {
        case message(String)

        var errorDescription: String? {
            switch self {
            case .message(let message): message
            }
        }
    }

    /// The engine runs one command at a time and blocks until it's finished.
    private static let queue = DispatchQueue(label: "io.github.daan-25.nimbus.engine")

    private final class Handler {
        let onEvent: (HelperEvent) -> Void
        init(_ onEvent: @escaping (HelperEvent) -> Void) { self.onEvent = onEvent }
    }

    static func configure(_ config: [String: Any]) {
        guard let json = text(config) else { return }
        _ = nimbus_configure(json)
    }

    /// Runs a command. Events arrive on a background thread. Returns whether it succeeded.
    @discardableResult
    static func run(
        _ command: String,
        args: [String] = [],
        request: [String: Any]? = nil,
        onEvent: @escaping @Sendable (HelperEvent) -> Void
    ) async -> Bool {
        var message: [String: Any] = ["command": command, "args": args]
        if let request { message["request"] = request }
        guard let json = text(message) else { return false }

        return await withCheckedContinuation { continuation in
            queue.async {
                let handler = Unmanaged.passRetained(Handler(onEvent))
                let succeeded = nimbus_run(json, { context, json in
                    guard let context, let json, let event = HelperEvent.decode(String(cString: json)) else { return }
                    Unmanaged<Handler>.fromOpaque(context).takeUnretainedValue().onEvent(event)
                }, handler.toOpaque())
                handler.release()
                continuation.resume(returning: succeeded)
            }
        }
    }

    /// Runs a command that answers with a single event.
    static func runOnce(_ command: String, args: [String] = []) async throws -> HelperEvent {
        let events = Collector()
        await run(command, args: args) { events.add($0) }
        if let error = events.all.first(where: { $0.event == "error" }) {
            throw Failure.message(error.message ?? "Unknown error")
        }
        guard let event = events.all.last(where: { $0.event != "log" }) else {
            throw Failure.message("The engine didn't answer.")
        }
        return event
    }

    static func reply(_ reply: [String: Any]) {
        guard let json = text(reply) else { return }
        nimbus_reply(json)
    }

    static func cancel() {
        nimbus_cancel()
    }

    private static func text(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [HelperEvent] = []

        func add(_ event: HelperEvent) {
            lock.lock()
            events.append(event)
            lock.unlock()
        }

        var all: [HelperEvent] {
            lock.lock()
            defer { lock.unlock() }
            return events
        }
    }
}

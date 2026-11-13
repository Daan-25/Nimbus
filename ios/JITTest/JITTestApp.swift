import SwiftUI

/// A tiny app that checks whether JIT works: it waits for a debugger, asks it for executable
/// memory the way emulators do on iOS 26 and later, and runs code it wrote there itself.
/// Start it with Enable JIT in Nimbus.
@main
struct JITTestApp: App {
    var body: some Scene {
        WindowGroup {
            TestView()
        }
    }
}

struct TestView: View {
    enum Outcome {
        case waiting
        case noDebugger
        case worked
        case failed(String)
    }

    @State private var outcome = Outcome.waiting

    var body: some View {
        VStack(spacing: 16) {
            switch outcome {
            case .waiting:
                ProgressView()
                Text("Waiting for a debugger…")
                    .font(.title3)
            case .noDebugger:
                Image(systemName: "bolt.slash").font(.system(size: 56)).foregroundStyle(.orange)
                Text("No debugger attached")
                    .font(.title3.bold())
                Text("Open this app with Enable JIT in Nimbus.")
                    .foregroundStyle(.secondary)
            case .worked:
                Image(systemName: "bolt.fill").font(.system(size: 56)).foregroundStyle(.green)
                Text("JIT works")
                    .font(.title3.bold())
                Text("The app ran code it wrote itself.")
                    .foregroundStyle(.secondary)
            case .failed(let reason):
                Image(systemName: "xmark.octagon").font(.system(size: 56)).foregroundStyle(.red)
                Text("JIT didn't work")
                    .font(.title3.bold())
                Text(reason)
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .padding(32)
        .task { await run() }
    }

    private func run() async {
        // The debugger attaches a moment after the app starts.
        for _ in 0..<100 where !jit_debugger_attached() {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard jit_debugger_attached() else {
            outcome = .noDebugger
            return
        }
        var error = [CChar](repeating: 0, count: 256)
        let result = jit_run_self_test(&error, error.count)
        outcome = result == 42 ? .worked : .failed(
            result < 0 ? String(cString: error) : "The generated code returned \(result) instead of 42."
        )
    }
}

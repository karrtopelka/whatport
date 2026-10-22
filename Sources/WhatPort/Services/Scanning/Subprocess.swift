import Foundation

/// Minimal helper for running a fixed, trusted executable with explicit
/// arguments (no shell) and collecting its output with a timeout.
enum Subprocess {
    struct Output: Sendable {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    enum Failure: Error, LocalizedError {
        case launchFailed(String)
        case timedOut

        var errorDescription: String? {
            switch self {
            case .launchFailed(let message): return "Could not launch process: \(message)"
            case .timedOut: return "The process did not finish in time."
            }
        }
    }

    static func run(
        executable: String,
        arguments: [String],
        currentDirectory: String? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval = 10
    ) async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if let currentDirectory { process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory) }
            if let environment { process.environment = environment }
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            process.standardInput = FileHandle.nullDevice

            let state = OutputState()
            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil } else { state.append(data, toStdout: true) }
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil } else { state.append(data, toStdout: false) }
            }

            let box = ProcessBox(process)
            let timeoutWork = DispatchWorkItem {
                if box.process.isRunning {
                    state.markTimedOut()
                    box.process.terminate()
                }
            }
            let timeoutBox = WorkItemBox(timeoutWork)

            process.terminationHandler = { finished in
                timeoutBox.item.cancel()
                // Drain anything still buffered.
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                let restOut = try? stdoutPipe.fileHandleForReading.readToEnd()
                let restErr = try? stderrPipe.fileHandleForReading.readToEnd()
                if let restOut { state.append(restOut, toStdout: true) }
                if let restErr { state.append(restErr, toStdout: false) }
                if state.timedOut {
                    continuation.resume(throwing: Failure.timedOut)
                } else {
                    continuation.resume(returning: state.output(status: finished.terminationStatus))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: Failure.launchFailed(error.localizedDescription))
                return
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
        }
    }

    private final class ProcessBox: @unchecked Sendable {
        let process: Process
        init(_ process: Process) { self.process = process }
    }

    private final class WorkItemBox: @unchecked Sendable {
        let item: DispatchWorkItem
        init(_ item: DispatchWorkItem) { self.item = item }
    }

    private final class OutputState: @unchecked Sendable {
        private let lock = NSLock()
        private var stdout = Data()
        private var stderr = Data()
        private var didTimeOut = false

        func append(_ data: Data, toStdout: Bool) {
            lock.lock(); defer { lock.unlock() }
            if toStdout { stdout.append(data) } else { stderr.append(data) }
        }

        func markTimedOut() {
            lock.lock(); defer { lock.unlock() }
            didTimeOut = true
        }

        var timedOut: Bool {
            lock.lock(); defer { lock.unlock() }
            return didTimeOut
        }

        func output(status: Int32) -> Output {
            lock.lock(); defer { lock.unlock() }
            return Output(
                status: status,
                stdout: String(decoding: stdout, as: UTF8.self),
                stderr: String(decoding: stderr, as: UTF8.self)
            )
        }
    }
}

import Foundation

public struct ProcessResult: Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String

    public var succeeded: Bool { status == 0 }

    /// stdout with the trailing newline every git command adds removed.
    public var trimmedOutput: String {
        stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum ProcessError: LocalizedError {
    case launchFailed(path: String, underlying: String)
    case timedOut(seconds: Double)
    case failed(command: String, status: Int32, message: String)

    public var errorDescription: String? {
        switch self {
        case let .launchFailed(path, underlying):
            "Could not launch \(path): \(underlying)"
        case let .timedOut(seconds):
            "Command timed out after \(Int(seconds))s"
        case let .failed(command, status, message):
            message.isEmpty ? "\(command) exited with \(status)" : message
        }
    }
}

public enum ProcessRunner {
    /// Run `executable` and wait for it to exit.
    ///
    /// stdout and stderr are drained on separate queues. Reading them one after the
    /// other deadlocks as soon as the child writes more than a pipe buffer, and a
    /// `git log` over a large repository is comfortably larger than that.
    ///
    /// Waiting for a child blocks a thread, so the work runs on a Dispatch queue
    /// rather than inside a `Task`. Swift's cooperative pool has about one thread per
    /// core; blocking those starves every other async operation, which matters here
    /// because a scan fans out dozens of git invocations at once.
    public static func run(
        executable: String,
        arguments: [String],
        workingDirectory: String? = nil,
        environment: [String: String]? = nil,
        timeout: Double = 30
    ) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try runSync(
                        executable: executable,
                        arguments: arguments,
                        workingDirectory: workingDirectory,
                        environment: environment,
                        timeout: timeout
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func runSync(
        executable: String,
        arguments: [String],
        workingDirectory: String?,
        environment: [String: String]?,
        timeout: Double
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        }
        if let environment { process.environment = environment }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        // Without this a git subcommand that wants credentials waits on a terminal
        // that will never answer, and the scan hangs until the timeout.
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw ProcessError.launchFailed(path: executable, underlying: error.localizedDescription)
        }

        let collector = OutputCollector()
        let group = DispatchGroup()
        for (handle, isStdout) in [(outPipe.fileHandleForReading, true), (errPipe.fileHandleForReading, false)] {
            DispatchQueue.global(qos: .userInitiated).async(group: group) {
                let data = handle.readDataToEndOfFile()
                collector.append(data, isStdout: isStdout)
            }
        }

        let deadline = DispatchTime.now() + timeout
        if group.wait(timeout: deadline) == .timedOut {
            process.terminate()
            _ = group.wait(timeout: .now() + 2)
            throw ProcessError.timedOut(seconds: timeout)
        }
        process.waitUntilExit()

        return ProcessResult(
            status: process.terminationStatus,
            stdout: collector.text(stdout: true),
            stderr: collector.text(stdout: false)
        )
    }
}

/// Lock-guarded buffers, because the two reader queues finish in any order.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()

    func append(_ data: Data, isStdout: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if isStdout { out.append(data) } else { err.append(data) }
    }

    func text(stdout: Bool) -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: stdout ? out : err, as: UTF8.self)
    }
}

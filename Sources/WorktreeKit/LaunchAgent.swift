import Foundation

/// Installs and removes the daily cleanup job.
///
/// A LaunchAgent rather than a timer inside the app, because the cleanup should happen
/// whether or not anyone opened the window that day.
public struct LaunchAgent: Sendable {
    public static let label = "com.ryan953.worktrees-ui.cleanup"

    public var label: String
    public var plistURL: URL
    public var logDirectory: URL

    public static let `default` = LaunchAgent(
        label: label,
        plistURL: URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents/\(label).plist"),
        logDirectory: URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/Worktrees")
    )

    public init(label: String, plistURL: URL, logDirectory: URL) {
        self.label = label
        self.plistURL = plistURL
        self.logDirectory = logDirectory
    }

    public enum Status: Sendable, Equatable {
        case notInstalled
        /// Installed, and the plist points at a tool that is where it says.
        case installed(hour: Int)
        /// Installed, but the executable it names is missing — the app was moved or
        /// deleted after the agent was installed.
        case brokenExecutable(String)
    }

    public var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    public func status() -> Status {
        guard let data = try? Data(contentsOf: plistURL),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let dictionary = plist as? [String: Any]
        else { return .notInstalled }

        if let arguments = dictionary["ProgramArguments"] as? [String], let tool = arguments.first,
            !FileManager.default.isExecutableFile(atPath: tool)
        {
            return .brokenExecutable(tool)
        }
        let hour = (dictionary["StartCalendarInterval"] as? [String: Any])?["Hour"] as? Int
        return .installed(hour: hour ?? 9)
    }

    /// Where the cleanup tool lives inside the running app bundle.
    ///
    /// The agent points straight at it rather than at a copy, so moving or deleting
    /// Worktrees.app leaves a job that visibly does nothing rather than one quietly
    /// running an old build.
    public static func bundledToolURL(bundle: Bundle = .main) -> URL? {
        let executable = bundle.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("worktrees-cleanup")
        if let executable, FileManager.default.isExecutableFile(atPath: executable.path) {
            return executable
        }
        // Running from `swift build` rather than an installed bundle.
        let sibling = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .appendingPathComponent("worktrees-cleanup")
        return FileManager.default.isExecutableFile(atPath: sibling.path) ? sibling : nil
    }

    public func plist(toolPath: String, hour: Int) -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": [toolPath, "--apply"],
            // Only Hour and Minute set, so launchd runs it once a day at that time.
            "StartCalendarInterval": ["Hour": max(0, min(23, hour)), "Minute": 0],
            // Missed runs — asleep, powered off — collapse into one run on wake rather
            // than firing once per day that was skipped.
            "RunAtLoad": false,
            "StandardOutPath": logDirectory.appendingPathComponent("cleanup.out.log").path,
            "StandardErrorPath": logDirectory.appendingPathComponent("cleanup.err.log").path,
            // Housekeeping should never compete with whatever the user is doing.
            "ProcessType": "Background",
            "LowPriorityIO": true,
            "Nice": 5,
        ]
    }

    public func plistData(toolPath: String, hour: Int) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: plist(toolPath: toolPath, hour: hour),
            format: .xml,
            options: 0
        )
    }

    /// Write the plist and load it. Replacing an existing job is an unload followed by
    /// a load, because launchd will not notice a rewritten file on its own.
    public func install(toolPath: String, hour: Int, launchctl: String = "/bin/launchctl") async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(
            at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        if isInstalled { _ = await bootout(launchctl: launchctl) }
        try plistData(toolPath: toolPath, hour: hour).write(to: plistURL)

        let target = "gui/\(getuid())"
        let result = try await ProcessRunner.run(
            executable: launchctl,
            arguments: ["bootstrap", target, plistURL.path],
            workingDirectory: nil,
            environment: nil,
            timeout: 30
        )
        guard result.succeeded else {
            throw ProcessError.failed(
                command: "launchctl bootstrap",
                status: result.status,
                message: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    public func uninstall(launchctl: String = "/bin/launchctl") async throws {
        _ = await bootout(launchctl: launchctl)
        if isInstalled {
            try FileManager.default.removeItem(at: plistURL)
        }
    }

    /// Run the job now, without waiting for its schedule.
    public func runNow(launchctl: String = "/bin/launchctl") async throws {
        let result = try await ProcessRunner.run(
            executable: launchctl,
            arguments: ["kickstart", "-k", "gui/\(getuid())/\(label)"],
            workingDirectory: nil,
            environment: nil,
            timeout: 30
        )
        guard result.succeeded else {
            throw ProcessError.failed(
                command: "launchctl kickstart",
                status: result.status,
                message: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    /// Unloading a job that is not loaded is not an error worth reporting.
    private func bootout(launchctl: String) async -> Bool {
        let result = try? await ProcessRunner.run(
            executable: launchctl,
            arguments: ["bootout", "gui/\(getuid())/\(label)"],
            workingDirectory: nil,
            environment: nil,
            timeout: 30
        )
        return result?.succeeded ?? false
    }
}

import Foundation

/// Which processes are sitting in which directories, taken once as a snapshot.
///
/// git will happily remove a clean worktree that a shell, an editor or a coding agent
/// is currently working in; the directory simply vanishes underneath them. Nothing in
/// git's own state reveals that, so this asks the operating system instead.
public struct ProcessCwdIndex: Sendable, Equatable {
    /// Directory path to a human description of the first process found there.
    public var byDirectory: [String: String]

    public static let empty = ProcessCwdIndex(byDirectory: [:])

    public init(byDirectory: [String: String]) {
        self.byDirectory = byDirectory
    }

    /// The process holding `path`, if any. A process inside a subdirectory counts:
    /// removing the worktree would pull the floor out from under it just the same.
    public func holder(of path: String) -> String? {
        let standardized = (path as NSString).standardizingPath
        if let direct = byDirectory[standardized] { return direct }
        let prefix = standardized.hasSuffix("/") ? standardized : standardized + "/"
        for (directory, holder) in byDirectory where directory.hasPrefix(prefix) {
            return holder
        }
        return nil
    }

    public static func current(lsof: String = "/usr/sbin/lsof") async -> ProcessCwdIndex {
        guard FileManager.default.isExecutableFile(atPath: lsof) else { return .empty }
        // -d cwd limits it to working directories; -F pcn asks for machine-readable
        // records rather than the columns, which are not safe to split on.
        let result = try? await ProcessRunner.run(
            executable: lsof,
            arguments: ["-d", "cwd", "-F", "pcn"],
            workingDirectory: nil,
            environment: nil,
            timeout: 20
        )
        // lsof exits non-zero when it cannot read some process, which is normal and
        // does not invalidate the records it did print.
        guard let output = result?.stdout, !output.isEmpty else { return .empty }
        return parse(output)
    }

    /// Parse `lsof -F pcn`: one field per line, tagged by its first character, with
    /// records running until the next `p` (process) line.
    public static func parse(_ output: String) -> ProcessCwdIndex {
        var byDirectory: [String: String] = [:]
        var pid = ""
        var command = ""
        for line in output.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": pid = value
            case "c": command = value
            case "n":
                let directory = (value as NSString).standardizingPath
                guard !directory.isEmpty, byDirectory[directory] == nil else { continue }
                byDirectory[directory] = command.isEmpty ? "pid \(pid)" : "\(command) (pid \(pid))"
            default: continue
            }
        }
        return ProcessCwdIndex(byDirectory: byDirectory)
    }
}

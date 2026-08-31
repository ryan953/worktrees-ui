import Foundation

/// A thin wrapper over the `git` binary.
///
/// Every read the app does goes through git's plumbing rather than a parser for
/// human-readable output: porcelain formats are documented as stable, the pretty ones
/// are not, and a misparse here would quietly mislabel work as pushed.
public struct GitClient: Sendable {
    public var executable: String
    public var environment: [String: String]

    public init(executable: String, environment: [String: String]) {
        self.executable = executable
        self.environment = environment
    }

    @discardableResult
    public func run(
        _ arguments: [String],
        in directory: String,
        timeout: Double = 30
    ) async throws -> ProcessResult {
        try await ProcessRunner.run(
            executable: executable,
            arguments: arguments,
            workingDirectory: directory,
            environment: environment,
            timeout: timeout
        )
    }

    /// Run a command that must succeed.
    public func output(
        _ arguments: [String],
        in directory: String,
        timeout: Double = 30
    ) async throws -> String {
        let result = try await run(arguments, in: directory, timeout: timeout)
        guard result.succeeded else {
            throw ProcessError.failed(
                command: "git " + arguments.joined(separator: " "),
                status: result.status,
                message: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return result.trimmedOutput
    }

    /// Run a command whose failure is an ordinary answer.
    ///
    /// Most of the questions here — "is there an upstream?", "does this ref exist?" —
    /// are asked by running a command that exits non-zero when the answer is no.
    public func optional(
        _ arguments: [String],
        in directory: String,
        timeout: Double = 30
    ) async -> String? {
        guard let result = try? await run(arguments, in: directory, timeout: timeout),
            result.succeeded
        else { return nil }
        return result.trimmedOutput
    }

    public func refExists(_ ref: String, in directory: String) async -> Bool {
        await optional(["rev-parse", "--verify", "--quiet", ref + "^{commit}"], in: directory) != nil
    }

    /// Count the commits reachable from `head` but not `base`.
    public func revListCount(base: String, head: String, in directory: String) async -> Int {
        let text = await optional(["rev-list", "--count", "\(base)..\(head)"], in: directory)
        return text.flatMap(Int.init) ?? 0
    }

    /// The commits in `base..head`, newest first.
    public func log(
        base: String?, head: String, limit: Int, in directory: String
    ) async -> [Commit] {
        let range = base.map { "\($0)..\(head)" } ?? head
        let args = [
            "log", "--no-color", "--max-count=\(limit)",
            "--format=\(GitLog.format)", range,
        ]
        guard let text = await optional(args, in: directory) else { return [] }
        return GitLog.parse(text)
    }

    /// Every worktree directory attached to this repository, main copy first.
    public func worktreePaths(in directory: String) async -> [String] {
        guard let text = await optional(["worktree", "list", "--porcelain"], in: directory) else {
            return []
        }
        return WorktreePorcelain.parse(text).map(\.path)
    }

    /// Count uncommitted changes, ignoring the directories other worktrees live in.
    ///
    /// Worktrees are commonly nested inside the checkout, under `.claude/worktrees`. A
    /// repository that does not gitignore that path would otherwise report its own
    /// worktrees as untracked files, which reads as "the working copy is dirty" — and
    /// that would block the pull button for a reason that is not real. Excluding by
    /// pathspec leaves git to answer, so a genuinely untracked file elsewhere still
    /// counts.
    public func dirtyCount(in directory: String, excluding nested: [String]) async -> Int {
        guard FileManager.default.fileExists(atPath: directory) else { return 0 }
        var arguments = ["status", "--porcelain", "--untracked-files=normal", "--", "."]
        for exclusion in nested.compactMap({ Self.relativePath(of: $0, under: directory) }) {
            arguments.append(":(exclude)\(exclusion)")
        }
        guard let text = await optional(arguments, in: directory, timeout: 60) else { return 0 }
        return text.split(separator: "\n").filter { !$0.isEmpty }.count
    }

    /// `child` written relative to `parent`, or nil when it is not inside it.
    public static func relativePath(of child: String, under parent: String) -> String? {
        let childPath = (child as NSString).standardizingPath
        let parentPath = (parent as NSString).standardizingPath
        guard childPath != parentPath else { return nil }
        let prefix = parentPath.hasSuffix("/") ? parentPath : parentPath + "/"
        guard childPath.hasPrefix(prefix) else { return nil }
        return String(childPath.dropFirst(prefix.count))
    }

    /// Fetch the remote so "published" reflects the server rather than the last time
    /// someone happened to fetch.
    ///
    /// `--prune` is what turns a branch deleted after a merge into a visible
    /// "remote deleted" rather than a stale ref that still looks published.
    public func fetch(remote: String = "origin", in directory: String) async throws {
        _ = try await output(
            ["fetch", "--prune", "--quiet", remote],
            in: directory,
            timeout: 120
        )
    }
}

/// Parsing for `git log` in the one format this app asks for.
public enum GitLog {
    /// Unit separator between fields, record separator between commits: both are
    /// bytes that cannot appear in a commit subject or an author name.
    public static let format = "%H%x1f%h%x1f%s%x1f%an%x1f%ct%x1e"

    public static func parse(_ text: String) -> [Commit] {
        text.components(separatedBy: "\u{1e}").compactMap { record -> Commit? in
            let trimmed = record.trimmingCharacters(in: .newlines)
            guard !trimmed.isEmpty else { return nil }
            let fields = trimmed.components(separatedBy: "\u{1f}")
            guard fields.count >= 5, let seconds = TimeInterval(fields[4]) else { return nil }
            return Commit(
                sha: fields[0],
                shortSHA: fields[1],
                subject: fields[2],
                author: fields[3],
                date: Date(timeIntervalSince1970: seconds)
            )
        }
    }
}

/// One record from `git worktree list --porcelain`, before any status is worked out.
public struct WorktreeEntry: Sendable, Equatable {
    public var path: String
    public var head: String?
    public var branch: String?
    public var isBare: Bool
    public var isDetached: Bool
    public var isLocked: Bool
    public var isPrunable: Bool

    public init(
        path: String, head: String? = nil, branch: String? = nil,
        isBare: Bool = false, isDetached: Bool = false,
        isLocked: Bool = false, isPrunable: Bool = false
    ) {
        self.path = path
        self.head = head
        self.branch = branch
        self.isBare = isBare
        self.isDetached = isDetached
        self.isLocked = isLocked
        self.isPrunable = isPrunable
    }
}

public enum WorktreePorcelain {
    /// Parse `git worktree list --porcelain`.
    ///
    /// Records are separated by a blank line, and git documents the main working copy
    /// as the first one — which is what makes "the working copy for this repo"
    /// knowable without guessing at directory names.
    public static func parse(_ text: String) -> [WorktreeEntry] {
        var entries: [WorktreeEntry] = []
        var current: WorktreeEntry?

        func flush() {
            if let entry = current { entries.append(entry) }
            current = nil
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
                continue
            }
            let (key, value) = split(line)
            switch key {
            case "worktree":
                flush()
                current = WorktreeEntry(path: value)
            case "HEAD":
                current?.head = value
            case "branch":
                // Always the full ref, e.g. refs/heads/feature/x.
                current?.branch = value.hasPrefix("refs/heads/")
                    ? String(value.dropFirst("refs/heads/".count))
                    : value
            case "bare":
                current?.isBare = true
            case "detached":
                current?.isDetached = true
            // Both carry an optional reason after the keyword; the flag is what
            // matters here and the reason is not shown.
            case "locked":
                current?.isLocked = true
            case "prunable":
                current?.isPrunable = true
            default:
                break
            }
        }
        flush()
        return entries
    }

    private static func split(_ line: String) -> (String, String) {
        guard let space = line.firstIndex(of: " ") else { return (line, "") }
        return (String(line[..<space]), String(line[line.index(after: space)...]))
    }
}

import Foundation

/// What happened to one worktree.
public struct CleanupOutcome: Sendable, Identifiable, Equatable {
    public enum Result: Sendable, Equatable {
        case removed
        case wouldRemove
        case kept(KeepReason)
        case failed(String)
    }

    public var path: String
    public var branch: String?
    public var repositoryName: String
    public var repositoryRoot: String
    public var result: Result
    public var grounds: RemovalGrounds?

    public var id: String { path }

    public var restoreCommand: String? {
        guard let grounds else { return nil }
        return grounds.recovery.restoreCommand(path: path, branch: branch)
    }
}

public struct CleanupReport: Sendable, Equatable {
    public var outcomes: [CleanupOutcome]
    public var startedAt: Date
    public var skippedBecauseLocked: Bool

    public var removed: [CleanupOutcome] {
        outcomes.filter { $0.result == .removed }
    }
    public var wouldRemove: [CleanupOutcome] {
        outcomes.filter { $0.result == .wouldRemove }
    }
    public var failures: [CleanupOutcome] {
        outcomes.filter { if case .failed = $0.result { return true } else { return false } }
    }
    public var kept: [CleanupOutcome] {
        outcomes.filter { if case .kept = $0.result { return true } else { return false } }
    }
}

/// Carries out a cleanup plan.
public struct CleanupRunner: Sendable {
    public var git: GitClient
    public var log: CleanupLog

    public init(git: GitClient, log: CleanupLog = .default) {
        self.git = git
        self.log = log
    }

    /// Remove the worktrees a plan marked removable.
    ///
    /// `git worktree remove` without `--force` is used deliberately: it refuses a
    /// directory with modifications, which is a second, independent check on top of the
    /// planner's. If the two ever disagree, nothing is deleted.
    public func run(
        _ candidates: [CleanupCandidate],
        policy: CleanupPolicy,
        selected: Set<String>? = nil
    ) async -> CleanupReport {
        let startedAt = Date()
        var outcomes: [CleanupOutcome] = []

        for candidate in candidates {
            let worktree = candidate.worktree
            let base = CleanupOutcome(
                path: worktree.path,
                branch: worktree.branch,
                repositoryName: candidate.repositoryName,
                repositoryRoot: worktree.repoRoot,
                result: .wouldRemove,
                grounds: candidate.grounds
            )

            guard case let .remove(grounds) = candidate.decision else {
                if case let .keep(reason) = candidate.decision {
                    var outcome = base
                    outcome.result = .kept(reason)
                    outcome.grounds = nil
                    outcomes.append(outcome)
                }
                continue
            }
            // A selection narrows the plan; nil means everything it found.
            if let selected, !selected.contains(worktree.path) {
                var outcome = base
                outcome.result = .kept(.isWorkingCopy)
                outcome.grounds = nil
                outcomes.append(outcome)
                continue
            }
            if policy.dryRun {
                outcomes.append(base)
                continue
            }

            var outcome = base
            do {
                try await git.removeWorktree(at: worktree.path, in: worktree.repoRoot)
                if policy.deletesBranch, let branch = worktree.branch {
                    // Only when nothing else has it checked out, or git refuses and the
                    // branch would be left behind with a confusing error.
                    let stillUsed = await git.branchIsCheckedOut(branch, in: worktree.repoRoot)
                    if !stillUsed {
                        // -D rather than -d: the branch is provably on GitHub by now, and
                        // -d refuses anything not merged into the current HEAD, which a
                        // squash-merged branch never is.
                        _ = await git.optional(["branch", "-D", branch], in: worktree.repoRoot)
                    }
                }
                outcome.result = .removed
                outcome.grounds = grounds
                await log.record(outcome)
            } catch {
                outcome.result = .failed(error.localizedDescription)
                outcome.grounds = nil
            }
            outcomes.append(outcome)
        }

        return CleanupReport(
            outcomes: outcomes, startedAt: startedAt, skippedBecauseLocked: false)
    }
}

/// Appends a line per removal, with the command that undoes it.
///
/// A scheduled job deletes things while nobody is watching, so the only acceptable
/// version of "you can get it back" is one written down at the time.
public struct CleanupLog: Sendable {
    public var url: URL

    public static let `default` = CleanupLog(
        url: URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/Worktrees/cleanup.log")
    )

    public init(url: URL) {
        self.url = url
    }

    public func record(_ outcome: CleanupOutcome) async {
        let stamp = ISO8601DateFormatter().string(from: Date())
        var line = "\(stamp)\tREMOVED\t\(outcome.repositoryName)\t\(outcome.path)"
        line += "\t\(outcome.branch ?? "(detached)")"
        if let grounds = outcome.grounds {
            line += "\t\(grounds.recovery.describedSource)"
        }
        line += "\n"
        if let restore = outcome.restoreCommand {
            line += "\trestore: git -C \(outcome.repositoryRoot) \(restore)\n"
        }
        append(line)
    }

    public func note(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        append("\(stamp)\t\(message)\n")
    }

    private func append(_ text: String) {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = text.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}

/// Stops a scheduled run and a run started from the app from removing the same
/// worktrees at the same time.
///
/// `mkdir` is atomic on a local filesystem, which is all this needs. The lease keeps a
/// crashed run from holding the lock forever.
public struct RunLock: Sendable {
    public var url: URL
    public var staleAfter: TimeInterval

    public static let `default` = RunLock(
        url: URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Caches/com.ryan953.worktrees-ui/cleanup.lock"),
        staleAfter: 60 * 30
    )

    public init(url: URL, staleAfter: TimeInterval = 1800) {
        self.url = url
        self.staleAfter = staleAfter
    }

    /// Take the lock, or return nil when another run holds it.
    public func acquire() -> Handle? {
        let fm = FileManager.default
        try? fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try fm.createDirectory(at: url, withIntermediateDirectories: false)
            return Handle(url: url)
        } catch {
            let created =
                (try? fm.attributesOfItem(atPath: url.path)[.creationDate] as? Date) ?? nil
            guard let created, Date().timeIntervalSince(created) > staleAfter else {
                return nil
            }
            try? fm.removeItem(at: url)
            guard (try? fm.createDirectory(at: url, withIntermediateDirectories: false)) != nil
            else { return nil }
            return Handle(url: url)
        }
    }

    /// Release is explicit rather than tied to deinit, because the callers exit the
    /// process directly and `exit()` runs neither `defer` nor `deinit` — a lock left
    /// behind would block every run until its lease expired.
    public final class Handle: @unchecked Sendable {
        let url: URL
        private var released = false

        init(url: URL) {
            self.url = url
        }

        public func release() {
            guard !released else { return }
            released = true
            try? FileManager.default.removeItem(at: url)
        }

        deinit { release() }
    }
}

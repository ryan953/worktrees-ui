import Foundation

public struct CleanupPolicy: Sendable, Equatable {
    /// How long a worktree must have been left alone before it can be removed.
    public var minimumAgeDays: Int
    /// Whether a worktree whose pull request is still open may be removed.
    public var includesOpenPullRequests: Bool
    /// Delete the local branch along with the worktree directory.
    public var deletesBranch: Bool
    /// Decide and report, but change nothing.
    public var dryRun: Bool

    public init(
        minimumAgeDays: Int = 14,
        includesOpenPullRequests: Bool = false,
        deletesBranch: Bool = true,
        dryRun: Bool = false
    ) {
        self.minimumAgeDays = minimumAgeDays
        self.includesOpenPullRequests = includesOpenPullRequests
        self.deletesBranch = deletesBranch
        self.dryRun = dryRun
    }
}

/// Where the commits would be read back from, if they are ever wanted again.
///
/// Carried through to the receipt, because "you can get it back" is only a real claim
/// if it comes with the command that does it.
public enum Recovery: Sendable, Equatable {
    /// Still a branch on the remote.
    case remoteBranch(String)
    /// GitHub keeps `refs/pull/<n>/head` permanently, including after the branch is
    /// deleted and for pull requests that were closed without merging. That is what
    /// makes a merged-and-tidied worktree safe to remove.
    case pullRequestRef(number: Int)

    public var describedSource: String {
        switch self {
        case let .remoteBranch(ref): "the \(ref) branch"
        case let .pullRequestRef(number): "pull request #\(number)"
        }
    }

    /// The command that brings the commits back into a worktree.
    public func restoreCommand(path: String, branch: String?) -> String {
        let name = branch ?? "restored"
        switch self {
        case let .remoteBranch(ref):
            return "git worktree add -b \(name) \(path) \(ref)"
        case let .pullRequestRef(number):
            return "git fetch origin refs/pull/\(number)/head && "
                + "git worktree add -b \(name) \(path) FETCH_HEAD"
        }
    }
}

/// Why a worktree is being left alone.
public enum KeepReason: Sendable, Equatable {
    case isWorkingCopy
    case locked
    case uncommittedChanges(Int)
    case noPullRequest
    case pullRequestStillOpen(number: Int)
    /// Some process has this directory as its working directory, so something is
    /// using it right now whatever git thinks.
    case inUse(String)
    case tooRecent(idleDays: Int, required: Int)
    /// The commits are not provably on GitHub, so removing would lose them.
    case notOnGitHub(String)

    public var summary: String {
        switch self {
        case .isWorkingCopy:
            "It is the working copy."
        case .locked:
            "The worktree is locked."
        case let .uncommittedChanges(count):
            "\(count) uncommitted \(count == 1 ? "change" : "changes")."
        case .noPullRequest:
            "No pull request, so there is nothing keeping the commits on GitHub."
        case let .pullRequestStillOpen(number):
            "Pull request #\(number) is still open."
        case let .inUse(holder):
            "In use by \(holder)."
        case let .tooRecent(idleDays, required):
            "Last touched \(idleDays) \(idleDays == 1 ? "day" : "days") ago; "
                + "the policy waits \(required)."
        case let .notOnGitHub(detail):
            detail
        }
    }
}

public struct RemovalGrounds: Sendable, Equatable {
    public var pullRequest: PullRequest
    public var recovery: Recovery
    public var idleDays: Int

    public init(pullRequest: PullRequest, recovery: Recovery, idleDays: Int) {
        self.pullRequest = pullRequest
        self.recovery = recovery
        self.idleDays = idleDays
    }

    public var summary: String {
        "Every commit is on GitHub in \(recovery.describedSource); "
            + "\(pullRequest.label) — \(pullRequest.title)."
    }
}

public enum CleanupDecision: Sendable, Equatable {
    case remove(RemovalGrounds)
    case keep(KeepReason)

    public var isRemovable: Bool {
        if case .remove = self { return true }
        return false
    }
}

/// One worktree, judged.
public struct CleanupCandidate: Sendable, Identifiable, Equatable {
    public var worktree: Worktree
    public var repositoryName: String
    public var decision: CleanupDecision

    public var id: String { worktree.path }
    public var isRemovable: Bool { decision.isRemovable }

    public var grounds: RemovalGrounds? {
        if case let .remove(grounds) = decision { return grounds }
        return nil
    }

    public init(worktree: Worktree, repositoryName: String, decision: CleanupDecision) {
        self.worktree = worktree
        self.repositoryName = repositoryName
        self.decision = decision
    }
}

/// Decides which worktrees can be removed.
///
/// Nothing here trusts a status label. A worktree is only removable once its HEAD has
/// been shown to exist on GitHub, because the whole promise of this feature is that
/// removing a directory never loses a commit.
public struct CleanupPlanner: Sendable {
    public var git: GitClient
    /// Injected by the tests; the real clock otherwise.
    public var now: Date

    public init(git: GitClient, now: Date = Date()) {
        self.git = git
        self.now = now
    }

    public func plan(
        repositories: [Repository],
        policy: CleanupPolicy
    ) async -> [CleanupCandidate] {
        // One pass for the whole run: asking per worktree would fork lsof dozens of
        // times to answer from the same snapshot.
        let holders = await ProcessCwdIndex.current()
        var candidates: [CleanupCandidate] = []
        for repository in repositories {
            for worktree in repository.worktrees where !worktree.isMain {
                let decision = await decide(
                    worktree, in: repository, policy: policy, holders: holders)
                candidates.append(
                    CleanupCandidate(
                        worktree: worktree,
                        repositoryName: repository.name,
                        decision: decision
                    )
                )
            }
        }
        return candidates
    }

    /// Cheap local checks first, the network call last, so a worktree that is obviously
    /// staying never costs a round trip.
    public func decide(
        _ worktree: Worktree,
        in repository: Repository,
        policy: CleanupPolicy,
        holders: ProcessCwdIndex = .empty
    ) async -> CleanupDecision {
        if worktree.isMain { return .keep(.isWorkingCopy) }
        if worktree.isLocked { return .keep(.locked) }
        if worktree.dirtyFileCount > 0 {
            return .keep(.uncommittedChanges(worktree.dirtyFileCount))
        }
        // A shell or an editor sitting in the directory means it is someone's current
        // context, which no amount of git state would reveal.
        if let holder = holders.holder(of: worktree.path) {
            return .keep(.inUse(holder))
        }
        guard let pullRequest = worktree.pullRequest else {
            return .keep(.noPullRequest)
        }
        if pullRequest.state == .open && !policy.includesOpenPullRequests {
            return .keep(.pullRequestStillOpen(number: pullRequest.number))
        }
        let idle = idleDays(for: worktree)
        if idle < policy.minimumAgeDays {
            return .keep(.tooRecent(idleDays: idle, required: policy.minimumAgeDays))
        }
        guard let recovery = await recovery(for: worktree, in: repository, pullRequest: pullRequest)
        else {
            return .keep(
                .notOnGitHub(
                    "Some commits here are not on GitHub, so removing this would lose them."
                )
            )
        }
        return .remove(
            RemovalGrounds(pullRequest: pullRequest, recovery: recovery, idleDays: idle)
        )
    }

    /// Prove that every commit in the worktree can be read back from GitHub.
    ///
    /// Returns nil when that cannot be established — including when the check itself
    /// fails, since "we could not tell" and "it is safe" must never collapse into the
    /// same answer for something that deletes work.
    func recovery(
        for worktree: Worktree,
        in repository: Repository,
        pullRequest: PullRequest
    ) async -> Recovery? {
        // The cheap case: the remote branch still exists and already has every commit,
        // which the scan worked out from the tracking refs.
        if worktree.sync.isFullyPushed {
            let ref = worktree.upstream ?? worktree.branch.map { "origin/\($0)" }
            if let ref { return .remoteBranch(ref) }
        }

        // Otherwise lean on the pull request ref, which outlives the branch.
        let ref = "refs/pull/\(pullRequest.number)/head"
        guard let head = await git.lsRemote(ref, in: repository.root), !head.isEmpty else {
            return nil
        }
        if head == worktree.head { return .pullRequestRef(number: pullRequest.number) }
        // The pull request may have moved on since; the commits here are still safe as
        // long as they are an ancestor of what GitHub holds.
        guard await git.hasCommit(head, in: repository.root),
            await git.isAncestor(worktree.head, of: head, in: repository.root)
        else { return nil }
        return .pullRequestRef(number: pullRequest.number)
    }

    /// How long since anything happened here.
    ///
    /// The last commit is the honest signal: a worktree with uncommitted edits never
    /// reaches this check, so there is no newer activity a commit date could miss.
    func idleDays(for worktree: Worktree) -> Int {
        let reference = worktree.lastCommitDate ?? modifiedDate(of: worktree.path) ?? now
        return max(0, Int(now.timeIntervalSince(reference) / 86400))
    }

    private func modifiedDate(of path: String) -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return attributes?[.modificationDate] as? Date
    }
}

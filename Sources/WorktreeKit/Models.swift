import Foundation

public struct Commit: Identifiable, Sendable, Hashable {
    public var sha: String
    public var shortSHA: String
    public var subject: String
    public var author: String
    public var date: Date

    public var id: String { sha }

    public init(sha: String, shortSHA: String, subject: String, author: String, date: Date) {
        self.sha = sha
        self.shortSHA = shortSHA
        self.subject = subject
        self.author = author
        self.date = date
    }
}

/// A remote parsed into the pieces a web link needs.
public struct RemoteRepo: Sendable, Hashable {
    public var host: String
    public var owner: String
    public var name: String

    public var slug: String { "\(owner)/\(name)" }
    public var isGitHub: Bool { host == "github.com" || host.hasSuffix(".github.com") }

    public init(host: String, owner: String, name: String) {
        self.host = host
        self.owner = owner
        self.name = name
    }

    /// Parse the SSH and HTTPS spellings git remotes come in.
    ///
    /// Enterprise hosts are kept as-is rather than assumed to be github.com, so a link
    /// is either right or absent — never pointing at the wrong server.
    public static func parse(_ remote: String) -> RemoteRepo? {
        var text = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.hasSuffix(".git") { text.removeLast(4) }

        var host: String
        var pathPart: String

        if let range = text.range(of: "://") {
            // https://github.com/owner/name, ssh://git@github.com/owner/name
            var rest = String(text[range.upperBound...])
            if let at = rest.firstIndex(of: "@") { rest = String(rest[rest.index(after: at)...]) }
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            host = String(rest[..<slash])
            pathPart = String(rest[rest.index(after: slash)...])
        } else if let colon = text.firstIndex(of: ":") {
            // git@github.com:owner/name — the scp-like form, with no scheme.
            var head = String(text[..<colon])
            if let at = head.firstIndex(of: "@") { head = String(head[head.index(after: at)...]) }
            host = head
            pathPart = String(text[text.index(after: colon)...])
        } else {
            return nil
        }

        // A host may carry a port, which is not part of the web address.
        if let portColon = host.firstIndex(of: ":") { host = String(host[..<portColon]) }

        let segments = pathPart.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        guard segments.count >= 2, !host.isEmpty else { return nil }
        // Deeper paths happen on self-hosted forges; the last two segments are still
        // owner and repository.
        let owner = segments[segments.count - 2]
        let name = segments[segments.count - 1]
        return RemoteRepo(host: host, owner: owner, name: name)
    }

    public func branchURL(_ branch: String) -> URL? {
        guard let encoded = encode(branch) else { return nil }
        return URL(string: "https://\(host)/\(slug)/tree/\(encoded)")
    }

    public func commitURL(_ sha: String) -> URL? {
        URL(string: "https://\(host)/\(slug)/commit/\(sha)")
    }

    public func compareURL(base: String, head: String) -> URL? {
        guard let b = encode(base), let h = encode(head) else { return nil }
        return URL(string: "https://\(host)/\(slug)/compare/\(b)...\(h)")
    }

    public func newPullRequestURL(base: String, head: String) -> URL? {
        guard let b = encode(base), let h = encode(head) else { return nil }
        return URL(string: "https://\(host)/\(slug)/compare/\(b)...\(h)?expand=1")
    }

    public var homeURL: URL? { URL(string: "https://\(host)/\(slug)") }

    /// Branch names may contain "/" and it must survive into the path unescaped, so
    /// the slash is added back after percent-encoding.
    private func encode(_ ref: String) -> String? {
        ref.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-._~/")))
    }
}

public struct PullRequest: Identifiable, Sendable, Hashable {
    public enum State: String, Sendable, Codable {
        case open = "OPEN"
        case merged = "MERGED"
        case closed = "CLOSED"
    }

    public var number: Int
    public var title: String
    public var url: String
    public var state: State
    public var isDraft: Bool
    public var headRefName: String
    public var baseRefName: String

    public var id: Int { number }

    public var label: String {
        switch state {
        case .open: isDraft ? "Draft #\(number)" : "Open #\(number)"
        case .merged: "Merged #\(number)"
        case .closed: "Closed #\(number)"
        }
    }

    public init(
        number: Int, title: String, url: String, state: State,
        isDraft: Bool, headRefName: String, baseRefName: String
    ) {
        self.number = number
        self.title = title
        self.url = url
        self.state = state
        self.isDraft = isDraft
        self.headRefName = headRefName
        self.baseRefName = baseRefName
    }
}

/// How the branch stands against the copy of it on the remote.
public enum SyncState: Sendable, Hashable {
    /// The remote has no branch by this name.
    case noRemoteBranch
    /// A tracking branch is configured, but the remote deleted it — the usual sign of
    /// a merged and tidied-up pull request.
    case remoteDeleted
    case upToDate
    case ahead(Int)
    case behind(Int)
    case diverged(ahead: Int, behind: Int)

    /// Whether every commit the working copy has is also on the remote.
    public var isFullyPushed: Bool {
        switch self {
        case .upToDate, .behind: true
        case .noRemoteBranch, .remoteDeleted, .ahead, .diverged: false
        }
    }

    public var aheadCount: Int {
        switch self {
        case let .ahead(n): n
        case let .diverged(ahead, _): ahead
        default: 0
        }
    }

    public var behindCount: Int {
        switch self {
        case let .behind(n): n
        case let .diverged(_, behind): behind
        default: 0
        }
    }
}

/// The one-word answer to "what is going on with this worktree?".
///
/// The two things worth knowing are kept apart deliberately: whether the branch has
/// commits of its own, and whether those commits exist on GitHub. Everything the list
/// shows is one of these five.
public enum WorktreeStatus: String, Sendable, CaseIterable {
    /// Nothing here that the base branch does not already have.
    case matchesBase
    /// Unique commits that exist nowhere but this disk.
    case localOnly
    /// A remote branch exists, but it is missing some of these commits.
    case unpushed
    /// Everything is on the remote.
    case published
    /// Pushed once, then deleted on the remote.
    case remoteDeleted
    /// No branch at all — a detached HEAD.
    case detached

    public var label: String {
        switch self {
        case .matchesBase: "Matches base"
        case .localOnly: "Local only"
        case .unpushed: "Unpushed"
        case .published: "Published"
        case .remoteDeleted: "Remote deleted"
        case .detached: "Detached"
        }
    }

    /// Whether this worktree holds work that exists only on this machine. This is the
    /// distinction the list is sorted by, because it is the one that loses work.
    public var isAtRisk: Bool {
        switch self {
        case .localOnly, .unpushed: true
        case .matchesBase, .published, .remoteDeleted, .detached: false
        }
    }
}

public struct Worktree: Identifiable, Sendable, Hashable {
    /// The worktree's own directory.
    public var path: String
    /// The main working copy of the repository this worktree belongs to — the place
    /// the "pull into working copy" button acts on.
    public var repoRoot: String
    /// nil when HEAD is detached.
    public var branch: String?
    public var head: String
    public var isMain: Bool
    public var isLocked: Bool
    public var isPrunable: Bool

    public var upstream: String?
    public var sync: SyncState
    public var baseBranch: String
    /// Commits on this branch that the base branch does not have, newest first.
    public var uniqueCommits: [Commit]
    public var dirtyFileCount: Int
    public var lastCommitDate: Date?
    public var pullRequest: PullRequest?

    public var id: String { path }

    public var name: String {
        branch ?? "detached at \(String(head.prefix(8)))"
    }

    public var displayName: String {
        (path as NSString).lastPathComponent
    }

    public var isDirty: Bool { dirtyFileCount > 0 }
    public var hasUniqueCommits: Bool { !uniqueCommits.isEmpty }

    public var status: WorktreeStatus {
        guard branch != nil else { return .detached }
        if case .remoteDeleted = sync { return .remoteDeleted }
        guard hasUniqueCommits else { return .matchesBase }
        if case .noRemoteBranch = sync { return .localOnly }
        return sync.isFullyPushed ? .published : .unpushed
    }

    public init(
        path: String, repoRoot: String, branch: String?, head: String,
        isMain: Bool, isLocked: Bool = false, isPrunable: Bool = false,
        upstream: String? = nil, sync: SyncState = .noRemoteBranch,
        baseBranch: String = "main", uniqueCommits: [Commit] = [],
        dirtyFileCount: Int = 0, lastCommitDate: Date? = nil,
        pullRequest: PullRequest? = nil
    ) {
        self.path = path
        self.repoRoot = repoRoot
        self.branch = branch
        self.head = head
        self.isMain = isMain
        self.isLocked = isLocked
        self.isPrunable = isPrunable
        self.upstream = upstream
        self.sync = sync
        self.baseBranch = baseBranch
        self.uniqueCommits = uniqueCommits
        self.dirtyFileCount = dirtyFileCount
        self.lastCommitDate = lastCommitDate
        self.pullRequest = pullRequest
    }
}

/// One repository and every worktree attached to it.
public struct Repository: Identifiable, Sendable, Hashable {
    /// The main working copy directory.
    public var root: String
    public var remote: RemoteRepo?
    public var defaultBranch: String
    public var worktrees: [Worktree]
    /// When the remote-tracking refs were last refreshed, so the UI can say how much
    /// to trust "published".
    public var lastFetch: Date?
    /// Set when the scan could not finish, e.g. `gh` is missing.
    public var warning: String?

    public var id: String { root }
    public var name: String { remote?.name ?? (root as NSString).lastPathComponent }

    /// Every worktree that is not the main working copy.
    public var linkedWorktrees: [Worktree] { worktrees.filter { !$0.isMain } }
    public var mainWorktree: Worktree? { worktrees.first(where: \.isMain) }

    /// The owner, when the remote gives one — shown beside the name so two repositories
    /// called `docs` are still tellable apart.
    public var owner: String? { remote?.owner }

    /// Nothing here but the working copy.
    public var isSolo: Bool { linkedWorktrees.isEmpty }

    /// Whether any worktree holds work of its own, committed or not.
    ///
    /// Deliberately not the same question as "is it pushed": a branch with commits that
    /// are all on GitHub is still a repository with something going on in it.
    public var hasLocalChanges: Bool {
        worktrees.contains { $0.isDirty || $0.hasUniqueCommits }
    }

    /// Whether any worktree has uncommitted edits.
    public var hasUncommittedChanges: Bool {
        worktrees.contains(where: \.isDirty)
    }

    /// Whether any worktree holds commits that exist nowhere but this machine.
    public var hasWorkOnlyHere: Bool {
        worktrees.contains { $0.status.isAtRisk }
    }

    public var hasPullRequests: Bool {
        worktrees.contains { $0.pullRequest != nil }
    }

    public init(
        root: String, remote: RemoteRepo?, defaultBranch: String,
        worktrees: [Worktree], lastFetch: Date? = nil, warning: String? = nil
    ) {
        self.root = root
        self.remote = remote
        self.defaultBranch = defaultBranch
        self.worktrees = worktrees
        self.lastFetch = lastFetch
        self.warning = warning
    }
}

import Foundation

public struct ScanOptions: Sendable {
    public var roots: [String]
    public var maxDepth: Int
    /// How many unique commits to read per worktree. The list only needs a count and
    /// the newest few subjects; reading the whole history of a long-lived branch is
    /// wasted work.
    public var commitLimit: Int
    public var lookUpPullRequests: Bool
    /// Fetch each remote before reading it. Off by default: it is the only part of a
    /// scan that touches the network, and a stale "published" is better than a scan
    /// that takes a minute every time the window opens.
    public var fetchFirst: Bool

    public init(
        roots: [String] = ["~/code"],
        maxDepth: Int = 2,
        commitLimit: Int = 50,
        lookUpPullRequests: Bool = true,
        fetchFirst: Bool = false
    ) {
        self.roots = roots
        self.maxDepth = maxDepth
        self.commitLimit = commitLimit
        self.lookUpPullRequests = lookUpPullRequests
        self.fetchFirst = fetchFirst
    }
}

/// Reads the state of every worktree under the configured roots.
public struct WorktreeScanner: Sendable {
    public var git: GitClient
    public var github: GitHubClient

    public init(git: GitClient, github: GitHubClient) {
        self.git = git
        self.github = github
    }

    public func scan(options: ScanOptions) async -> [Repository] {
        let candidates = RepositoryFinder.findRepositories(roots: options.roots, maxDepth: options.maxDepth)
        let roots = await deduplicate(candidates)

        var repositories: [Repository] = []
        await withTaskGroup(of: Repository?.self) { group in
            for root in roots {
                group.addTask { await self.read(root: root, options: options) }
            }
            for await repository in group {
                if let repository { repositories.append(repository) }
            }
        }
        return repositories.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Collapse candidates that are different worktrees of the same repository.
    ///
    /// Every worktree shares one `--git-common-dir`, so that is the identity. The main
    /// working copy is then taken from git's own list rather than from whichever
    /// directory the walk happened to reach first.
    func deduplicate(_ candidates: [String]) async -> [String] {
        var byCommonDir: [String: String] = [:]
        var order: [String] = []
        for candidate in candidates {
            guard
                let commonDir = await git.optional(
                    ["rev-parse", "--path-format=absolute", "--git-common-dir"],
                    in: candidate
                )
            else { continue }
            if byCommonDir[commonDir] == nil {
                byCommonDir[commonDir] = candidate
                order.append(commonDir)
            }
        }
        return order.compactMap { byCommonDir[$0] }
    }

    func read(root: String, options: ScanOptions) async -> Repository? {
        guard let porcelain = await git.optional(["worktree", "list", "--porcelain"], in: root) else {
            return nil
        }
        let entries = WorktreePorcelain.parse(porcelain).filter { !$0.isBare }
        guard let main = entries.first else { return nil }
        let repoRoot = main.path

        let remote = await readRemote(in: repoRoot)
        let defaultBranch = await readDefaultBranch(in: repoRoot, fallback: main.branch)

        var warning: String?
        if options.fetchFirst {
            do {
                try await git.fetch(in: repoRoot)
            } catch {
                warning = "Could not fetch: \(error.localizedDescription)"
            }
        }

        // Prefer the remote-tracking copy of the default branch as the base. A local
        // `main` can sit months behind and would report commits as unique that the
        // server merged long ago.
        let baseRef: String
        if await git.refExists("refs/remotes/origin/\(defaultBranch)", in: repoRoot) {
            baseRef = "refs/remotes/origin/\(defaultBranch)"
        } else if await git.refExists("refs/heads/\(defaultBranch)", in: repoRoot) {
            baseRef = "refs/heads/\(defaultBranch)"
        } else {
            baseRef = "HEAD"
        }

        var pullRequests: [String: PullRequest] = [:]
        if options.lookUpPullRequests, let remote, remote.isGitHub {
            if github.isAvailable {
                do {
                    pullRequests = try await github.pullRequestsByBranch(slug: remote.slug, in: repoRoot)
                } catch {
                    warning = warning ?? "No pull requests: \(error.localizedDescription)"
                }
            } else {
                warning = warning ?? "gh is not installed, so pull requests are not shown."
            }
        }

        // Bound before the group: the tasks below run concurrently, so they may only
        // capture values that are finished changing.
        let resolvedPullRequests = pullRequests
        let allPaths = entries.map(\.path)
        var worktrees: [Worktree] = []
        await withTaskGroup(of: Worktree.self) { group in
            for (index, entry) in entries.enumerated() {
                group.addTask {
                    await self.read(
                        entry: entry,
                        isMain: index == 0,
                        repoRoot: repoRoot,
                        baseRef: baseRef,
                        defaultBranch: defaultBranch,
                        pullRequests: resolvedPullRequests,
                        siblingPaths: allPaths,
                        options: options
                    )
                }
            }
            for await worktree in group { worktrees.append(worktree) }
        }

        return Repository(
            root: repoRoot,
            remote: remote,
            defaultBranch: defaultBranch,
            worktrees: sort(worktrees),
            lastFetch: lastFetchDate(in: repoRoot),
            warning: warning
        )
    }

    /// Main copy first, then the worktrees holding work that exists only here, then
    /// the rest newest-first. The ordering is the point of the list: what is at risk
    /// of being lost should never need scrolling to.
    func sort(_ worktrees: [Worktree]) -> [Worktree] {
        worktrees.sorted { lhs, rhs in
            if lhs.isMain != rhs.isMain { return lhs.isMain }
            if lhs.status.isAtRisk != rhs.status.isAtRisk { return lhs.status.isAtRisk }
            let left = lhs.lastCommitDate ?? .distantPast
            let right = rhs.lastCommitDate ?? .distantPast
            if left != right { return left > right }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    func read(
        entry: WorktreeEntry,
        isMain: Bool,
        repoRoot: String,
        baseRef: String,
        defaultBranch: String,
        pullRequests: [String: PullRequest],
        siblingPaths: [String],
        options: ScanOptions
    ) async -> Worktree {
        let head = entry.head ?? ""
        let branch = entry.branch
        let (upstream, sync) = await readSync(branch: branch, head: head, in: repoRoot)

        // A worktree whose directory has been deleted still appears in git's list. Its
        // commits are readable from the repository, but its status is not, so the
        // commands below run from the main copy in that case.
        let readable = FileManager.default.fileExists(atPath: entry.path) ? entry.path : repoRoot

        let commits = await git.log(
            base: baseRef,
            head: head.isEmpty ? "HEAD" : head,
            limit: options.commitLimit,
            in: readable
        )
        let dirty = await git.dirtyCount(in: entry.path, excluding: siblingPaths)

        return Worktree(
            path: entry.path,
            repoRoot: repoRoot,
            branch: branch,
            head: head,
            isMain: isMain,
            isLocked: entry.isLocked,
            isPrunable: entry.isPrunable,
            upstream: upstream,
            sync: sync,
            baseBranch: defaultBranch,
            uniqueCommits: commits,
            dirtyFileCount: dirty,
            lastCommitDate: commits.first?.date,
            pullRequest: branch.flatMap { pullRequests[$0] }
        )
    }

    /// Work out where the branch stands against the remote.
    ///
    /// The three cases that matter are told apart here: a configured upstream that is
    /// still there, a configured upstream the remote has deleted (git's `[gone]`), and
    /// a branch that was never pushed. Only the first can be compared with a count.
    func readSync(branch: String?, head: String, in repoRoot: String) async -> (String?, SyncState) {
        guard let branch else { return (nil, .noRemoteBranch) }

        let configured = await git.optional(
            ["for-each-ref", "--format=%(upstream:short)", "refs/heads/\(branch)"],
            in: repoRoot
        )
        let upstream = (configured?.isEmpty == false) ? configured : nil

        // A branch pushed by someone else, or by `git push` without `-u`, has a remote
        // copy but no configured upstream. Comparing against it is still the right
        // answer to "is this on GitHub?".
        let effective: String?
        if let upstream {
            effective = upstream
        } else if await git.refExists("refs/remotes/origin/\(branch)", in: repoRoot) {
            effective = "origin/\(branch)"
        } else {
            effective = nil
        }

        guard let effective else { return (upstream, .noRemoteBranch) }
        guard await git.refExists(effective, in: repoRoot) else {
            return (upstream, .remoteDeleted)
        }

        let counts = await git.optional(
            ["rev-list", "--left-right", "--count", "\(effective)...\(head)"],
            in: repoRoot
        )
        let parts =
            counts?
            .split(whereSeparator: { $0 == "\t" || $0 == " " })
            .compactMap { Int($0) } ?? []
        guard parts.count == 2 else { return (upstream, .upToDate) }
        let behind = parts[0]
        let ahead = parts[1]

        switch (ahead, behind) {
        case (0, 0): return (upstream, .upToDate)
        case (_, 0): return (upstream, .ahead(ahead))
        case (0, _): return (upstream, .behind(behind))
        default: return (upstream, .diverged(ahead: ahead, behind: behind))
        }
    }

    func readRemote(in repoRoot: String) async -> RemoteRepo? {
        if let origin = await git.optional(["remote", "get-url", "origin"], in: repoRoot),
            let parsed = RemoteRepo.parse(origin)
        {
            return parsed
        }
        // No `origin` is unusual but legal; take whichever remote is configured first.
        guard let remotes = await git.optional(["remote"], in: repoRoot) else { return nil }
        for name in remotes.split(separator: "\n").map(String.init) {
            if let url = await git.optional(["remote", "get-url", name], in: repoRoot),
                let parsed = RemoteRepo.parse(url)
            {
                return parsed
            }
        }
        return nil
    }

    func readDefaultBranch(in repoRoot: String, fallback: String?) async -> String {
        if let symbolic = await git.optional(
            ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"],
            in: repoRoot
        ), symbolic.hasPrefix("origin/") {
            return String(symbolic.dropFirst("origin/".count))
        }
        for candidate in ["main", "master"] {
            if await git.refExists("refs/remotes/origin/\(candidate)", in: repoRoot) {
                return candidate
            }
        }
        return fallback ?? "main"
    }

    /// When the remote-tracking refs were last refreshed.
    ///
    /// git touches FETCH_HEAD on every fetch, which makes it the cheapest honest
    /// answer to "how old is this?" — and the UI needs one, because "published" is
    /// only ever as current as the last fetch.
    func lastFetchDate(in repoRoot: String) -> Date? {
        let fm = FileManager.default
        for relative in [".git/FETCH_HEAD", ".git/refs/remotes/origin"] {
            let path = (repoRoot as NSString).appendingPathComponent(relative)
            if let attributes = try? fm.attributesOfItem(atPath: path),
                let date = attributes[.modificationDate] as? Date
            {
                return date
            }
        }
        return nil
    }
}

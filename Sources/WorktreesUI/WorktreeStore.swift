import Foundation
import Observation
import WorktreeKit

/// Everything the window shows, and the actions it can take.
@MainActor
@Observable
final class WorktreeStore {
    enum Filter: String, CaseIterable, Identifiable {
        case all
        case unpublished
        case published

        var id: String { rawValue }

        var label: String {
            switch self {
            case .all: "All"
            case .unpublished: "Only here"
            case .published: "On GitHub"
            }
        }

        func matches(_ worktree: Worktree) -> Bool {
            switch self {
            case .all: true
            case .unpublished: worktree.status.isAtRisk
            case .published:
                worktree.status == .published || worktree.pullRequest != nil
            }
        }
    }

    private(set) var repositories: [Repository] = []
    private(set) var isLoading = false
    private(set) var lastScan: Date?
    private(set) var toolError: String?
    private(set) var busyMessage: String?

    var filter: Filter = .all
    var search = ""
    var hideMatchingBase = Preferences.hideMatchingBase {
        didSet { Preferences.hideMatchingBase = hideMatchingBase }
    }
    var selection: Worktree.ID?
    /// The last completed action, shown as a banner so a button press has a visible
    /// result even when the change is off-screen in another directory.
    var lastResult: String?
    var actionError: String?

    private var path = ""
    private var gitExecutable: String?
    private var ghExecutable: String?

    init() {}

    /// Build a store with data already in it, for previews and view snapshots.
    init(repositories: [Repository], selection: Worktree.ID? = nil) {
        self.repositories = repositories
        self.selection = selection
        self.lastScan = Date()
    }

    var gitIsMissing: Bool { gitExecutable == nil }
    var ghIsMissing: Bool { ghExecutable == nil }

    // MARK: - Derived views of the data

    /// Repositories with the filter and the search applied, empty ones dropped.
    var visibleRepositories: [Repository] {
        repositories.compactMap { repository in
            let matches = repository.worktrees.filter { include($0, in: repository) }
            guard !matches.isEmpty else { return nil }
            var copy = repository
            copy.worktrees = matches
            return copy
        }
    }

    var allWorktrees: [Worktree] {
        repositories.flatMap(\.worktrees)
    }

    var selectedWorktree: Worktree? {
        guard let selection else { return nil }
        return allWorktrees.first { $0.id == selection }
    }

    func repository(for worktree: Worktree) -> Repository? {
        repositories.first { $0.root == worktree.repoRoot }
    }

    /// How many worktrees hold work that is on this machine only.
    var atRiskCount: Int {
        allWorktrees.filter { $0.status.isAtRisk }.count
    }

    private func include(_ worktree: Worktree, in repository: Repository) -> Bool {
        // The main copy is always listed: it is the answer to "where is my working
        // copy?", which the window should never make someone hunt for.
        if !worktree.isMain {
            if hideMatchingBase && worktree.status == .matchesBase { return false }
            guard filter.matches(worktree) else { return false }
        }
        guard !search.isEmpty else { return true }
        let needle = search.lowercased()
        return worktree.name.lowercased().contains(needle)
            || worktree.path.lowercased().contains(needle)
            || repository.name.lowercased().contains(needle)
            || (worktree.pullRequest.map { "#\($0.number) \($0.title)".lowercased().contains(needle) } ?? false)
    }

    // MARK: - Loading

    func bootstrap() async {
        path = await ShellEnvironment.loginPath()
        resolveTools()
        await refresh()
    }

    private func resolveTools() {
        gitExecutable = ExecutableLocator.resolve(
            override: Preferences.gitPath.isEmpty ? nil : Preferences.gitPath,
            named: "git",
            path: path
        )
        ghExecutable = ExecutableLocator.resolve(
            override: Preferences.ghPath.isEmpty ? nil : Preferences.ghPath,
            named: "gh",
            path: path
        )
        toolError = gitExecutable == nil
            ? "Could not find git. Set its path in Settings, or install the command line tools."
            : nil
    }

    /// Re-read the tool paths after Settings changed, then rescan.
    func reloadSettings() async {
        resolveTools()
        await refresh()
    }

    func refresh(fetchFirst: Bool? = nil) async {
        guard !isLoading else { return }
        guard let scanner = makeScanner() else { return }
        isLoading = true
        defer { isLoading = false }

        let options = ScanOptions(
            roots: Preferences.roots,
            maxDepth: Preferences.maxDepth,
            lookUpPullRequests: Preferences.lookUpPullRequests,
            fetchFirst: fetchFirst ?? Preferences.fetchOnRefresh
        )
        repositories = await scanner.scan(options: options)
        lastScan = Date()
        // A selection that survived a rescan should stay put; one that did not — the
        // worktree was removed — should not leave the detail pane showing a ghost.
        if let selection, !allWorktrees.contains(where: { $0.id == selection }) {
            self.selection = nil
        }
    }

    private func makeScanner() -> WorktreeScanner? {
        guard let gitExecutable else { return nil }
        let environment = ShellEnvironment.environment(path: path)
        return WorktreeScanner(
            git: GitClient(executable: gitExecutable, environment: environment),
            github: GitHubClient(executable: ghExecutable, environment: environment)
        )
    }

    private func makeGit() -> GitClient? {
        guard let gitExecutable else { return nil }
        return GitClient(executable: gitExecutable, environment: ShellEnvironment.environment(path: path))
    }

    // MARK: - Actions

    /// Fetch one repository so its published/unpushed answers are current.
    func fetch(_ repository: Repository) async {
        guard let git = makeGit() else { return }
        busyMessage = "Fetching \(repository.name)…"
        defer { busyMessage = nil }
        do {
            try await git.fetch(in: repository.root)
            await refresh(fetchFirst: false)
            lastResult = "Fetched \(repository.name)."
        } catch {
            actionError = "Could not fetch \(repository.name): \(error.localizedDescription)"
        }
    }

    func plan(for worktree: Worktree, mode: PullMode) async -> PullPlan? {
        guard let git = makeGit() else { return nil }
        return await WorkingCopyPuller(git: git).plan(for: worktree, mode: mode)
    }

    func pull(_ worktree: Worktree, plan: PullPlan) async {
        guard let git = makeGit() else { return }
        busyMessage = "Checking out in \(worktree.repoRoot)…"
        defer { busyMessage = nil }
        do {
            let summary = try await WorkingCopyPuller(git: git).perform(plan, worktree: worktree)
            lastResult = summary
            await refresh(fetchFirst: false)
        } catch {
            actionError = error.localizedDescription
        }
    }

    func dismissBanners() {
        lastResult = nil
        actionError = nil
    }
}

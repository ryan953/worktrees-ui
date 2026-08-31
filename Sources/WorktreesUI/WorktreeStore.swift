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

    /// How the repository list is split up.
    ///
    /// The facets are repository-level on purpose: the question these answer is "which
    /// repositories should I look at", and that is not a property of any one worktree.
    enum Grouping: String, CaseIterable, Identifiable {
        case repository
        case activity
        case pullRequests
        case size

        var id: String { rawValue }

        var label: String {
            switch self {
            case .repository: "Repository"
            case .activity: "Local changes"
            case .pullRequests: "Pull requests"
            case .size: "Worktree count"
            }
        }
    }

    struct RepositoryGroup: Identifiable {
        var title: String
        var repositories: [Repository]
        var id: String { title }
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
    var grouping = Grouping(rawValue: Preferences.grouping) ?? .repository {
        didSet { Preferences.grouping = grouping.rawValue }
    }
    var selection: Worktree.ID?
    /// The last completed action, shown as a banner so a button press has a visible
    /// result even when the change is off-screen in another directory.
    var lastResult: String?
    var actionError: String?

    private(set) var cleanupCandidates: [CleanupCandidate] = []
    private(set) var isPlanningCleanup = false
    private(set) var agentStatus: LaunchAgent.Status = .notInstalled
    /// Which candidates the cleanup sheet will act on.
    var cleanupSelection: Set<String> = []

    private var toolchain: Toolchain?

    init() {}

    /// Build a store with data already in it, for previews and view snapshots.
    init(
        repositories: [Repository],
        selection: Worktree.ID? = nil,
        cleanupCandidates: [CleanupCandidate] = [],
        agentStatus: LaunchAgent.Status = .notInstalled
    ) {
        self.repositories = repositories
        self.selection = selection
        self.cleanupCandidates = cleanupCandidates
        self.cleanupSelection = Set(Self.defaultSelection(cleanupCandidates).map(\.id))
        self.agentStatus = agentStatus
        self.lastScan = Date()
    }

    var gitIsMissing: Bool { toolchain == nil }
    var ghIsMissing: Bool { toolchain?.ghExecutable == nil }

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

    /// The visible repositories, split into the sections the sidebar draws.
    ///
    /// Empty groups are dropped rather than shown as empty headings, so the sidebar
    /// never asks anyone to read a category with nothing in it.
    var repositoryGroups: [RepositoryGroup] {
        let visible = visibleRepositories
        switch grouping {
        case .repository:
            return [RepositoryGroup(title: "", repositories: visible)]
        case .activity:
            return split(
                visible,
                by: \.hasLocalChanges,
                whenTrue: "Local changes",
                whenFalse: "Nothing local"
            )
        case .pullRequests:
            return split(
                visible,
                by: \.hasPullRequests,
                whenTrue: "With pull requests",
                whenFalse: "No pull requests"
            )
        case .size:
            return split(
                visible,
                by: \.isSolo,
                whenTrue: "Just the working copy",
                whenFalse: "With worktrees"
            )
        }
    }

    private func split(
        _ repositories: [Repository],
        by predicate: (Repository) -> Bool,
        whenTrue: String,
        whenFalse: String
    ) -> [RepositoryGroup] {
        let matching = repositories.filter(predicate)
        let rest = repositories.filter { !predicate($0) }
        return [
            RepositoryGroup(title: whenTrue, repositories: matching),
            RepositoryGroup(title: whenFalse, repositories: rest),
        ].filter { !$0.repositories.isEmpty }
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
        await resolveTools()
        agentStatus = LaunchAgent.default.status()
        await refresh()
    }

    private func resolveTools() async {
        do {
            toolchain = try await Toolchain.resolve(
                gitOverride: Preferences.gitPath.isEmpty ? nil : Preferences.gitPath,
                ghOverride: Preferences.ghPath.isEmpty ? nil : Preferences.ghPath
            )
            toolError = nil
        } catch {
            toolchain = nil
            toolError = error.localizedDescription
        }
    }

    /// Re-read the tool paths after Settings changed, then rescan.
    func reloadSettings() async {
        await resolveTools()
        agentStatus = LaunchAgent.default.status()
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
        toolchain?.scanner()
    }

    private func makeGit() -> GitClient? {
        toolchain?.git
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

    // MARK: - Cleanup

    /// Work out what could be removed right now.
    ///
    /// Planned under the manual policy: someone reading the list can see each
    /// worktree's state and choose, so the caution an unattended job needs would only
    /// hide options from them.
    func planCleanup() async {
        guard let git = makeGit() else { return }
        isPlanningCleanup = true
        defer { isPlanningCleanup = false }
        let policy = Preferences.policy(dryRun: true, manual: true)
        cleanupCandidates = await CleanupPlanner(git: git)
            .plan(repositories: repositories, policy: policy)
        cleanupSelection = Set(Self.defaultSelection(cleanupCandidates).map(\.id))
    }

    /// What starts out ticked.
    ///
    /// Everything safe is listed, but a worktree whose pull request is still open is
    /// left unticked: it is almost certainly live work, and a pre-ticked box is a
    /// decision made on someone's behalf.
    static func defaultSelection(_ candidates: [CleanupCandidate]) -> [CleanupCandidate] {
        candidates.filter { candidate in
            guard candidate.isRemovable else { return false }
            return candidate.grounds?.pullRequest.state != .open
        }
    }

    func runCleanup() async {
        guard let git = makeGit() else { return }
        // The same lock the scheduled job takes, so a cleanup started here and one that
        // fires at 9am can never remove the same worktrees at once.
        guard let lock = RunLock.default.acquire() else {
            actionError = "A scheduled cleanup is running right now. Try again in a moment."
            return
        }
        defer { lock.release() }

        busyMessage = "Removing worktrees…"
        defer { busyMessage = nil }
        var policy = Preferences.policy(dryRun: false, manual: true)
        policy.dryRun = false
        let report = await CleanupRunner(git: git)
            .run(cleanupCandidates, policy: policy, selected: cleanupSelection)

        let removed = report.removed.count
        if report.failures.isEmpty {
            lastResult = removed == 0
                ? "Nothing was removed."
                : "Removed \(Format.count(removed, "worktree", "worktrees")). "
                    + "Restore commands are in ~/Library/Logs/Worktrees/cleanup.log."
        } else {
            actionError = report.failures.compactMap {
                if case let .failed(message) = $0.result { return message }
                return nil
            }.joined(separator: " ")
        }
        cleanupCandidates = []
        cleanupSelection = []
        await refresh(fetchFirst: false)
    }

    var removableCount: Int {
        cleanupCandidates.filter(\.isRemovable).count
    }

    /// Judge one worktree, for the button in its detail pane.
    func decision(for worktree: Worktree) async -> CleanupDecision? {
        guard let git = makeGit(), let repository = repository(for: worktree) else { return nil }
        let policy = Preferences.policy(dryRun: true, manual: true)
        let holders = await ProcessCwdIndex.current()
        return await CleanupPlanner(git: git)
            .decide(worktree, in: repository, policy: policy, holders: holders)
    }

    /// Remove a single worktree that has already been judged removable.
    func remove(_ worktree: Worktree, decision: CleanupDecision) async {
        guard let git = makeGit(), let repository = repository(for: worktree) else { return }
        guard let lock = RunLock.default.acquire() else {
            actionError = "A scheduled cleanup is running right now. Try again in a moment."
            return
        }
        defer { lock.release() }

        busyMessage = "Removing \(worktree.displayName)…"
        defer { busyMessage = nil }
        let candidate = CleanupCandidate(
            worktree: worktree, repositoryName: repository.name, decision: decision)
        var policy = Preferences.policy(dryRun: false, manual: true)
        policy.dryRun = false
        let report = await CleanupRunner(git: git).run([candidate], policy: policy)

        if let failure = report.failures.first, case let .failed(message) = failure.result {
            actionError = message
        } else if let removed = report.removed.first {
            selection = nil
            lastResult = "Removed \(Format.path(removed.path)). "
                + "The restore command is in ~/Library/Logs/Worktrees/cleanup.log."
        }
        await refresh(fetchFirst: false)
    }

    // MARK: - The scheduled job

    func installAgent() async {
        guard let tool = LaunchAgent.bundledToolURL() else {
            actionError =
                "Could not find the worktrees-cleanup tool next to the app. "
                + "Install Worktrees.app rather than running it from a build directory."
            return
        }
        do {
            try await LaunchAgent.default.install(
                toolPath: tool.path, hour: Preferences.cleanupHour)
            agentStatus = LaunchAgent.default.status()
            lastResult = "Daily cleanup installed; it runs at \(Preferences.cleanupHour):00."
        } catch {
            actionError = "Could not install the scheduled job: \(error.localizedDescription)"
        }
    }

    func removeAgent() async {
        do {
            try await LaunchAgent.default.uninstall()
            agentStatus = LaunchAgent.default.status()
            lastResult = "Daily cleanup removed."
        } catch {
            actionError = "Could not remove the scheduled job: \(error.localizedDescription)"
        }
    }

    func runAgentNow() async {
        do {
            try await LaunchAgent.default.runNow()
            lastResult = "Cleanup started; see ~/Library/Logs/Worktrees/cleanup.out.log."
        } catch {
            actionError = "Could not start the scheduled job: \(error.localizedDescription)"
        }
    }
}

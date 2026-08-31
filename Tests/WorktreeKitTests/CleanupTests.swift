import Foundation
import Testing

@testable import WorktreeKit

@Suite("Cleanup decisions")
struct CleanupDecisionTests {
    static func repository(_ worktrees: [Worktree]) -> Repository {
        Repository(
            root: "/repo",
            remote: RemoteRepo(host: "github.com", owner: "o", name: "n"),
            defaultBranch: "main",
            worktrees: worktrees
        )
    }

    static func pullRequest(_ number: Int = 1, state: PullRequest.State = .merged) -> PullRequest {
        PullRequest(
            number: number, title: "A change", url: "https://github.com/o/n/pull/\(number)",
            state: state, isDraft: false, headRefName: "feature", baseRefName: "main"
        )
    }

    static func worktree(
        branch: String? = "feature",
        sync: SyncState = .upToDate,
        dirty: Int = 0,
        locked: Bool = false,
        pullRequest: PullRequest? = pullRequest(),
        daysOld: Int = 30
    ) -> Worktree {
        // An extra hour past the day boundary: idleDays truncates, so a date exactly
        // N*86400 ago lands on N-1 as soon as any time elapses.
        let age = TimeInterval(-(86400 * daysOld + 3600))
        return Worktree(
            path: "/repo/wt", repoRoot: "/repo", branch: branch, head: "abc123",
            isMain: false, isLocked: locked,
            upstream: branch.map { "origin/\($0)" }, sync: sync, baseBranch: "main",
            uniqueCommits: [
                Commit(
                    sha: "abc123", shortSHA: "abc123", subject: "work", author: "a",
                    date: Date().addingTimeInterval(age)
                )
            ],
            dirtyFileCount: dirty,
            lastCommitDate: Date().addingTimeInterval(age),
            pullRequest: pullRequest
        )
    }

    /// A planner whose git is never reached: these cases must all be decided from local
    /// state, before anything touches the network.
    static let offlinePlanner = CleanupPlanner(
        git: GitClient(executable: "/nonexistent", environment: [:])
    )

    static func decide(
        _ worktree: Worktree,
        policy: CleanupPolicy = CleanupPolicy(minimumAgeDays: 14),
        holders: ProcessCwdIndex = .empty
    ) async -> CleanupDecision {
        await offlinePlanner.decide(
            worktree, in: repository([worktree]), policy: policy, holders: holders)
    }

    @Test("The working copy is never a candidate")
    func keepsWorkingCopy() async {
        var worktree = Self.worktree()
        worktree.isMain = true
        #expect(await Self.decide(worktree) == .keep(.isWorkingCopy))
    }

    @Test("Uncommitted changes always win")
    func keepsDirty() async {
        let decision = await Self.decide(Self.worktree(dirty: 3))
        #expect(decision == .keep(.uncommittedChanges(3)))
    }

    @Test("A locked worktree is left alone")
    func keepsLocked() async {
        #expect(await Self.decide(Self.worktree(locked: true)) == .keep(.locked))
    }

    @Test("Without a pull request there is nothing keeping the commits on GitHub")
    func keepsWithoutPullRequest() async {
        #expect(await Self.decide(Self.worktree(pullRequest: nil)) == .keep(.noPullRequest))
    }

    @Test("An open pull request is left alone unless the policy says otherwise")
    func keepsOpenPullRequest() async {
        let worktree = Self.worktree(pullRequest: Self.pullRequest(7, state: .open))
        #expect(await Self.decide(worktree) == .keep(.pullRequestStillOpen(number: 7)))

        let permissive = CleanupPolicy(minimumAgeDays: 14, includesOpenPullRequests: true)
        #expect(await Self.decide(worktree, policy: permissive).isRemovable)
    }

    @Test("A worktree touched recently waits for the policy's period")
    func keepsRecent() async {
        let decision = await Self.decide(Self.worktree(daysOld: 3))
        #expect(decision == .keep(.tooRecent(idleDays: 3, required: 14)))
        // The same worktree is fair game once the period is zero, which is what the
        // button in the app uses.
        #expect(await Self.decide(Self.worktree(daysOld: 3), policy: CleanupPolicy(minimumAgeDays: 0)).isRemovable)
    }

    @Test("A worktree something is working in is left alone")
    func keepsInUse() async {
        let holders = ProcessCwdIndex(byDirectory: ["/repo/wt": "zsh (pid 42)"])
        let decision = await Self.decide(Self.worktree(), holders: holders)
        #expect(decision == .keep(.inUse("zsh (pid 42)")))
    }

    @Test("A process in a subdirectory counts as using the worktree")
    func keepsInUseFromSubdirectory() async {
        let holders = ProcessCwdIndex(byDirectory: ["/repo/wt/src/deep": "nvim (pid 9)"])
        let decision = await Self.decide(Self.worktree(), holders: holders)
        #expect(decision == .keep(.inUse("nvim (pid 9)")))
    }

    @Test("A pushed branch with a merged pull request can go")
    func removesPushed() async {
        let decision = await Self.decide(Self.worktree())
        guard case let .remove(grounds) = decision else {
            Issue.record("expected removal, got \(decision)")
            return
        }
        #expect(grounds.recovery == .remoteBranch("origin/feature"))
        #expect(grounds.pullRequest.number == 1)
        #expect(grounds.idleDays >= 29)
    }

    @Test("Commits not yet on the remote are never removed on the cheap path")
    func keepsUnpushedWithoutVerifying() async {
        // Ahead of the remote and git is unreachable, so the pull request ref cannot be
        // checked — the answer must be "keep", never "probably fine".
        let decision = await Self.decide(Self.worktree(sync: .ahead(2)))
        #expect(!decision.isRemovable)
    }
}

@Suite("Recovery and removal against real repositories")
struct CleanupIntegrationTests {
    typealias Fixture = ScannerIntegrationTests.Fixture

    static func scan(_ fixture: Fixture) async -> Repository? {
        await ScannerIntegrationTests.scanner(fixture.git)
            .scan(options: ScannerIntegrationTests.options(root: fixture.root))
            .first
    }

    @Test("A deleted branch is still recoverable through the pull request ref")
    func recoversThroughPullRequestRef() async throws {
        let fixture = try await ScannerIntegrationTests.makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }

        let path = try await fixture.addWorktree("merged", branch: "merged-work")
        try await fixture.commit("work that was merged", in: path)
        // GitHub keeps refs/pull/<n>/head after the branch is deleted, so the fixture
        // pushes to that ref and never creates the branch — which is exactly the state a
        // merged-and-tidied pull request leaves behind.
        try await fixture.run(["push", "origin", "merged-work:refs/pull/42/head"], in: path)
        try await fixture.run(["fetch", "--prune", "origin"], in: fixture.workingCopy)

        let repository = try #require(await Self.scan(fixture))
        var worktree = try #require(repository.worktrees.first { $0.branch == "merged-work" })
        #expect(worktree.status == .localOnly, "the branch itself is not on the remote")
        worktree.pullRequest = CleanupDecisionTests.pullRequest(42)

        let planner = CleanupPlanner(git: fixture.git)
        let decision = await planner.decide(
            worktree, in: repository, policy: CleanupPolicy(minimumAgeDays: 0))
        guard case let .remove(grounds) = decision else {
            Issue.record("expected removal, got \(decision)")
            return
        }
        #expect(grounds.recovery == .pullRequestRef(number: 42))
        #expect(grounds.recovery.restoreCommand(path: path, branch: "merged-work")
            .contains("refs/pull/42/head"))
    }

    @Test("Commits missing from the pull request ref are not removable")
    func refusesWhenCommitsAreNotOnGitHub() async throws {
        let fixture = try await ScannerIntegrationTests.makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }

        let path = try await fixture.addWorktree("ahead", branch: "ahead-work")
        try await fixture.commit("pushed", in: path)
        try await fixture.run(["push", "origin", "ahead-work:refs/pull/43/head"], in: path)
        // One more commit that never left this disk.
        try await fixture.commit("never pushed", in: path)
        try await fixture.run(["fetch", "--prune", "origin"], in: fixture.workingCopy)

        let repository = try #require(await Self.scan(fixture))
        var worktree = try #require(repository.worktrees.first { $0.branch == "ahead-work" })
        worktree.pullRequest = CleanupDecisionTests.pullRequest(43)

        let decision = await CleanupPlanner(git: fixture.git).decide(
            worktree, in: repository, policy: CleanupPolicy(minimumAgeDays: 0))
        #expect(!decision.isRemovable)
        if case let .keep(reason) = decision, case .notOnGitHub = reason {
            // Correct: the extra commit exists nowhere else.
        } else {
            Issue.record("expected notOnGitHub, got \(decision)")
        }
    }

    @Test("Removing takes the directory and the branch, and logs how to undo it")
    func removesAndLogs() async throws {
        let fixture = try await ScannerIntegrationTests.makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }

        let path = try await fixture.addWorktree("done", branch: "done-work")
        try await fixture.commit("finished", in: path)
        try await fixture.run(["push", "-u", "origin", "done-work"], in: path)
        try await fixture.run(["fetch", "origin"], in: fixture.workingCopy)

        let repository = try #require(await Self.scan(fixture))
        var worktree = try #require(repository.worktrees.first { $0.branch == "done-work" })
        worktree.pullRequest = CleanupDecisionTests.pullRequest(44)

        let decision = await CleanupPlanner(git: fixture.git).decide(
            worktree, in: repository, policy: CleanupPolicy(minimumAgeDays: 0))
        #expect(decision.isRemovable)

        let logURL = URL(fileURLWithPath: fixture.root).appendingPathComponent("cleanup.log")
        let runner = CleanupRunner(git: fixture.git, log: CleanupLog(url: logURL))
        let candidate = CleanupCandidate(
            worktree: worktree, repositoryName: "fixture", decision: decision)
        let report = await runner.run(
            [candidate], policy: CleanupPolicy(minimumAgeDays: 0, dryRun: false))

        #expect(report.removed.count == 1)
        #expect(!FileManager.default.fileExists(atPath: path))
        let branches = try await fixture.git.output(
            ["branch", "--list", "done-work"], in: fixture.workingCopy)
        #expect(branches.isEmpty, "the local branch goes with the worktree")

        let log = try String(contentsOf: logURL, encoding: .utf8)
        #expect(log.contains("REMOVED"))
        #expect(log.contains("restore:"), "a removal without a restore command is not acceptable")
        #expect(log.contains("worktree add"))
    }

    @Test("A dry run reports without touching anything")
    func dryRunChangesNothing() async throws {
        let fixture = try await ScannerIntegrationTests.makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }

        let path = try await fixture.addWorktree("keep", branch: "keep-work")
        try await fixture.commit("finished", in: path)
        try await fixture.run(["push", "-u", "origin", "keep-work"], in: path)
        try await fixture.run(["fetch", "origin"], in: fixture.workingCopy)

        let repository = try #require(await Self.scan(fixture))
        var worktree = try #require(repository.worktrees.first { $0.branch == "keep-work" })
        worktree.pullRequest = CleanupDecisionTests.pullRequest(45)
        let decision = await CleanupPlanner(git: fixture.git).decide(
            worktree, in: repository, policy: CleanupPolicy(minimumAgeDays: 0))

        let candidate = CleanupCandidate(
            worktree: worktree, repositoryName: "fixture", decision: decision)
        let report = await CleanupRunner(git: fixture.git).run(
            [candidate], policy: CleanupPolicy(minimumAgeDays: 0, dryRun: true))

        #expect(report.wouldRemove.count == 1)
        #expect(report.removed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test("A selection narrows what is removed")
    func honoursSelection() async throws {
        let fixture = try await ScannerIntegrationTests.makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }

        var candidates: [CleanupCandidate] = []
        for name in ["one", "two"] {
            let path = try await fixture.addWorktree(name, branch: "\(name)-work")
            try await fixture.commit("work", in: path)
            try await fixture.run(["push", "-u", "origin", "\(name)-work"], in: path)
        }
        try await fixture.run(["fetch", "origin"], in: fixture.workingCopy)
        let repository = try #require(await Self.scan(fixture))

        for name in ["one", "two"] {
            var worktree = try #require(repository.worktrees.first { $0.branch == "\(name)-work" })
            worktree.pullRequest = CleanupDecisionTests.pullRequest(46)
            let decision = await CleanupPlanner(git: fixture.git).decide(
                worktree, in: repository, policy: CleanupPolicy(minimumAgeDays: 0))
            candidates.append(
                CleanupCandidate(worktree: worktree, repositoryName: "fixture", decision: decision))
        }

        let chosen = try #require(candidates.first { $0.worktree.branch == "one-work" })
        let report = await CleanupRunner(git: fixture.git).run(
            candidates,
            policy: CleanupPolicy(minimumAgeDays: 0, dryRun: false),
            selected: [chosen.id]
        )
        #expect(report.removed.count == 1)
        #expect(!FileManager.default.fileExists(atPath: chosen.worktree.path))
        let other = try #require(candidates.first { $0.worktree.branch == "two-work" })
        #expect(FileManager.default.fileExists(atPath: other.worktree.path))
    }
}

@Suite("Supporting pieces")
struct CleanupSupportTests {
    @Test("lsof records are read back into directories and holders")
    func parsesLsof() {
        let output = """
            p512
            czsh
            fcwd
            n/Users/me/code/app
            p777
            cnvim
            fcwd
            n/Users/me/code/app/.claude/worktrees/feature
            """
        let index = ProcessCwdIndex.parse(output)
        #expect(index.holder(of: "/Users/me/code/app") == "zsh (pid 512)")
        #expect(
            index.holder(of: "/Users/me/code/app/.claude/worktrees/feature") == "nvim (pid 777)")
        #expect(index.holder(of: "/Users/me/elsewhere") == nil)
    }

    @Test("The plist names the tool, runs daily, and stays out of the way")
    func buildsPlist() throws {
        let agent = LaunchAgent(
            label: "com.example.cleanup",
            plistURL: URL(fileURLWithPath: "/tmp/x.plist"),
            logDirectory: URL(fileURLWithPath: "/tmp/logs")
        )
        let plist = agent.plist(toolPath: "/Applications/Worktrees.app/Contents/MacOS/worktrees-cleanup", hour: 9)
        #expect(plist["Label"] as? String == "com.example.cleanup")
        let arguments = try #require(plist["ProgramArguments"] as? [String])
        #expect(arguments.first?.hasSuffix("worktrees-cleanup") == true)
        // Without --apply the scheduled job would report and never clean anything.
        #expect(arguments.contains("--apply"))
        let schedule = try #require(plist["StartCalendarInterval"] as? [String: Any])
        #expect(schedule["Hour"] as? Int == 9)
        #expect(schedule["Minute"] as? Int == 0)
        #expect(plist["RunAtLoad"] as? Bool == false)
        #expect(plist["ProcessType"] as? String == "Background")
    }

    @Test("An out-of-range hour is clamped rather than written into launchd")
    func clampsHour() {
        let agent = LaunchAgent.default
        let schedule = agent.plist(toolPath: "/bin/true", hour: 99)["StartCalendarInterval"]
        #expect((schedule as? [String: Any])?["Hour"] as? Int == 23)
    }

    @Test("The lock keeps a second run out, and a stale one does not block forever")
    func locks() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("worktrees-lock-\(UUID().uuidString)")
        let lock = RunLock(url: directory, staleAfter: 3600)

        let first = try #require(lock.acquire())
        #expect(lock.acquire() == nil, "a second run must not get in")
        first.release()
        let third = try #require(lock.acquire())
        third.release()

        // A lock older than its lease is broken rather than left to block every run.
        let stale = RunLock(url: directory, staleAfter: 0)
        let held = try #require(stale.acquire())
        let broken = stale.acquire()
        #expect(broken != nil)
        held.release()
        broken?.release()
    }
}

import Foundation
import Testing

@testable import WorktreeKit

/// Exercises the one action that writes to a directory the user is not looking at.
///
/// These run the real checkouts against real repositories, because the failure that
/// matters — ending up with a detached worktree *and* a working copy that never moved —
/// only shows up in the state git is left in.
@Suite("Pulling into the working copy")
struct PullTests {
    typealias Fixture = ScannerIntegrationTests.Fixture

    static func puller(_ git: GitClient) -> WorkingCopyPuller {
        WorkingCopyPuller(git: git)
    }

    static func scan(_ fixture: Fixture) async -> Repository? {
        await ScannerIntegrationTests.scanner(fixture.git)
            .scan(options: ScannerIntegrationTests.options(root: fixture.root))
            .first
    }

    @Test("Moving the branch leaves the working copy on it and the worktree detached")
    func movesTheBranch() async throws {
        let fixture = try await ScannerIntegrationTests.makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }

        let path = try await fixture.addWorktree("feature", branch: "feature")
        try await fixture.commit("work in the worktree", in: path)

        let repository = try #require(await Self.scan(fixture))
        let worktree = try #require(repository.worktrees.first { $0.branch == "feature" })

        let puller = Self.puller(fixture.git)
        let plan = await puller.plan(for: worktree, mode: .moveBranch)
        #expect(plan.canProceed)
        #expect(plan.steps.count == 2)

        let summary = try await puller.perform(plan, worktree: worktree)
        #expect(summary.contains("feature"))

        // The working copy is on the branch, which is the whole point.
        let checkedOut = try await fixture.git.output(
            ["symbolic-ref", "--short", "HEAD"], in: fixture.workingCopy)
        #expect(checkedOut == "feature")

        // And the worktree let go of it, rather than both claiming the same branch.
        let worktreeHead = await fixture.git.optional(
            ["symbolic-ref", "--quiet", "--short", "HEAD"], in: path)
        #expect(worktreeHead == nil)

        // The files are still there: detaching moves a ref, not a directory.
        let stillThere = try await fixture.git.output(["rev-parse", "HEAD"], in: path)
        #expect(stillThere == worktree.head)
    }

    @Test("Checking out the commit leaves the worktree alone")
    func copiesTheCommit() async throws {
        let fixture = try await ScannerIntegrationTests.makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }

        let path = try await fixture.addWorktree("spike", branch: "spike")
        try await fixture.commit("a spike", in: path)

        let repository = try #require(await Self.scan(fixture))
        let worktree = try #require(repository.worktrees.first { $0.branch == "spike" })

        let puller = Self.puller(fixture.git)
        let plan = await puller.plan(for: worktree, mode: .copyCommit)
        #expect(plan.canProceed)
        try await puller.perform(plan, worktree: worktree)

        let head = try await fixture.git.output(["rev-parse", "HEAD"], in: fixture.workingCopy)
        #expect(head == worktree.head)
        // Detached, so nothing committed here lands on a branch by accident.
        #expect(await fixture.git.optional(["symbolic-ref", "--quiet", "HEAD"], in: fixture.workingCopy) == nil)
        // The worktree still owns its branch.
        let worktreeBranch = try await fixture.git.output(
            ["symbolic-ref", "--short", "HEAD"], in: path)
        #expect(worktreeBranch == "spike")
    }

    @Test("Refuses to check out over uncommitted work")
    func refusesWhenTheWorkingCopyIsDirty() async throws {
        let fixture = try await ScannerIntegrationTests.makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }

        let path = try await fixture.addWorktree("feature", branch: "feature")
        try await fixture.commit("work", in: path)
        // An edit to a tracked file, which a checkout would carry across or refuse.
        let tracked = try await fixture.git.output(
            ["ls-files", "--full-name"], in: fixture.workingCopy)
        let first = try #require(tracked.split(separator: "\n").first.map(String.init))
        try "edited\n".write(
            toFile: (fixture.workingCopy as NSString).appendingPathComponent(first),
            atomically: true,
            encoding: .utf8
        )

        let repository = try #require(await Self.scan(fixture))
        let worktree = try #require(repository.worktrees.first { $0.branch == "feature" })

        let puller = Self.puller(fixture.git)
        for mode in PullMode.allCases {
            let plan = await puller.plan(for: worktree, mode: mode)
            #expect(!plan.canProceed, "\(mode) should be blocked by a dirty working copy")
            #expect(plan.blockers.contains { $0.contains("uncommitted") })
            await #expect(throws: (any Error).self) {
                try await puller.perform(plan, worktree: worktree)
            }
        }
    }

    @Test("Refuses the working copy itself and a branch already checked out there")
    func refusesPointlessMoves() async throws {
        let fixture = try await ScannerIntegrationTests.makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }

        _ = try await fixture.addWorktree("feature", branch: "feature")
        let repository = try #require(await Self.scan(fixture))
        let puller = Self.puller(fixture.git)

        let main = try #require(repository.worktrees.first { $0.isMain })
        let mainPlan = await puller.plan(for: main, mode: .moveBranch)
        #expect(!mainPlan.canProceed)
        #expect(mainPlan.blockers.contains { $0.contains("working copy") })

        // Move it once, then the same move is no longer meaningful.
        let worktree = try #require(repository.worktrees.first { $0.branch == "feature" })
        try await puller.perform(
            await puller.plan(for: worktree, mode: .moveBranch), worktree: worktree)
        let second = await puller.plan(for: worktree, mode: .moveBranch)
        #expect(!second.canProceed)
        #expect(second.blockers.contains { $0.contains("already on feature") })
    }

    @Test("A detached worktree has no branch to move, but its commit can still come over")
    func handlesDetachedWorktree() async throws {
        let fixture = try await ScannerIntegrationTests.makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }

        let path = try await fixture.addWorktree("loose", branch: "loose")
        try await fixture.commit("work", in: path)
        try await fixture.run(["checkout", "--detach"], in: path)

        let repository = try #require(await Self.scan(fixture))
        let worktree = try #require(repository.worktrees.first { $0.path == path })
        #expect(worktree.status == .detached)

        let puller = Self.puller(fixture.git)
        let move = await puller.plan(for: worktree, mode: .moveBranch)
        #expect(!move.canProceed)

        let copy = await puller.plan(for: worktree, mode: .copyCommit)
        #expect(copy.canProceed)
        try await puller.perform(copy, worktree: worktree)
        let head = try await fixture.git.output(["rev-parse", "HEAD"], in: fixture.workingCopy)
        #expect(head == worktree.head)
    }
}

import Foundation
import Testing

@testable import WorktreeKit

/// Drives the scanner against real repositories on disk.
///
/// The whole app rests on one judgement — whether a branch's commits are on GitHub —
/// and that answer comes from git's own refs. Mocking git here would test the mock, so
/// these build a bare "remote", clone it, and push (or do not push) for real.
@Suite("Scanner against real repositories")
struct ScannerIntegrationTests {
    /// The real path, following symlinks.
    ///
    /// `/var` is a symlink to `/private/var`, and git always answers with the resolved
    /// spelling. Foundation's `resolvingSymlinksInPath` deliberately does the reverse
    /// for temporary directories, so `realpath` is what actually agrees with git.
    static func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// A git that ignores the machine's own configuration, so a user's `init.defaultBranch`,
    /// signing key or hooks cannot change what these tests see.
    static func makeGit() -> GitClient {
        var environment = ShellEnvironment.environment(path: ShellEnvironment.merge(""))
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        environment["GIT_AUTHOR_NAME"] = "Test"
        environment["GIT_AUTHOR_EMAIL"] = "test@example.com"
        environment["GIT_COMMITTER_NAME"] = "Test"
        environment["GIT_COMMITTER_EMAIL"] = "test@example.com"
        return GitClient(executable: "/usr/bin/git", environment: environment)
    }

    struct Fixture {
        var root: String
        var workingCopy: String
        var git: GitClient

        @discardableResult
        func run(_ arguments: [String], in directory: String? = nil) async throws -> String {
            try await git.output(arguments, in: directory ?? workingCopy, timeout: 60)
        }

        func commit(_ message: String, in directory: String? = nil) async throws {
            let dir = directory ?? workingCopy
            let name = UUID().uuidString.prefix(8)
            try (message + "\n").write(
                toFile: (dir as NSString).appendingPathComponent("\(name).txt"),
                atomically: true,
                encoding: .utf8
            )
            try await run(["add", "-A"], in: dir)
            try await run(["commit", "-m", message], in: dir)
        }

        /// Add a worktree under the layout Claude Code and `wt` both use.
        func addWorktree(_ name: String, branch: String) async throws -> String {
            let path = (workingCopy as NSString).appendingPathComponent(".claude/worktrees/\(name)")
            try await run(["worktree", "add", "-b", branch, path])
            return path
        }
    }

    static func makeFixture() async throws -> Fixture {
        let git = makeGit()
        let created = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("worktrees-ui-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: created, withIntermediateDirectories: true)
        let root = Self.canonicalPath(created)

        let origin = (root as NSString).appendingPathComponent("origin.git")
        _ = try await git.output(["init", "--bare", "--initial-branch=main", origin], in: root)

        let workingCopy = (root as NSString).appendingPathComponent("work")
        _ = try await git.output(["clone", origin, workingCopy], in: root)

        let fixture = Fixture(root: root, workingCopy: workingCopy, git: git)
        try await fixture.run(["config", "user.email", "test@example.com"])
        try await fixture.run(["config", "user.name", "Test"])
        try await fixture.commit("initial")
        try await fixture.run(["push", "-u", "origin", "main"])
        return fixture
    }

    static func scanner(_ git: GitClient) -> WorktreeScanner {
        WorktreeScanner(
            git: git,
            // No `gh`: these tests are about git's answer, and a pull request lookup
            // would need a network and a token.
            github: GitHubClient(executable: nil, environment: [:])
        )
    }

    static func options(root: String) -> ScanOptions {
        ScanOptions(roots: [root], maxDepth: 1, commitLimit: 20, lookUpPullRequests: false)
    }

    @Test("Tells apart local-only, unpushed, published and deleted branches")
    func classifiesWorktrees() async throws {
        let fixture = try await Self.makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }

        // Committed here, never pushed anywhere.
        let localOnly = try await fixture.addWorktree("local", branch: "local-only")
        try await fixture.commit("only on this disk", in: localOnly)

        // Pushed, and nothing added since.
        let published = try await fixture.addWorktree("published", branch: "published-branch")
        try await fixture.commit("shared work", in: published)
        try await fixture.run(["push", "-u", "origin", "published-branch"], in: published)

        // Pushed, then carried on committing.
        let unpushed = try await fixture.addWorktree("unpushed", branch: "unpushed-branch")
        try await fixture.commit("shared work", in: unpushed)
        try await fixture.run(["push", "-u", "origin", "unpushed-branch"], in: unpushed)
        try await fixture.commit("still on this disk", in: unpushed)

        // Pushed, then deleted on the remote — what a merged pull request leaves behind.
        let gone = try await fixture.addWorktree("gone", branch: "gone-branch")
        try await fixture.commit("merged and tidied", in: gone)
        try await fixture.run(["push", "-u", "origin", "gone-branch"], in: gone)
        try await fixture.run(["push", "origin", "--delete", "gone-branch"], in: gone)
        try await fixture.run(["fetch", "--prune", "origin"], in: fixture.workingCopy)

        let repositories = await Self.scanner(fixture.git).scan(options: Self.options(root: fixture.root))
        #expect(repositories.count == 1)
        let repository = try #require(repositories.first)

        #expect(repository.root == fixture.workingCopy)
        #expect(repository.defaultBranch == "main")
        #expect(repository.worktrees.count == 5)

        func status(_ branch: String) -> WorktreeStatus? {
            repository.worktrees.first { $0.branch == branch }?.status
        }
        #expect(status("main") == .matchesBase)
        #expect(status("local-only") == .localOnly)
        #expect(status("published-branch") == .published)
        #expect(status("unpushed-branch") == .unpushed)
        #expect(status("gone-branch") == .remoteDeleted)
    }

    @Test("Counts only the commits the base branch does not have")
    func countsUniqueCommits() async throws {
        let fixture = try await Self.makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }

        let path = try await fixture.addWorktree("feature", branch: "feature")
        try await fixture.commit("first", in: path)
        try await fixture.commit("second", in: path)

        // Moving the base on should not change what is unique to the branch.
        try await fixture.commit("unrelated work on main")
        try await fixture.run(["push", "origin", "main"])
        try await fixture.run(["fetch", "origin"])

        let repositories = await Self.scanner(fixture.git).scan(options: Self.options(root: fixture.root))
        let feature = try #require(repositories.first?.worktrees.first { $0.branch == "feature" })
        #expect(feature.uniqueCommits.count == 2)
        #expect(feature.uniqueCommits.first?.subject == "second")
        #expect(feature.uniqueCommits.last?.subject == "first")

        let main = try #require(repositories.first?.worktrees.first { $0.isMain })
        #expect(main.uniqueCommits.isEmpty)
    }

    @Test("Every worktree names the same working copy, and it is the main one")
    func reportsWorkingCopy() async throws {
        let fixture = try await Self.makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }

        _ = try await fixture.addWorktree("nested", branch: "nested")
        // A worktree outside the repository directory: the walk finds it on its own, so
        // this is what proves the two are collapsed into one repository rather than
        // listed twice with the wrong root.
        let loose = (fixture.root as NSString).appendingPathComponent("loose")
        try await fixture.run(["worktree", "add", "-b", "loose", loose])

        let repositories = await Self.scanner(fixture.git).scan(options: Self.options(root: fixture.root))
        #expect(repositories.count == 1)
        let repository = try #require(repositories.first)
        #expect(repository.root == fixture.workingCopy)
        #expect(repository.worktrees.allSatisfy { $0.repoRoot == fixture.workingCopy })
        #expect(repository.worktrees.filter(\.isMain).count == 1)
        #expect(repository.mainWorktree?.path == fixture.workingCopy)
        #expect(repository.linkedWorktrees.count == 2)
    }

    @Test("Counts uncommitted changes in the worktree they belong to")
    func countsDirtyFiles() async throws {
        let fixture = try await Self.makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }

        let path = try await fixture.addWorktree("dirty", branch: "dirty")
        try "scratch\n".write(
            toFile: (path as NSString).appendingPathComponent("untracked.txt"),
            atomically: true,
            encoding: .utf8
        )

        let repositories = await Self.scanner(fixture.git).scan(options: Self.options(root: fixture.root))
        let dirty = try #require(repositories.first?.worktrees.first { $0.branch == "dirty" })
        #expect(dirty.dirtyFileCount == 1)
        #expect(dirty.isDirty)

        let main = try #require(repositories.first?.worktrees.first { $0.isMain })
        #expect(main.isDirty == false)
    }

    @Test("Reads a branch pushed without an upstream as published anyway")
    func handlesMissingUpstream() async throws {
        let fixture = try await Self.makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }

        let path = try await fixture.addWorktree("noupstream", branch: "no-upstream")
        try await fixture.commit("work", in: path)
        // No -u, so nothing is configured to track; the remote branch still exists.
        try await fixture.run(["push", "origin", "no-upstream"], in: path)
        try await fixture.run(["fetch", "origin"], in: fixture.workingCopy)

        let repositories = await Self.scanner(fixture.git).scan(options: Self.options(root: fixture.root))
        let worktree = try #require(repositories.first?.worktrees.first { $0.branch == "no-upstream" })
        #expect(worktree.upstream == nil)
        #expect(worktree.status == .published)
    }
}

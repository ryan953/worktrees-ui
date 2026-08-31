import Foundation
import Testing

@testable import WorktreeKit

/// Scans this machine's real repositories and prints what the app would show.
///
/// Off unless `WORKTREES_UI_LIVE_SCAN` is set: it depends on whatever happens to be
/// checked out, so it can never assert. It exists to answer "is the app telling the
/// truth about my repositories?" without launching a window.
@Suite(
    "Live scan",
    .enabled(if: ProcessInfo.processInfo.environment["WORKTREES_UI_LIVE_SCAN"] != nil)
)
struct LiveScanTests {
    @Test("Reports every worktree under the configured roots")
    func scanRealRepositories() async throws {
        let roots = ProcessInfo.processInfo.environment["WORKTREES_UI_LIVE_ROOTS"]
            .map { $0.split(separator: ":").map(String.init) } ?? ["~/code"]
        let path = await ShellEnvironment.loginPath()
        let environment = ShellEnvironment.environment(path: path)
        let git = try #require(ExecutableLocator.find(named: "git", in: path))
        let scanner = WorktreeScanner(
            git: GitClient(executable: git, environment: environment),
            github: GitHubClient(
                executable: ExecutableLocator.find(named: "gh", in: path),
                environment: environment
            )
        )

        let started = Date()
        let repositories = await scanner.scan(
            options: ScanOptions(roots: roots, maxDepth: 2, lookUpPullRequests: true)
        )
        let elapsed = Date().timeIntervalSince(started)

        var lines: [String] = []
        lines.append(String(format: "Scanned %d repositories in %.1fs", repositories.count, elapsed))
        for repository in repositories where repository.linkedWorktrees.count > 0 {
            lines.append("")
            lines.append("\(repository.name)  [\(repository.remote?.slug ?? "no remote")]")
            lines.append("  working copy: \(repository.root)")
            if let warning = repository.warning { lines.append("  warning: \(warning)") }
            for worktree in repository.worktrees {
                let pr = worktree.pullRequest.map { " \($0.label)" } ?? ""
                let dirty = worktree.isDirty ? " ~\(worktree.dirtyFileCount)" : ""
                lines.append(
                    "  \(worktree.isMain ? "*" : "-") "
                        + "\(worktree.status.label.padding(toLength: 15, withPad: " ", startingAt: 0)) "
                        + "\(worktree.uniqueCommits.count) unique\(dirty)\(pr)  \(worktree.name)"
                )
            }
        }
        print(lines.joined(separator: "\n"))
        #expect(!repositories.isEmpty, "no repositories found under \(roots)")
    }
}

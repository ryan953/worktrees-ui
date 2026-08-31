import Foundation
import WorktreeKit

@testable import WorktreesUI

/// One repository showing every status the list can display, and a second so the
/// grouping is exercised too.
enum Fixtures {
    static let home = NSHomeDirectory()

    /// Point settings at a throwaway suite before anything reads them. Tests set
    /// preferences as a side effect of driving the store, and those writes must not
    /// reach the installed app — or the next test.
    static func useTemporaryPreferences() {
        let name = "com.ryan953.worktrees-ui.tests"
        UserDefaults.standard.removePersistentDomain(forName: name)
        Preferences.store = UserDefaults(suiteName: name) ?? .standard
    }

    static func commit(_ subject: String, _ minutesAgo: Int, sha: String) -> Commit {
        Commit(
            sha: sha + String(repeating: "0", count: max(0, 40 - sha.count)),
            shortSHA: String(sha.prefix(7)),
            subject: subject,
            author: "Sam Rivers",
            date: Date().addingTimeInterval(TimeInterval(-60 * minutesAgo))
        )
    }

    static func repositories() -> [Repository] {
        let seerRoot = "\(home)/code/seer"
        let seer = Repository(
            root: seerRoot,
            remote: RemoteRepo(host: "github.com", owner: "getsentry", name: "seer"),
            defaultBranch: "main",
            worktrees: [
                Worktree(
                    path: seerRoot, repoRoot: seerRoot, branch: "main",
                    head: "47f04af9485976084e74d92c6a4649818c07ad76",
                    isMain: true, sync: .upToDate, baseBranch: "main"
                ),
                Worktree(
                    path: "\(seerRoot)/.claude/worktrees/autofix-trigger",
                    repoRoot: seerRoot, branch: "seer/autofix-trigger-recall",
                    head: "7d7a18478f17862dde96e0d521b47ffc904fd5a9",
                    isMain: false, upstream: nil, sync: .noRemoteBranch, baseBranch: "main",
                    uniqueCommits: [
                        commit("feat(autofix): recall the trigger for a repeated run", 40, sha: "7d7a184"),
                        commit("test: cover the recall path", 95, sha: "a91bd02"),
                    ],
                    dirtyFileCount: 3,
                    lastCommitDate: Date().addingTimeInterval(-2400)
                ),
                Worktree(
                    path: "\(seerRoot)/.claude/worktrees/pr7795-embed",
                    repoRoot: seerRoot, branch: "pr7795-embed",
                    head: "58e615026bf246349d8cf3702d77a2430b82088c",
                    isMain: false, upstream: "origin/pr7795-embed",
                    sync: .ahead(2), baseBranch: "main",
                    uniqueCommits: [
                        commit("feat(embed): log the widget schema on each request", 180, sha: "58e6150"),
                        commit("refactor: pull the schema out of the fixture list", 260, sha: "c40aa19"),
                        commit("feat(embed): read the runtime source", 700, sha: "1f28e73"),
                    ],
                    lastCommitDate: Date().addingTimeInterval(-10800),
                    pullRequest: PullRequest(
                        number: 7795,
                        title: "Log the embed widget schema that production actually sends",
                        url: "https://github.com/getsentry/seer/pull/7795",
                        state: .open, isDraft: true,
                        headRefName: "pr7795-embed", baseRefName: "main"
                    )
                ),
                Worktree(
                    path: "\(seerRoot)/.claude/worktrees/codegen",
                    repoRoot: seerRoot, branch: "seer/codegen-cards",
                    head: "b31f7a2c9d4e5061728394a5b6c7d8e9f0a1b2c3",
                    isMain: false, upstream: "origin/seer/codegen-cards",
                    sync: .upToDate, baseBranch: "main",
                    uniqueCommits: [
                        commit("feat(codegen): generate the API cards from the spec", 1500, sha: "b31f7a2")
                    ],
                    lastCommitDate: Date().addingTimeInterval(-90000),
                    pullRequest: PullRequest(
                        number: 7801, title: "Generate the API cards from the OpenAPI spec",
                        url: "https://github.com/getsentry/seer/pull/7801",
                        state: .open, isDraft: false,
                        headRefName: "seer/codegen-cards", baseRefName: "main"
                    )
                ),
                Worktree(
                    path: "\(seerRoot)/.claude/worktrees/merged-work",
                    repoRoot: seerRoot, branch: "seer/embed-logging",
                    head: "e7c1908a5b6c7d8e9f0a1b2c3d4e5f6071829304",
                    isMain: false, upstream: "origin/seer/embed-logging",
                    sync: .remoteDeleted, baseBranch: "main",
                    uniqueCommits: [commit("feat: embed logging", 4300, sha: "e7c1908")],
                    lastCommitDate: Date().addingTimeInterval(-258000),
                    pullRequest: PullRequest(
                        number: 7760, title: "Embed logging",
                        url: "https://github.com/getsentry/seer/pull/7760",
                        state: .merged, isDraft: false,
                        headRefName: "seer/embed-logging", baseRefName: "main"
                    )
                ),
            ],
            lastFetch: Date().addingTimeInterval(-900)
        )

        let sentryRoot = "\(home)/code/sentry"
        let sentry = Repository(
            root: sentryRoot,
            remote: RemoteRepo(host: "github.com", owner: "getsentry", name: "sentry"),
            defaultBranch: "master",
            worktrees: [
                Worktree(
                    path: sentryRoot, repoRoot: sentryRoot, branch: "master",
                    head: "368131dfabb2c3d4e5f60718293a4b5c6d7e8f90",
                    isMain: true, sync: .behind(12), baseBranch: "master"
                ),
                Worktree(
                    path: "\(sentryRoot)/.claude/worktrees/open-tickets",
                    repoRoot: sentryRoot, branch: "ryan953/open-tickets-projects",
                    head: "482061b5282a3b4c5d6e7f8091a2b3c4d5e6f708",
                    isMain: false, upstream: "origin/ryan953/open-tickets-projects",
                    sync: .diverged(ahead: 1, behind: 84), baseBranch: "master",
                    uniqueCommits: [
                        commit("feat(inbox): add the header docs tooltip", 4320, sha: "482061b")
                    ],
                    dirtyFileCount: 7,
                    lastCommitDate: Date().addingTimeInterval(-259200)
                ),
            ],
            lastFetch: Date().addingTimeInterval(-86400 * 3),
            warning: nil
        )

        return [seer, sentry]
    }

    @MainActor
    static func store(selection: Worktree.ID? = nil) -> WorktreeStore {
        useTemporaryPreferences()
        return WorktreeStore(repositories: repositories(), selection: selection)
    }

    /// The worktree that has commits nobody else has — the case the app exists for.
    static var localOnlyID: Worktree.ID {
        "\(home)/code/seer/.claude/worktrees/autofix-trigger"
    }

    static var publishedID: Worktree.ID {
        "\(home)/code/seer/.claude/worktrees/codegen"
    }
}

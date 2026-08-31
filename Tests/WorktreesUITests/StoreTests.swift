import Foundation
import Testing
import WorktreeKit

@testable import WorktreesUI

@MainActor
@Suite("Filtering and search")
struct StoreTests {
    @Test("Counts the worktrees whose work is only on this machine")
    func countsAtRisk() {
        let store = Fixtures.store()
        // The local-only branch, and the one with a commit it has not pushed.
        #expect(store.atRiskCount == 3)
    }

    @Test("“Only here” keeps just the work that is not on GitHub")
    func filtersToUnpublished() {
        let store = Fixtures.store()
        store.filter = .unpublished
        let names = store.visibleRepositories
            .flatMap(\.worktrees)
            .filter { !$0.isMain }
            .map(\.name)
        #expect(names.contains("seer/autofix-trigger-recall"))
        #expect(names.contains("pr7795-embed"))
        #expect(names.contains("ryan953/open-tickets-projects"))
        #expect(!names.contains("seer/codegen-cards"))
    }

    @Test("The working copy is never filtered out of its own group")
    func alwaysShowsTheWorkingCopy() {
        let store = Fixtures.store()
        store.filter = .unpublished
        for repository in store.visibleRepositories {
            #expect(repository.worktrees.contains { $0.isMain })
        }
    }

    @Test("Search reaches branches, paths and pull requests")
    func searches() {
        let store = Fixtures.store()

        store.search = "codegen"
        #expect(store.visibleRepositories.flatMap(\.worktrees).contains { $0.name == "seer/codegen-cards" })

        store.search = "7795"
        let byNumber = store.visibleRepositories.flatMap(\.worktrees)
        #expect(byNumber.contains { $0.pullRequest?.number == 7795 })

        store.search = "open-tickets"
        #expect(store.visibleRepositories.count == 1)

        store.search = "nothing matches this"
        #expect(store.visibleRepositories.isEmpty)
    }

    @Test("Hiding worktrees with nothing of their own leaves the rest alone")
    func hidesMatchingBase() {
        var repositories = Fixtures.repositories()
        repositories[0].worktrees.append(
            Worktree(
                path: "\(Fixtures.home)/code/seer/.claude/worktrees/idle",
                repoRoot: "\(Fixtures.home)/code/seer", branch: "idle",
                head: "aaa", isMain: false, sync: .upToDate, baseBranch: "main"
            )
        )
        Fixtures.useTemporaryPreferences()
        let store = WorktreeStore(repositories: repositories)
        #expect(store.visibleRepositories.flatMap(\.worktrees).contains { $0.name == "idle" })

        store.hideMatchingBase = true
        #expect(!store.visibleRepositories.flatMap(\.worktrees).contains { $0.name == "idle" })
    }

    @Test("Grouping by local changes separates the busy repositories from the quiet ones")
    func groupsByActivity() {
        Fixtures.useTemporaryPreferences()
        let store = WorktreeStore(repositories: Fixtures.repositories() + [Fixtures.soloRepository()])
        store.grouping = .activity

        let titles = store.repositoryGroups.map(\.title)
        #expect(titles == ["Local changes", "Nothing local"])
        let quiet = store.repositoryGroups.last?.repositories.map(\.name)
        #expect(quiet == ["dotfiles"])
        let busy = store.repositoryGroups.first?.repositories.map(\.name).sorted()
        #expect(busy == ["seer", "sentry"])
    }

    @Test("Grouping by pull requests follows any worktree in the repository")
    func groupsByPullRequests() {
        Fixtures.useTemporaryPreferences()
        let store = WorktreeStore(repositories: Fixtures.repositories() + [Fixtures.soloRepository()])
        store.grouping = .pullRequests

        let withPRs = store.repositoryGroups.first { $0.title == "With pull requests" }
        #expect(withPRs?.repositories.map(\.name) == ["seer"])
        let without = store.repositoryGroups.first { $0.title == "No pull requests" }
        #expect(without?.repositories.map(\.name).sorted() == ["dotfiles", "sentry"])
    }

    @Test("Grouping by size finds the repositories that are only a working copy")
    func groupsBySize() {
        Fixtures.useTemporaryPreferences()
        let store = WorktreeStore(repositories: Fixtures.repositories() + [Fixtures.soloRepository()])
        store.grouping = .size

        let solo = store.repositoryGroups.first { $0.title == "Just the working copy" }
        #expect(solo?.repositories.map(\.name) == ["dotfiles"])
        let rest = store.repositoryGroups.first { $0.title == "With worktrees" }
        #expect(rest?.repositories.map(\.name).sorted() == ["seer", "sentry"])
    }

    @Test("A group with nothing in it is not shown at all")
    func dropsEmptyGroups() {
        Fixtures.useTemporaryPreferences()
        let store = WorktreeStore(repositories: [Fixtures.soloRepository()])
        store.grouping = .size
        #expect(store.repositoryGroups.map(\.title) == ["Just the working copy"])
    }

    @Test("Grouping by repository leaves one section holding everything")
    func groupsByRepository() {
        Fixtures.useTemporaryPreferences()
        let store = WorktreeStore(repositories: Fixtures.repositories())
        store.grouping = .repository
        #expect(store.repositoryGroups.count == 1)
        #expect(store.repositoryGroups[0].repositories.count == 2)
    }

    @Test("Every worktree knows the working copy it belongs to")
    func resolvesRepositories() {
        let store = Fixtures.store()
        for worktree in store.allWorktrees {
            let repository = store.repository(for: worktree)
            #expect(repository?.root == worktree.repoRoot)
        }
    }
}

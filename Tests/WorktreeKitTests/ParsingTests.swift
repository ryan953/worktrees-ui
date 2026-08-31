import Foundation
import Testing

@testable import WorktreeKit

@Suite("Worktree porcelain")
struct WorktreePorcelainTests {
    @Test("Reads the main copy and its linked worktrees")
    func parsesRecords() {
        let text = """
            worktree /Users/me/code/app
            HEAD 47f04af9485976084e74d92c6a4649818c07ad76
            branch refs/heads/main

            worktree /Users/me/code/app/.claude/worktrees/feature
            HEAD 7d7a18478f17862dde96e0d521b47ffc904fd5a9
            branch refs/heads/team/feature-with-slashes

            worktree /Users/me/code/app/.claude/worktrees/spike
            HEAD df868109573ec0d99a331e86f88c3e040ca550dc
            detached

            """
        let entries = WorktreePorcelain.parse(text)
        #expect(entries.count == 3)
        // git documents the main working copy as the first record, which is what makes
        // "the working copy for this repo" knowable at all.
        #expect(entries[0].path == "/Users/me/code/app")
        #expect(entries[0].branch == "main")
        #expect(entries[1].branch == "team/feature-with-slashes")
        #expect(entries[2].branch == nil)
        #expect(entries[2].isDetached)
    }

    @Test("Keeps the flags git adds after a path")
    func parsesFlags() {
        let text = """
            worktree /repo
            HEAD abc123
            branch refs/heads/main
            bare

            worktree /repo/wt
            HEAD def456
            branch refs/heads/wip
            locked because I am still using it
            prunable gitdir file points to non-existent location

            """
        let entries = WorktreePorcelain.parse(text)
        #expect(entries[0].isBare)
        #expect(entries[1].isLocked)
        #expect(entries[1].isPrunable)
    }

    @Test("Survives a trailing record with no blank line")
    func parsesUnterminated() {
        let entries = WorktreePorcelain.parse("worktree /repo\nHEAD abc\nbranch refs/heads/main")
        #expect(entries.count == 1)
        #expect(entries[0].branch == "main")
    }
}

@Suite("Remote URLs")
struct RemoteRepoTests {
    @Test(
        "Parses the spellings git remotes come in",
        arguments: [
            "git@github.com:ryan953/worktrees-ui.git",
            "https://github.com/ryan953/worktrees-ui.git",
            "https://github.com/ryan953/worktrees-ui",
            "ssh://git@github.com/ryan953/worktrees-ui.git",
            "ssh://git@github.com:22/ryan953/worktrees-ui.git",
        ]
    )
    func parses(_ url: String) {
        let remote = RemoteRepo.parse(url)
        #expect(remote?.slug == "ryan953/worktrees-ui")
        #expect(remote?.host == "github.com")
        #expect(remote?.isGitHub == true)
    }

    @Test("Keeps a non-GitHub host instead of assuming github.com")
    func keepsHost() {
        let remote = RemoteRepo.parse("git@git.example.com:team/thing.git")
        #expect(remote?.host == "git.example.com")
        #expect(remote?.isGitHub == false)
    }

    @Test("Refuses what it cannot read rather than guessing")
    func rejectsGarbage() {
        #expect(RemoteRepo.parse("") == nil)
        #expect(RemoteRepo.parse("/srv/local/repo.git") == nil)
        #expect(RemoteRepo.parse("github.com") == nil)
    }

    @Test("Builds links that keep slashes in branch names")
    func buildsLinks() {
        let remote = RemoteRepo(host: "github.com", owner: "ryan953", name: "worktrees-ui")
        #expect(
            remote.branchURL("team/feature")?.absoluteString
                == "https://github.com/ryan953/worktrees-ui/tree/team/feature"
        )
        #expect(
            remote.compareURL(base: "main", head: "team/feature")?.absoluteString
                == "https://github.com/ryan953/worktrees-ui/compare/main...team/feature"
        )
        #expect(
            remote.newPullRequestURL(base: "main", head: "wip")?.absoluteString
                == "https://github.com/ryan953/worktrees-ui/compare/main...wip?expand=1"
        )
    }

    @Test("Escapes a branch name that would otherwise break the URL")
    func escapesBranch() {
        let remote = RemoteRepo(host: "github.com", owner: "o", name: "n")
        let url = remote.branchURL("fix/a b#c")?.absoluteString
        #expect(url == "https://github.com/o/n/tree/fix/a%20b%23c")
    }
}

@Suite("Commit log")
struct GitLogTests {
    @Test("Reads the separated format")
    func parses() {
        let text =
            "abc123\u{1f}abc123f\u{1f}feat: add the thing\u{1f}Sam Rivers\u{1f}1756600000\u{1e}"
            + "def456\u{1f}def456a\u{1f}fix: a subject with \u{2014} punctuation\u{1f}Ada\u{1f}1756500000\u{1e}"
        let commits = GitLog.parse(text)
        #expect(commits.count == 2)
        #expect(commits[0].subject == "feat: add the thing")
        #expect(commits[0].author == "Sam Rivers")
        #expect(commits[1].subject == "fix: a subject with — punctuation")
        #expect(commits[0].date > commits[1].date)
    }

    @Test("Returns nothing for empty output rather than a broken commit")
    func parsesEmpty() {
        #expect(GitLog.parse("").isEmpty)
        #expect(GitLog.parse("\n").isEmpty)
    }
}

@Suite("Status")
struct WorktreeStatusTests {
    private func worktree(
        branch: String? = "wip", sync: SyncState, commits: Int
    ) -> Worktree {
        let list = (0..<commits).map {
            Commit(
                sha: "sha\($0)", shortSHA: "sha\($0)", subject: "s\($0)",
                author: "a", date: Date()
            )
        }
        return Worktree(
            path: "/repo/wt", repoRoot: "/repo", branch: branch, head: "sha0",
            isMain: false, sync: sync, uniqueCommits: list
        )
    }

    @Test("A branch with nothing of its own matches the base")
    func matchesBase() {
        #expect(worktree(sync: .upToDate, commits: 0).status == .matchesBase)
        // Even with no remote at all: there is nothing here to lose.
        #expect(worktree(sync: .noRemoteBranch, commits: 0).status == .matchesBase)
    }

    @Test("Commits that exist nowhere else are local only")
    func localOnly() {
        let wt = worktree(sync: .noRemoteBranch, commits: 3)
        #expect(wt.status == .localOnly)
        #expect(wt.status.isAtRisk)
    }

    @Test("A remote branch missing some commits is unpushed")
    func unpushed() {
        #expect(worktree(sync: .ahead(2), commits: 4).status == .unpushed)
        #expect(worktree(sync: .diverged(ahead: 1, behind: 6), commits: 4).status == .unpushed)
    }

    @Test("Everything on the remote counts as published")
    func published() {
        #expect(worktree(sync: .upToDate, commits: 4).status == .published)
        // Behind still means the remote has every commit this copy has.
        #expect(worktree(sync: .behind(9), commits: 4).status == .published)
        #expect(worktree(sync: .upToDate, commits: 4).status.isAtRisk == false)
    }

    @Test("A deleted remote branch is called out on its own")
    func remoteDeleted() {
        #expect(worktree(sync: .remoteDeleted, commits: 6).status == .remoteDeleted)
    }

    @Test("No branch means detached, whatever the counts say")
    func detached() {
        #expect(worktree(branch: nil, sync: .noRemoteBranch, commits: 2).status == .detached)
    }

    @Test("Ahead and behind counts read off the sync state")
    func counts() {
        #expect(SyncState.diverged(ahead: 3, behind: 7).aheadCount == 3)
        #expect(SyncState.diverged(ahead: 3, behind: 7).behindCount == 7)
        #expect(SyncState.ahead(2).isFullyPushed == false)
        #expect(SyncState.behind(2).isFullyPushed)
    }
}

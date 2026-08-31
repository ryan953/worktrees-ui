import Foundation

/// Looks up pull requests through the `gh` CLI.
///
/// `gh` is used rather than the REST API directly because it already holds the token,
/// handles enterprise hosts, and means the app never stores a credential of its own.
public struct GitHubClient: Sendable {
    public var executable: String?
    public var environment: [String: String]

    public var isAvailable: Bool { executable != nil }

    public init(executable: String?, environment: [String: String]) {
        self.executable = executable
        self.environment = environment
    }

    private struct RawPullRequest: Decodable {
        var number: Int
        var title: String
        var url: String
        var state: String
        var isDraft: Bool
        var headRefName: String
        var baseRefName: String
    }

    /// Every recent pull request in a repository, keyed by the branch it came from.
    ///
    /// One call per repository rather than one per worktree: a repository with a dozen
    /// worktrees would otherwise mean a dozen round trips, and the answer to all of
    /// them is in this single response.
    public func pullRequestsByBranch(
        slug: String,
        in directory: String,
        limit: Int = 200
    ) async throws -> [String: PullRequest] {
        guard let executable else { return [:] }
        let arguments = [
            "pr", "list",
            "--repo", slug,
            "--state", "all",
            "--limit", String(limit),
            "--json", "number,title,url,state,isDraft,headRefName,baseRefName",
        ]
        let result = try await ProcessRunner.run(
            executable: executable,
            arguments: arguments,
            workingDirectory: directory,
            environment: environment,
            timeout: 60
        )
        guard result.succeeded else {
            throw ProcessError.failed(
                command: "gh pr list --repo \(slug)",
                status: result.status,
                message: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        let raw = try JSONDecoder().decode([RawPullRequest].self, from: Data(result.stdout.utf8))

        var byBranch: [String: PullRequest] = [:]
        for item in raw {
            let pr = PullRequest(
                number: item.number,
                title: item.title,
                url: item.url,
                state: PullRequest.State(rawValue: item.state.uppercased()) ?? .closed,
                isDraft: item.isDraft,
                headRefName: item.headRefName,
                baseRefName: item.baseRefName
            )
            // A branch can carry several pull requests over its life — a closed one and
            // then a reopened one. Prefer whichever is most alive, then the newest.
            if let existing = byBranch[item.headRefName] {
                if rank(pr.state) > rank(existing.state)
                    || (rank(pr.state) == rank(existing.state) && pr.number > existing.number)
                {
                    byBranch[item.headRefName] = pr
                }
            } else {
                byBranch[item.headRefName] = pr
            }
        }
        return byBranch
    }

    private func rank(_ state: PullRequest.State) -> Int {
        switch state {
        case .open: 2
        case .merged: 1
        case .closed: 0
        }
    }
}

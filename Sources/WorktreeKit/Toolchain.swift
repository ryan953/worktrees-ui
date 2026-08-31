import Foundation

/// The resolved tools and environment both binaries run git and gh with.
public struct Toolchain: Sendable {
    public var path: String
    public var environment: [String: String]
    public var gitExecutable: String
    public var ghExecutable: String?

    public var git: GitClient {
        GitClient(executable: gitExecutable, environment: environment)
    }

    public var github: GitHubClient {
        GitHubClient(executable: ghExecutable, environment: environment)
    }

    public enum Failure: LocalizedError {
        case gitNotFound(path: String)

        public var errorDescription: String? {
            switch self {
            case let .gitNotFound(path):
                "Could not find git on PATH (\(path)). Set its path in Settings."
            }
        }
    }

    /// Work out the PATH a terminal would have, find the tools on it, and make sure
    /// `gh` has a token it can use.
    public static func resolve(
        gitOverride: String? = nil,
        ghOverride: String? = nil
    ) async throws -> Toolchain {
        let path = await ShellEnvironment.loginPath()
        guard
            let gitExecutable = ExecutableLocator.resolve(
                override: gitOverride, named: "git", path: path)
        else {
            throw Failure.gitNotFound(path: path)
        }
        let ghExecutable = ExecutableLocator.resolve(override: ghOverride, named: "gh", path: path)

        var environment = ShellEnvironment.environment(path: path)
        if let ghExecutable {
            await addGitHubToken(to: &environment, gh: ghExecutable)
        }
        return Toolchain(
            path: path,
            environment: environment,
            gitExecutable: gitExecutable,
            ghExecutable: ghExecutable
        )
    }

    /// Put an explicit token in the environment when there is not one already.
    ///
    /// Run from launchd there is no terminal session behind `gh`, and its keyring-backed
    /// login is not reliably readable the way it is from a shell. Asking `gh` for the
    /// token once, while it can still answer, and passing it on explicitly is what keeps
    /// the scheduled run from silently finding no pull requests — which would make every
    /// worktree look unremovable rather than fail loudly.
    static func addGitHubToken(to environment: inout [String: String], gh: String) async {
        if let existing = environment["GH_TOKEN"] ?? environment["GITHUB_TOKEN"], !existing.isEmpty {
            return
        }
        let result = try? await ProcessRunner.run(
            executable: gh,
            arguments: ["auth", "token"],
            workingDirectory: nil,
            environment: environment,
            timeout: 20
        )
        guard let token = result?.trimmedOutput, !token.isEmpty, result?.succeeded == true else {
            return
        }
        environment["GH_TOKEN"] = token
        environment["GITHUB_TOKEN"] = token
    }

    public func scanner() -> WorktreeScanner {
        WorktreeScanner(git: git, github: github)
    }
}

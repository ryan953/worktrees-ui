import Foundation

/// How to bring a worktree's branch into the main working copy.
///
/// Two modes exist because git will not check out a branch that is already checked out
/// in a worktree, and the two honest ways around that differ in what they cost. There
/// is no third option that leaves both directories on the branch.
public enum PullMode: String, Sendable, CaseIterable, Identifiable {
    /// Free the branch by detaching the worktree, then check it out in the main copy.
    /// Commits made afterwards land on the branch.
    case moveBranch
    /// Check out the same commit in the main copy with a detached HEAD, leaving the
    /// worktree exactly as it was.
    case copyCommit

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .moveBranch: "Move the branch here"
        case .copyCommit: "Check out the commit here"
        }
    }

    public var explanation: String {
        switch self {
        case .moveBranch:
            "The worktree is detached so the branch is free, then the working copy "
                + "checks it out. Commits you make go on the branch. The worktree keeps its "
                + "files but is no longer on the branch."
        case .copyCommit:
            "The working copy checks out the same commit with a detached HEAD. The "
                + "worktree is untouched. Good for reading and running the code; commits "
                + "made here are not on any branch."
        }
    }
}

/// What a pull would do, and what stands in its way.
public struct PullPlan: Sendable {
    public var mode: PullMode
    public var branch: String?
    public var head: String
    public var workingCopy: String
    public var worktreePath: String
    /// The ref the working copy is on now, so the summary can say how to get back.
    public var currentRef: String?
    public var steps: [String]
    /// Reasons this cannot run. Non-empty means the button is disabled.
    public var blockers: [String]
    /// Things worth knowing that do not stop it.
    public var warnings: [String]

    public var canProceed: Bool { blockers.isEmpty }

    public init(
        mode: PullMode, branch: String?, head: String, workingCopy: String,
        worktreePath: String, currentRef: String?, steps: [String],
        blockers: [String], warnings: [String]
    ) {
        self.mode = mode
        self.branch = branch
        self.head = head
        self.workingCopy = workingCopy
        self.worktreePath = worktreePath
        self.currentRef = currentRef
        self.steps = steps
        self.blockers = blockers
        self.warnings = warnings
    }
}

public struct WorkingCopyPuller: Sendable {
    public var git: GitClient

    public init(git: GitClient) {
        self.git = git
    }

    public func plan(for worktree: Worktree, mode: PullMode) async -> PullPlan {
        let workingCopy = worktree.repoRoot
        var blockers: [String] = []
        var warnings: [String] = []
        var steps: [String] = []

        let currentRef = await currentRefName(in: workingCopy)
        // The repository's other worktrees are commonly nested inside the working copy.
        // Counting them as uncommitted changes would block every pull, for a layout that
        // is the normal one.
        let nested = await git.worktreePaths(in: workingCopy)
        let workingCopyDirty = await git.dirtyCount(in: workingCopy, excluding: nested)
        let worktreeExists = FileManager.default.fileExists(atPath: worktree.path)

        if worktree.isMain {
            blockers.append("This is the working copy.")
        }
        if !FileManager.default.fileExists(atPath: workingCopy) {
            blockers.append("The working copy directory is missing: \(workingCopy)")
        }
        // Checking out over uncommitted work either fails outright or drags the changes
        // onto the new branch. Neither is something to do behind a single button.
        if workingCopyDirty > 0 {
            blockers.append(
                "The working copy has \(workingCopyDirty) uncommitted "
                    + (workingCopyDirty == 1 ? "change" : "changes") + ". Commit or stash first."
            )
        }

        switch mode {
        case .moveBranch:
            guard let branch = worktree.branch else {
                blockers.append("This worktree has a detached HEAD, so there is no branch to move.")
                break
            }
            if currentRef == branch {
                blockers.append("The working copy is already on \(branch).")
            }
            if worktreeExists {
                steps.append("git -C \(worktree.path) checkout --detach")
                if worktree.isDirty {
                    warnings.append(
                        "\(worktree.displayName) has \(worktree.dirtyFileCount) uncommitted "
                            + "changes. They stay in that directory, on a detached HEAD."
                    )
                }
            } else {
                warnings.append("The worktree directory is gone, so only the checkout runs.")
            }
            steps.append("git -C \(workingCopy) checkout \(branch)")

        case .copyCommit:
            if worktree.head.isEmpty {
                blockers.append("This worktree has no commit to check out.")
            }
            steps.append("git -C \(workingCopy) checkout --detach \(worktree.head)")
        }

        if let currentRef, !currentRef.isEmpty, blockers.isEmpty {
            warnings.append("The working copy leaves \(currentRef); nothing on it is lost.")
        }

        return PullPlan(
            mode: mode,
            branch: worktree.branch,
            head: worktree.head,
            workingCopy: workingCopy,
            worktreePath: worktree.path,
            currentRef: currentRef,
            steps: steps,
            blockers: blockers,
            warnings: warnings
        )
    }

    /// Carry out a plan. Returns a one-line summary for the UI.
    ///
    /// The detach and the checkout are two commands with a window between them, so a
    /// failed checkout puts the worktree back on its branch. Leaving someone with a
    /// detached worktree *and* no branch in the working copy would be worse than not
    /// having pressed the button.
    @discardableResult
    public func perform(_ plan: PullPlan, worktree: Worktree) async throws -> String {
        guard plan.canProceed else {
            throw ProcessError.failed(
                command: "pull into working copy",
                status: 1,
                message: plan.blockers.joined(separator: " ")
            )
        }

        switch plan.mode {
        case .copyCommit:
            _ = try await git.output(
                ["checkout", "--detach", worktree.head],
                in: plan.workingCopy,
                timeout: 120
            )
            return "\(plan.workingCopy) is on \(String(worktree.head.prefix(8))), detached."

        case .moveBranch:
            guard let branch = worktree.branch else {
                throw ProcessError.failed(
                    command: "checkout",
                    status: 1,
                    message: "No branch to move."
                )
            }
            let detached = FileManager.default.fileExists(atPath: worktree.path)
            if detached {
                _ = try await git.output(["checkout", "--detach"], in: worktree.path, timeout: 120)
            }
            do {
                _ = try await git.output(["checkout", branch], in: plan.workingCopy, timeout: 120)
            } catch {
                if detached {
                    // Best effort: if this also fails there is nothing further to try, and
                    // the original error is the one worth reporting.
                    _ = await git.optional(["checkout", branch], in: worktree.path, timeout: 120)
                }
                throw error
            }
            return "\(plan.workingCopy) is on \(branch)."
        }
    }

    /// The branch name, or a short sha when HEAD is detached.
    func currentRefName(in directory: String) async -> String? {
        if let branch = await git.optional(["symbolic-ref", "--quiet", "--short", "HEAD"], in: directory),
            !branch.isEmpty
        {
            return branch
        }
        guard let sha = await git.optional(["rev-parse", "--short", "HEAD"], in: directory) else {
            return nil
        }
        return sha.isEmpty ? nil : "a detached \(sha)"
    }
}

import Foundation
import WorktreeKit

// The tool the scheduled job runs. It shares WorktreeKit, and its settings suite, with
// the app, so a cleanup at 9am applies exactly the policy shown in Settings.
//
// Dry run unless --apply is given: the destructive direction should be the one that has
// to be asked for, whether a person or launchd is asking.

struct Options {
    var apply = false
    var json = false
    var roots: [String]?
    var minimumAgeDays: Int?
    var includeOpen: Bool?
    var keepBranch = false
    var quiet = false
}

func usage() -> String {
    """
    worktrees-cleanup — remove worktrees whose commits are safely on GitHub.

    USAGE
      worktrees-cleanup [--apply] [options]

    By default it reports what it would do and changes nothing.

    OPTIONS
      --apply               Actually remove the worktrees.
      --json                Emit the report as JSON.
      --roots a:b           Directories to scan (default: the app's setting).
      --min-age-days N      Only worktrees left alone this long (default: setting).
      --include-open        Also remove worktrees whose pull request is still open.
      --keep-branch         Leave the local branch behind.
      --quiet               Only print removals and problems.
      -h, --help            This text.

    A worktree is only removed when it has no uncommitted changes, no process is
    working in it, it has a pull request, and its commits are provably readable
    back from GitHub. Every removal is logged with the command that restores it.
    """
}

func parse(_ arguments: [String]) -> Options? {
    var options = Options()
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        index += 1
        func next() -> String? {
            guard index < arguments.count else { return nil }
            defer { index += 1 }
            return arguments[index]
        }
        switch argument {
        case "--apply": options.apply = true
        case "--dry-run": options.apply = false
        case "--json": options.json = true
        case "--keep-branch": options.keepBranch = true
        case "--include-open": options.includeOpen = true
        case "--quiet": options.quiet = true
        case "--roots":
            guard let value = next() else { return nil }
            options.roots = value.split(separator: ":").map(String.init)
        case "--min-age-days":
            guard let value = next(), let number = Int(value) else { return nil }
            options.minimumAgeDays = number
        case "-h", "--help":
            print(usage())
            exit(0)
        default:
            FileHandle.standardError.write(Data("unknown argument: \(argument)\n".utf8))
            return nil
        }
    }
    return options
}

func describe(_ report: CleanupReport, applied: Bool, quiet: Bool) -> String {
    var lines: [String] = []
    let acted = applied ? report.removed : report.wouldRemove
    lines.append(applied ? "== Removed ==" : "== Would remove ==")
    if acted.isEmpty {
        lines.append("  (nothing eligible)")
    }
    for outcome in acted {
        let branch = outcome.branch ?? "(detached)"
        lines.append("  \(outcome.repositoryName)/\(branch)")
        lines.append("    \(Format.tildePath(outcome.path))")
        if let grounds = outcome.grounds {
            lines.append("    \(grounds.summary)")
        }
        if let restore = outcome.restoreCommand {
            lines.append("    restore: git -C \(outcome.repositoryRoot) \(restore)")
        }
    }

    if !report.failures.isEmpty {
        lines.append("")
        lines.append("== Failed ==")
        for outcome in report.failures {
            if case let .failed(message) = outcome.result {
                lines.append("  \(Format.tildePath(outcome.path)): \(message)")
            }
        }
    }

    if !quiet {
        lines.append("")
        lines.append("== Kept ==")
        if report.kept.isEmpty { lines.append("  (none)") }
        for outcome in report.kept {
            if case let .kept(reason) = outcome.result {
                lines.append("  \(Format.tildePath(outcome.path)): \(reason.summary)")
            }
        }
    }

    lines.append("")
    lines.append(
        "\(applied ? "Removed" : "Would remove"): \(acted.count)   "
            + "Kept: \(report.kept.count)   Failed: \(report.failures.count)")
    return lines.joined(separator: "\n")
}

enum Format {
    static func tildePath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

func emitJSON(_ report: CleanupReport, applied: Bool) {
    var items: [[String: Any]] = []
    for outcome in report.outcomes {
        var item: [String: Any] = [
            "path": outcome.path,
            "repository": outcome.repositoryName,
        ]
        if let branch = outcome.branch { item["branch"] = branch }
        switch outcome.result {
        case .removed: item["result"] = "removed"
        case .wouldRemove: item["result"] = "would-remove"
        case let .kept(reason):
            item["result"] = "kept"
            item["reason"] = reason.summary
        case let .failed(message):
            item["result"] = "failed"
            item["error"] = message
        }
        if let grounds = outcome.grounds {
            item["pullRequest"] = grounds.pullRequest.number
            item["recoverableFrom"] = grounds.recovery.describedSource
            item["idleDays"] = grounds.idleDays
        }
        if let restore = outcome.restoreCommand { item["restore"] = restore }
        items.append(item)
    }
    let payload: [String: Any] = ["applied": applied, "worktrees": items]
    guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
    else { return }
    print(String(decoding: data, as: UTF8.self))
}

@main
struct Main {
    static func main() async {
        guard let options = parse(Array(CommandLine.arguments.dropFirst())) else {
            FileHandle.standardError.write(Data((usage() + "\n").utf8))
            exit(2)
        }

        let log = CleanupLog.default
        // Only a run that changes something needs to exclude other runs; a dry run can
        // safely read alongside one.
        var lock: RunLock.Handle?
        if options.apply {
            lock = RunLock.default.acquire()
            guard lock != nil else {
                FileHandle.standardError.write(
                    Data("another cleanup run is in progress; exiting\n".utf8))
                exit(0)
            }
        }
        // `exit()` runs no `defer`, so every path out goes through here instead.
        func finish(_ code: Int32) -> Never {
            lock?.release()
            exit(code)
        }

        let toolchain: Toolchain
        do {
            toolchain = try await Toolchain.resolve(
                gitOverride: Preferences.gitPath.isEmpty ? nil : Preferences.gitPath,
                ghOverride: Preferences.ghPath.isEmpty ? nil : Preferences.ghPath
            )
        } catch {
            let message = "cleanup could not start: \(error.localizedDescription)"
            FileHandle.standardError.write(Data((message + "\n").utf8))
            log.note("ERROR\t\(message)")
            finish(1)
        }

        if toolchain.ghExecutable == nil {
            // Without gh there are no pull requests, and no pull request means nothing
            // is ever removable. Say so rather than reporting a quiet "nothing to do".
            let message =
                "gh was not found, so no pull requests can be read and nothing is removable."
            FileHandle.standardError.write(Data((message + "\n").utf8))
            log.note("ERROR\t\(message)")
            finish(1)
        }

        var policy = Preferences.policy(dryRun: !options.apply)
        if let days = options.minimumAgeDays { policy.minimumAgeDays = days }
        if let includeOpen = options.includeOpen { policy.includesOpenPullRequests = includeOpen }
        if options.keepBranch { policy.deletesBranch = false }

        // Always fetch: whether a commit is on GitHub is read from remote-tracking refs,
        // and acting on a week-old view of the remote is how a scheduled job would
        // delete something that only looked published.
        let repositories = await toolchain.scanner().scan(
            options: ScanOptions(
                roots: options.roots ?? Preferences.roots,
                maxDepth: Preferences.maxDepth,
                lookUpPullRequests: true,
                fetchFirst: true
            )
        )

        let planner = CleanupPlanner(git: toolchain.git)
        let candidates = await planner.plan(repositories: repositories, policy: policy)
        let report = await CleanupRunner(git: toolchain.git, log: log)
            .run(candidates, policy: policy)

        if options.json {
            emitJSON(report, applied: options.apply)
        } else {
            print(describe(report, applied: options.apply, quiet: options.quiet))
        }
        finish(report.failures.isEmpty ? 0 : 1)
    }
}

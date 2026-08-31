import Foundation

/// Settings, shared by the app and the scheduled cleanup job.
///
/// Both binaries name the suite explicitly rather than using `UserDefaults.standard`:
/// standard defaults are keyed to the running executable's bundle identifier, and the
/// command line tool has none, so the scheduled job would silently read an empty set of
/// settings and clean up under defaults the user never chose.
public enum Preferences {
    public static let suiteName = "com.ryan953.worktrees-ui"

    /// Pointed at a volatile suite by the tests, so running them never writes into the
    /// settings of the installed app.
    ///
    /// A process may not open its own bundle identifier as a suite — macOS refuses and
    /// logs "does not make sense and will not work" — and the cleanup tool ships inside
    /// Worktrees.app, so it inherits that identifier and hits the same rule. In both
    /// binaries standard defaults already point at exactly this domain, so ask for the
    /// suite only when the running process is something else.
    nonisolated(unsafe) public static var store: UserDefaults = {
        if Bundle.main.bundleIdentifier == suiteName { return .standard }
        return UserDefaults(suiteName: suiteName) ?? .standard
    }()

    /// Directories to look for repositories in.
    public static var roots: [String] {
        get {
            let stored = store.stringArray(forKey: "roots") ?? []
            return stored.isEmpty ? ["~/code"] : stored
        }
        set { store.set(newValue, forKey: "roots") }
    }

    /// How far below each root to look. Two levels covers `~/code/repo` and the
    /// `~/code/org/repo` layout without walking a whole home directory.
    public static var maxDepth: Int {
        get { store.object(forKey: "maxDepth") as? Int ?? 2 }
        set { store.set(newValue, forKey: "maxDepth") }
    }

    public static var lookUpPullRequests: Bool {
        get { store.object(forKey: "lookUpPullRequests") as? Bool ?? true }
        set { store.set(newValue, forKey: "lookUpPullRequests") }
    }

    /// Fetch every remote as part of a scan. Off by default because it is the only
    /// part that touches the network.
    public static var fetchOnRefresh: Bool {
        get { store.object(forKey: "fetchOnRefresh") as? Bool ?? false }
        set { store.set(newValue, forKey: "fetchOnRefresh") }
    }

    /// Hide worktrees that have nothing of their own.
    public static var hideMatchingBase: Bool {
        get { store.object(forKey: "hideMatchingBase") as? Bool ?? false }
        set { store.set(newValue, forKey: "hideMatchingBase") }
    }

    /// How the sidebar splits repositories up.
    public static var grouping: String {
        get { store.string(forKey: "grouping") ?? "repository" }
        set { store.set(newValue, forKey: "grouping") }
    }

    public static var gitPath: String {
        get { store.string(forKey: "gitPath") ?? "" }
        set { store.set(newValue, forKey: "gitPath") }
    }

    public static var ghPath: String {
        get { store.string(forKey: "ghPath") ?? "" }
        set { store.set(newValue, forKey: "ghPath") }
    }

    public static var terminalApp: String {
        get { store.string(forKey: "terminalApp") ?? "Terminal" }
        set { store.set(newValue, forKey: "terminalApp") }
    }

    // MARK: - Cleanup

    /// How long a worktree must have been left alone before the scheduled job will
    /// touch it. Cleaning up by hand from the app ignores this.
    public static var cleanupMinimumAgeDays: Int {
        get { store.object(forKey: "cleanupMinimumAgeDays") as? Int ?? 14 }
        set { store.set(newValue, forKey: "cleanupMinimumAgeDays") }
    }

    /// Whether the scheduled job may remove a worktree whose pull request is still
    /// open. Off by default: an open pull request is usually work in progress, and a
    /// scheduled job should not clear the desk of something still being worked on.
    public static var cleanupIncludesOpenPullRequests: Bool {
        get { store.object(forKey: "cleanupIncludesOpenPullRequests") as? Bool ?? false }
        set { store.set(newValue, forKey: "cleanupIncludesOpenPullRequests") }
    }

    /// Delete the local branch as well as the worktree directory.
    public static var cleanupDeletesBranch: Bool {
        get { store.object(forKey: "cleanupDeletesBranch") as? Bool ?? true }
        set { store.set(newValue, forKey: "cleanupDeletesBranch") }
    }

    /// Hour of the day, local time, that the scheduled job runs.
    public static var cleanupHour: Int {
        get { store.object(forKey: "cleanupHour") as? Int ?? 9 }
        set { store.set(newValue, forKey: "cleanupHour") }
    }

    /// The policy to clean up under.
    ///
    /// `manual` is for the button in the app, and drops both the waiting period and the
    /// open-pull-request rule. Those two exist to keep an unattended job cautious;
    /// someone reading the list can see each worktree's state and choose, and hiding
    /// options from them would only send them to the command line.
    public static func policy(dryRun: Bool, manual: Bool = false) -> CleanupPolicy {
        CleanupPolicy(
            minimumAgeDays: manual ? 0 : cleanupMinimumAgeDays,
            includesOpenPullRequests: manual ? true : cleanupIncludesOpenPullRequests,
            deletesBranch: cleanupDeletesBranch,
            dryRun: dryRun
        )
    }
}

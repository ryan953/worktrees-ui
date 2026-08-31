import Foundation

/// Settings, kept in UserDefaults.
enum Preferences {
    /// Pointed at a volatile suite by the tests, so running them never writes into the
    /// settings of the installed app.
    nonisolated(unsafe) static var store = UserDefaults.standard

    /// Directories to look for repositories in.
    static var roots: [String] {
        get {
            let stored = store.stringArray(forKey: "roots") ?? []
            return stored.isEmpty ? ["~/code"] : stored
        }
        set { store.set(newValue, forKey: "roots") }
    }

    /// How far below each root to look. Two levels covers `~/code/repo` and the
    /// `~/code/org/repo` layout without walking a whole home directory.
    static var maxDepth: Int {
        get { store.object(forKey: "maxDepth") as? Int ?? 2 }
        set { store.set(newValue, forKey: "maxDepth") }
    }

    static var lookUpPullRequests: Bool {
        get { store.object(forKey: "lookUpPullRequests") as? Bool ?? true }
        set { store.set(newValue, forKey: "lookUpPullRequests") }
    }

    /// Fetch every remote as part of a scan. Off by default because it is the only
    /// part that touches the network.
    static var fetchOnRefresh: Bool {
        get { store.object(forKey: "fetchOnRefresh") as? Bool ?? false }
        set { store.set(newValue, forKey: "fetchOnRefresh") }
    }

    /// Hide worktrees that have nothing of their own.
    static var hideMatchingBase: Bool {
        get { store.object(forKey: "hideMatchingBase") as? Bool ?? false }
        set { store.set(newValue, forKey: "hideMatchingBase") }
    }

    static var gitPath: String {
        get { store.string(forKey: "gitPath") ?? "" }
        set { store.set(newValue, forKey: "gitPath") }
    }

    static var ghPath: String {
        get { store.string(forKey: "ghPath") ?? "" }
        set { store.set(newValue, forKey: "ghPath") }
    }

    static var terminalApp: String {
        get { store.string(forKey: "terminalApp") ?? "Terminal" }
        set { store.set(newValue, forKey: "terminalApp") }
    }
}

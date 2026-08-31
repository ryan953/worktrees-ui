import Foundation

/// Finds git repositories under a set of root directories.
public enum RepositoryFinder {
    /// Directories that never contain a checkout worth listing but do contain
    /// thousands of files, so descending into them costs seconds per scan.
    static let skipped: Set<String> = [
        "node_modules", ".build", ".venv", "venv", "vendor", "target",
        "Pods", "DerivedData", ".next", "dist", "build", ".tox", "__pycache__",
        ".cache", "Library", ".Trash",
    ]

    /// Directories directly under `roots` (to `maxDepth` levels) that hold a `.git`.
    ///
    /// Descent stops at a repository: worktrees nested inside one — the layout both
    /// `wt` and Claude Code use, under `.claude/worktrees` — are found by asking git
    /// itself, which is authoritative, rather than by recognising a directory name.
    public static func findRepositories(
        roots: [String],
        maxDepth: Int = 2,
        fileManager: FileManager = .default
    ) -> [String] {
        var found: [String] = []
        var seen = Set<String>()

        func walk(_ directory: String, depth: Int) {
            let standardized = (directory as NSString).standardizingPath
            guard seen.insert(standardized).inserted else { return }

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: standardized, isDirectory: &isDirectory),
                isDirectory.boolValue
            else { return }

            if fileManager.fileExists(atPath: (standardized as NSString).appendingPathComponent(".git")) {
                found.append(standardized)
                return
            }
            guard depth > 0 else { return }

            let contents = (try? fileManager.contentsOfDirectory(atPath: standardized)) ?? []
            for entry in contents.sorted() where !entry.hasPrefix(".") && !skipped.contains(entry) {
                walk((standardized as NSString).appendingPathComponent(entry), depth: depth - 1)
            }
        }

        for root in roots {
            walk((root as NSString).expandingTildeInPath, depth: maxDepth)
        }
        return found
    }
}

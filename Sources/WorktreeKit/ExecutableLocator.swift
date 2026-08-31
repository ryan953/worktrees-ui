import Foundation

/// Finds a command-line tool on a PATH.
public enum ExecutableLocator {
    public static func find(named name: String, in path: String) -> String? {
        let fm = FileManager.default
        for dir in path.split(separator: ":").map(String.init) where !dir.isEmpty {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Resolve the binary to use, honouring an explicit override from Settings.
    ///
    /// An override that is an absolute path is used as-is so a user can point at a
    /// specific install; a bare name is looked up on `path`.
    public static func resolve(override: String?, named name: String, path: String) -> String? {
        if let override, !override.trimmingCharacters(in: .whitespaces).isEmpty {
            let trimmed = override.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("/") {
                return FileManager.default.isExecutableFile(atPath: trimmed) ? trimmed : nil
            }
            return find(named: trimmed, in: path)
        }
        return find(named: name, in: path)
    }
}

import Foundation
import SwiftUI
import WorktreeKit

enum Format {
    /// A path with the home directory written as `~`, which is how these paths are
    /// read and typed.
    static func path(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// Held on the main actor because the formatter is not thread-safe and every
    /// caller is a view.
    @MainActor
    static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    @MainActor
    static func ago(_ date: Date?) -> String? {
        guard let date else { return nil }
        return relative.localizedString(for: date, relativeTo: Date())
    }

    static func count(_ number: Int, _ singular: String, _ plural: String) -> String {
        "\(number) \(number == 1 ? singular : plural)"
    }
}

extension WorktreeStatus {
    var color: Color {
        switch self {
        case .matchesBase: .secondary
        case .localOnly: .orange
        case .unpushed: .yellow
        case .published: .green
        case .remoteDeleted: .purple
        case .detached: .gray
        }
    }

    var symbol: String {
        switch self {
        case .matchesBase: "equal.circle"
        case .localOnly: "internaldrive"
        case .unpushed: "arrow.up.circle"
        case .published: "checkmark.icloud"
        case .remoteDeleted: "trash.circle"
        case .detached: "arrow.triangle.branch"
        }
    }

    /// The sentence the detail pane leads with.
    var explanation: String {
        switch self {
        case .matchesBase:
            "Nothing here that the base branch does not already have."
        case .localOnly:
            "These commits exist on this disk and nowhere else. Push them to keep them."
        case .unpushed:
            "The branch is on GitHub, but it is missing some of these commits."
        case .published:
            "Every commit here is on GitHub."
        case .remoteDeleted:
            "The branch was on GitHub and has been deleted — usually what a merged pull "
                + "request leaves behind."
        case .detached:
            "No branch is checked out here, so there is nothing to push."
        }
    }
}

extension SyncState {
    var summary: String {
        switch self {
        case .noRemoteBranch: "No branch on the remote"
        case .remoteDeleted: "Deleted on the remote"
        case .upToDate: "In step with the remote"
        case let .ahead(n): "\(Format.count(n, "commit", "commits")) not pushed"
        case let .behind(n): "\(Format.count(n, "commit", "commits")) behind"
        case let .diverged(ahead, behind):
            "\(ahead) not pushed, \(behind) behind"
        }
    }
}

extension PullRequest.State {
    var color: Color {
        switch self {
        case .open: .green
        case .merged: .purple
        case .closed: .red
        }
    }

    var symbol: String {
        switch self {
        case .open: "arrow.triangle.pull"
        case .merged: "arrow.triangle.merge"
        case .closed: "xmark.circle"
        }
    }
}

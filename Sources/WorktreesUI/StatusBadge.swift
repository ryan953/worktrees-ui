import SwiftUI
import WorktreeKit

struct StatusBadge: View {
    var status: WorktreeStatus

    var body: some View {
        Label(status.label, systemImage: status.symbol)
            .labelStyle(.titleAndIcon)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(status.color.opacity(0.15), in: Capsule())
            .foregroundStyle(status.color)
    }
}

struct PullRequestBadge: View {
    var pullRequest: PullRequest

    var body: some View {
        Label(pullRequest.label, systemImage: pullRequest.state.symbol)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(pullRequest.state.color.opacity(0.15), in: Capsule())
            .foregroundStyle(pullRequest.state.color)
    }
}

/// A path shown as something to read, copy and open — never as bare text.
///
/// The working copy directory is the one fact the window is asked to keep on screen at
/// all times, so it gets a control of its own rather than a label.
struct PathRow: View {
    var title: String
    var path: String
    var symbol: String = "folder"
    var emphasised = false

    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(emphasised ? Color.accentColor : .secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(Format.path(path))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(path)
            }
            Spacer(minLength: 8)
            Button {
                SystemActions.copy(path)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy the path")

            Button {
                SystemActions.reveal(path)
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")

            Button {
                SystemActions.openTerminal(at: path)
            } label: {
                Image(systemName: "terminal")
            }
            .buttonStyle(.borderless)
            .help("Open a terminal here")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            emphasised ? Color.accentColor.opacity(0.09) : Color.secondary.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 7)
        )
    }
}

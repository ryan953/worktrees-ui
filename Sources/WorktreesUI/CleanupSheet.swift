import SwiftUI
import WorktreeKit

/// Lists what can be removed, and for everything else, why it cannot.
///
/// The kept list is shown rather than hidden: the useful question when a worktree is
/// missing from the removable list is "why not?", and answering it here is what stops
/// anyone reaching for a force flag.
struct CleanupSheet: View {
    @Bindable var store: WorktreeStore

    @Environment(\.dismiss) private var dismiss
    @State private var isConfirming = false

    private var removable: [CleanupCandidate] {
        store.cleanupCandidates.filter(\.isRemovable)
    }
    private var kept: [CleanupCandidate] {
        store.cleanupCandidates.filter { !$0.isRemovable }
    }
    private var selectedCount: Int {
        removable.filter { store.cleanupSelection.contains($0.id) }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if store.isPlanningCleanup {
                ProgressView("Checking what is safe to remove…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
            Divider()
            footer
        }
        .frame(width: 640, height: 560)
        .task { await store.planCleanup() }
        .confirmationDialog(
            "Remove \(Format.count(selectedCount, "worktree", "worktrees"))?",
            isPresented: $isConfirming,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                Task {
                    await store.runCleanup()
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "The directories are deleted. Every commit in them is on GitHub, and the "
                    + "command to bring each one back is written to the cleanup log."
            )
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Clean up worktrees")
                .font(.headline)
            Text(
                "A worktree can go when it has no uncommitted changes, nothing is working "
                    + "in it, and its commits are on GitHub in a pull request you can pull "
                    + "from again."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
    }

    private var list: some View {
        List {
            Section {
                if removable.isEmpty {
                    Text("Nothing is safe to remove right now.")
                        .foregroundStyle(.secondary)
                }
                ForEach(removable) { candidate in
                    RemovableRow(
                        candidate: candidate,
                        isOn: Binding(
                            get: { store.cleanupSelection.contains(candidate.id) },
                            set: { on in
                                if on {
                                    store.cleanupSelection.insert(candidate.id)
                                } else {
                                    store.cleanupSelection.remove(candidate.id)
                                }
                            }
                        )
                    )
                }
            } header: {
                HStack {
                    Text("Safe to remove")
                    Spacer()
                    if !removable.isEmpty {
                        Button(selectedCount == removable.count ? "Deselect all" : "Select all") {
                            store.cleanupSelection =
                                selectedCount == removable.count
                                ? []
                                : Set(removable.map(\.id))
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                }
            }

            if !kept.isEmpty {
                Section("Staying, and why") {
                    ForEach(kept) { candidate in
                        KeptRow(candidate: candidate)
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private var footer: some View {
        HStack {
            if !removable.isEmpty {
                Text("\(selectedCount) of \(removable.count) selected")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Remove\(selectedCount > 0 ? " \(selectedCount)" : "")") {
                isConfirming = true
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selectedCount == 0)
        }
        .padding(16)
    }
}

private struct RemovableRow: View {
    var candidate: CleanupCandidate
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(candidate.repositoryName)
                        .font(.callout.weight(.semibold))
                    Text(candidate.worktree.name)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let pullRequest = candidate.grounds?.pullRequest {
                        PullRequestBadge(pullRequest: pullRequest)
                    }
                }
                if let grounds = candidate.grounds {
                    Text(
                        "Idle \(Format.count(grounds.idleDays, "day", "days")) · "
                            + "recoverable from \(grounds.recovery.describedSource)"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Text(Format.path(candidate.worktree.path))
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .toggleStyle(.checkbox)
    }
}

private struct KeptRow: View {
    var candidate: CleanupCandidate

    private var reason: String {
        if case let .keep(reason) = candidate.decision { return reason.summary }
        return ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(candidate.repositoryName)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(candidate.worktree.name)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text(reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 1)
    }
}

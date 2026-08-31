import SwiftUI
import WorktreeKit

struct SidebarView: View {
    @Bindable var store: WorktreeStore

    var body: some View {
        List(selection: $store.selection) {
            ForEach(store.visibleRepositories) { repository in
                Section {
                    ForEach(repository.worktrees) { worktree in
                        WorktreeRow(worktree: worktree)
                            .tag(worktree.id)
                    }
                } header: {
                    RepositoryHeader(repository: repository, store: store)
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if store.visibleRepositories.isEmpty && !store.isLoading {
                EmptyStateView(store: store)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            FilterBar(store: store)
        }
    }
}

private struct FilterBar: View {
    @Bindable var store: WorktreeStore

    var body: some View {
        VStack(spacing: 6) {
            Picker("Show", selection: $store.filter) {
                ForEach(WorktreeStore.Filter.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if store.atRiskCount > 0 {
                Label(
                    "\(Format.count(store.atRiskCount, "worktree has", "worktrees have")) work only on this machine",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

private struct RepositoryHeader: View {
    var repository: Repository
    var store: WorktreeStore

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(repository.name)
                    .font(.headline)
                Spacer()
                if let remote = repository.remote, let url = remote.homeURL {
                    Button {
                        SystemActions.open(url)
                    } label: {
                        Image(systemName: "arrow.up.forward.square")
                    }
                    .buttonStyle(.borderless)
                    .help("Open \(remote.slug) on GitHub")
                }
                Button {
                    Task { await store.fetch(repository) }
                } label: {
                    Image(systemName: "arrow.trianglehead.2.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Fetch \(repository.name)")
            }
            // The working copy is named on every group, so it is on screen no matter
            // which worktree is selected or how far the list is scrolled.
            Text(Format.path(repository.root))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
                .help("Working copy: \(repository.root)")
            if let warning = repository.warning {
                Text(warning)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
        .textCase(nil)
    }
}

private struct WorktreeRow: View {
    var worktree: Worktree

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: worktree.isMain ? "house.fill" : "arrow.triangle.branch")
                    .font(.caption)
                    .foregroundStyle(worktree.isMain ? Color.accentColor : .secondary)
                Text(worktree.name)
                    .font(.body.weight(worktree.isMain ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack(spacing: 5) {
                StatusBadge(status: worktree.status)
                if let pullRequest = worktree.pullRequest {
                    PullRequestBadge(pullRequest: pullRequest)
                }
                if worktree.isDirty {
                    Label("\(worktree.dirtyFileCount)", systemImage: "pencil.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("\(Format.count(worktree.dirtyFileCount, "uncommitted change", "uncommitted changes"))")
                }
                Spacer(minLength: 0)
                if worktree.hasUniqueCommits {
                    // The commit-node glyph, so a bare number is not left to mean
                    // whatever the reader assumes.
                    Label("\(worktree.uniqueCommits.count)", systemImage: "smallcircle.filled.circle")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help("\(Format.count(worktree.uniqueCommits.count, "commit", "commits")) not on \(worktree.baseBranch)")
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct EmptyStateView: View {
    var store: WorktreeStore

    var body: some View {
        ContentUnavailableView {
            Label("No worktrees", systemImage: "square.stack.3d.up.slash")
        } description: {
            if let toolError = store.toolError {
                Text(toolError)
            } else if !store.search.isEmpty {
                Text("Nothing matches “\(store.search)”.")
            } else if store.filter != .all || store.hideMatchingBase {
                Text("Nothing matches this filter.")
            } else {
                Text("No git repositories under \(Preferences.roots.map(Format.path).joined(separator: ", ")).")
            }
        } actions: {
            SettingsLink { Text("Settings…") }
        }
    }
}

import SwiftUI
import WorktreeKit

struct WorktreeDetailView: View {
    var worktree: Worktree
    var repository: Repository?
    var store: WorktreeStore

    @State private var isPulling = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                locations
                actions
                if let repository, let remote = repository.remote {
                    links(remote: remote)
                }
                details
                commits
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $isPulling) {
            PullSheet(worktree: worktree, store: store)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(worktree.name)
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)
                if worktree.isMain {
                    Text("working copy")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                }
            }
            HStack(spacing: 6) {
                StatusBadge(status: worktree.status)
                if let pullRequest = worktree.pullRequest {
                    PullRequestBadge(pullRequest: pullRequest)
                }
                if worktree.isLocked {
                    Label("Locked", systemImage: "lock").font(.caption).foregroundStyle(.secondary)
                }
                if worktree.isPrunable {
                    Label("Prunable", systemImage: "xmark.bin").font(.caption).foregroundStyle(.orange)
                }
            }
            Text(worktree.status.explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var locations: some View {
        VStack(spacing: 6) {
            PathRow(
                title: "Working copy for \(repository?.name ?? "this repository")",
                path: worktree.repoRoot,
                symbol: "house.fill",
                emphasised: true
            )
            if !worktree.isMain {
                PathRow(title: "This worktree", path: worktree.path, symbol: "arrow.triangle.branch")
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                isPulling = true
            } label: {
                Label("Pull into working copy", systemImage: "arrow.down.to.line")
            }
            .buttonStyle(.borderedProminent)
            .disabled(worktree.isMain)
            .help(
                worktree.isMain
                    ? "This is the working copy."
                    : "Check this branch out in \(Format.path(worktree.repoRoot))"
            )

            if let repository {
                Button {
                    Task { await store.fetch(repository) }
                } label: {
                    Label("Fetch", systemImage: "arrow.trianglehead.2.clockwise")
                }
                .help("Refresh what the remote has, so “published” is current")
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func links(remote: RemoteRepo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("On GitHub")
                .font(.headline)

            if let pullRequest = worktree.pullRequest, let url = URL(string: pullRequest.url) {
                LinkRow(
                    title: "\(pullRequest.label) — \(pullRequest.title)",
                    subtitle: "into \(pullRequest.baseRefName)",
                    symbol: pullRequest.state.symbol,
                    tint: pullRequest.state.color,
                    url: url
                )
            }

            if let branch = worktree.branch {
                // Only offered when the remote actually has the branch: a link to a
                // branch that was never pushed is a 404, which is worse than no link.
                if worktree.sync.isFullyPushed || worktree.sync.aheadCount > 0,
                    worktree.status != .localOnly, worktree.status != .remoteDeleted,
                    let url = remote.branchURL(branch)
                {
                    LinkRow(
                        title: "Branch \(branch)",
                        subtitle: url.absoluteString,
                        symbol: "arrow.triangle.branch",
                        tint: .accentColor,
                        url: url
                    )
                }
                if worktree.pullRequest == nil, worktree.hasUniqueCommits,
                    worktree.sync.isFullyPushed,
                    let url = remote.newPullRequestURL(base: worktree.baseBranch, head: branch)
                {
                    LinkRow(
                        title: "Open a pull request",
                        subtitle: "\(worktree.baseBranch)…\(branch)",
                        symbol: "plus.circle",
                        tint: .green,
                        url: url
                    )
                }
                if worktree.hasUniqueCommits, worktree.sync.isFullyPushed,
                    let url = remote.compareURL(base: worktree.baseBranch, head: branch)
                {
                    LinkRow(
                        title: "Compare with \(worktree.baseBranch)",
                        subtitle: url.absoluteString,
                        symbol: "arrow.left.arrow.right",
                        tint: .secondary,
                        url: url
                    )
                }
            }

            if worktree.status == .localOnly {
                Text("Nothing to link to yet — this branch has never been pushed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Details").font(.headline)
            DetailRow(label: "Status", value: worktree.sync.summary)
            DetailRow(label: "Base branch", value: worktree.baseBranch)
            DetailRow(label: "Upstream", value: worktree.upstream ?? "none configured")
            DetailRow(label: "HEAD", value: String(worktree.head.prefix(12)))
            if worktree.isDirty {
                DetailRow(
                    label: "Uncommitted",
                    value: Format.count(worktree.dirtyFileCount, "file", "files")
                )
            }
            if let repository {
                DetailRow(
                    label: "Last fetch",
                    value: Format.ago(repository.lastFetch) ?? "unknown",
                    // Everything the app says about GitHub is only as fresh as this.
                    note: "“Published” is only as current as the last fetch."
                )
            }
        }
    }

    @ViewBuilder
    private var commits: some View {
        if worktree.hasUniqueCommits {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(Format.count(worktree.uniqueCommits.count, "commit", "commits")) not on \(worktree.baseBranch)")
                    .font(.headline)
                ForEach(worktree.uniqueCommits) { commit in
                    CommitRow(
                        commit: commit,
                        remote: repository?.remote,
                        isPushed: worktree.sync.isFullyPushed
                    )
                }
            }
        }
    }
}

private struct DetailRow: View {
    var label: String
    var value: String
    var note: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                if let note {
                    Text(note).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }
}

private struct LinkRow: View {
    var title: String
    var subtitle: String
    var symbol: String
    var tint: Color
    var url: URL

    var body: some View {
        Button {
            SystemActions.open(url)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(tint).frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.callout).lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Image(systemName: "arrow.up.forward").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Copy Link") { SystemActions.copy(url.absoluteString) }
        }
    }
}

private struct CommitRow: View {
    var commit: Commit
    var remote: RemoteRepo?
    var isPushed: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(commit.shortSHA)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(commit.subject)
                    .font(.callout)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(commit.author) · \(Format.ago(commit.date) ?? "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isPushed, let url = remote?.commitURL(commit.sha) {
                Button {
                    SystemActions.open(url)
                } label: {
                    Image(systemName: "arrow.up.forward")
                }
                .buttonStyle(.borderless)
                .help("Open this commit on GitHub")
            }
        }
        .padding(.vertical, 3)
    }
}

import SwiftUI
import WorktreeKit

struct ContentView: View {
    @Bindable var store: WorktreeStore

    @State private var isCleaningUp = false

    var body: some View {
        NavigationSplitView {
            SidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 260, ideal: 310, max: 420)
        } detail: {
            Group {
                if let worktree = store.selectedWorktree {
                    WorktreeDetailView(
                        worktree: worktree,
                        repository: store.repository(for: worktree),
                        store: store
                    )
                } else {
                    ContentUnavailableView(
                        "Pick a worktree",
                        systemImage: "sidebar.left",
                        description: Text("Its branch, its commits and where its working copy lives.")
                    )
                }
            }
            .frame(minWidth: 420)
        }
        .searchable(text: $store.search, placement: .sidebar, prompt: "Branch, path or pull request")
        .toolbar { toolbar }
        .safeAreaInset(edge: .bottom, spacing: 0) { banners }
        .sheet(isPresented: $isCleaningUp) { CleanupSheet(store: store) }
        .task { await store.bootstrap() }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .status) {
            if store.isLoading || store.busyMessage != nil {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    if let message = store.busyMessage {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else if let lastScan = store.lastScan {
                Text("Scanned \(Format.ago(lastScan) ?? "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        ToolbarItem {
            Toggle(isOn: Binding(get: { store.hideMatchingBase }, set: { store.hideMatchingBase = $0 })) {
                Label("Hide worktrees with no commits of their own", systemImage: "line.3.horizontal.decrease.circle")
            }
            .help("Hide worktrees with no commits of their own")
        }
        ToolbarItem {
            Button {
                isCleaningUp = true
            } label: {
                Label("Clean Up", systemImage: "trash")
            }
            .help("Remove worktrees whose commits are already on GitHub")
            .disabled(store.isLoading || store.gitIsMissing)
        }
        ToolbarItem {
            Button {
                Task { await store.refresh(fetchFirst: true) }
            } label: {
                Label("Fetch All", systemImage: "arrow.trianglehead.2.clockwise")
            }
            .help("Fetch every remote, then rescan")
            .disabled(store.isLoading)
        }
        ToolbarItem {
            Button {
                Task { await store.refresh(fetchFirst: false) }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r")
            .disabled(store.isLoading)
        }
    }

    @ViewBuilder
    private var banners: some View {
        if let message = store.actionError ?? store.lastResult {
            let isError = store.actionError != nil
            HStack(spacing: 8) {
                Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(isError ? Color.red : .green)
                Text(message)
                    .font(.callout)
                    .textSelection(.enabled)
                    .lineLimit(2)
                Spacer()
                Button {
                    store.dismissBanners()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }
}

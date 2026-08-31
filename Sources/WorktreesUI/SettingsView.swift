import SwiftUI
import WorktreeKit

struct SettingsView: View {
    var store: WorktreeStore

    @State private var roots = Preferences.roots
    @State private var maxDepth = Preferences.maxDepth
    @State private var lookUpPullRequests = Preferences.lookUpPullRequests
    @State private var fetchOnRefresh = Preferences.fetchOnRefresh
    @State private var gitPath = Preferences.gitPath
    @State private var ghPath = Preferences.ghPath
    @State private var terminalApp = Preferences.terminalApp

    var body: some View {
        Form {
            Section("Where to look") {
                ForEach(Array(roots.enumerated()), id: \.offset) { index, _ in
                    HStack {
                        TextField("Directory", text: binding(for: index))
                            .font(.callout.monospaced())
                        Button {
                            chooseDirectory(for: index)
                        } label: {
                            Image(systemName: "folder")
                        }
                        Button {
                            roots.remove(at: index)
                            save()
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .disabled(roots.count <= 1)
                    }
                }
                Button("Add a directory") {
                    roots.append("~/code")
                    save()
                }
                Stepper("Look \(maxDepth) levels deep", value: $maxDepth, in: 1...4)
                    .onChange(of: maxDepth) { save() }
            }

            Section("What to read") {
                Toggle("Look up pull requests with gh", isOn: $lookUpPullRequests)
                    .onChange(of: lookUpPullRequests) { save() }
                Toggle("Fetch every remote when refreshing", isOn: $fetchOnRefresh)
                    .onChange(of: fetchOnRefresh) { save() }
                Text(
                    "Fetching is the only part that uses the network. Without it, whether a "
                        + "branch is published is read from the last fetch."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                if store.ghIsMissing && lookUpPullRequests {
                    Label("gh was not found, so no pull requests are shown.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Tools") {
                TextField("git", text: $gitPath, prompt: Text("found on your PATH"))
                    .font(.callout.monospaced())
                    .onSubmit { save() }
                TextField("gh", text: $ghPath, prompt: Text("found on your PATH"))
                    .font(.callout.monospaced())
                    .onSubmit { save() }
                Picker("Terminal", selection: $terminalApp) {
                    ForEach(["Terminal", "iTerm", "Ghostty", "WezTerm", "kitty", "Alacritty", "Warp"], id: \.self) {
                        Text($0).tag($0)
                    }
                }
                .onChange(of: terminalApp) { save() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 470)
    }

    private func binding(for index: Int) -> Binding<String> {
        Binding(
            get: { index < roots.count ? roots[index] : "" },
            set: { newValue in
                guard index < roots.count else { return }
                roots[index] = newValue
                save()
            }
        )
    }

    private func chooseDirectory(for index: Int) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        roots[index] = url.path
        save()
    }

    private func save() {
        Preferences.roots = roots.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        Preferences.maxDepth = maxDepth
        Preferences.lookUpPullRequests = lookUpPullRequests
        Preferences.fetchOnRefresh = fetchOnRefresh
        Preferences.gitPath = gitPath.trimmingCharacters(in: .whitespaces)
        Preferences.ghPath = ghPath.trimmingCharacters(in: .whitespaces)
        Preferences.terminalApp = terminalApp
        Task { await store.reloadSettings() }
    }
}

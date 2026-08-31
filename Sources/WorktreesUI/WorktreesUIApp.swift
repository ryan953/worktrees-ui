import SwiftUI
import WorktreeKit

@main
struct WorktreesUIApp: App {
    @State private var store = WorktreeStore()

    var body: some Scene {
        WindowGroup("Worktrees") {
            ContentView(store: store)
                .frame(minWidth: 820, minHeight: 480)
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .toolbar) {
                Button("Refresh") {
                    Task { await store.refresh(fetchFirst: false) }
                }
                .keyboardShortcut("r")
                Button("Fetch All and Refresh") {
                    Task { await store.refresh(fetchFirst: true) }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView(store: store)
        }
    }
}

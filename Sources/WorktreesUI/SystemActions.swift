import AppKit
import Foundation

enum SystemActions {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func reveal(_ path: String) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// Open the user's terminal at a directory.
    ///
    /// Handing the directory to the app rather than running `cd` in a script keeps this
    /// working for iTerm, Ghostty and the rest without knowing anything about them.
    static func openTerminal(at path: String) {
        let name = Preferences.terminalApp
        let directory = URL(fileURLWithPath: path)
        guard
            let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID(for: name))
                ?? NSWorkspace.shared.urlForApplication(toOpen: directory)
        else {
            reveal(path)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([directory], withApplicationAt: app, configuration: configuration)
    }

    private static func bundleID(for name: String) -> String {
        switch name.lowercased() {
        case "iterm", "iterm2": "com.googlecode.iterm2"
        case "ghostty": "com.mitchellh.ghostty"
        case "warp": "dev.warp.Warp-Stable"
        case "wezterm": "com.github.wez.wezterm"
        case "kitty": "net.kovidgoyal.kitty"
        case "alacritty": "org.alacritty"
        default: "com.apple.Terminal"
        }
    }
}

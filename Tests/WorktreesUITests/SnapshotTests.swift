import AppKit
import SwiftUI
import Testing
import WorktreeKit

@testable import WorktreesUI

/// Renders the real views into an offscreen window so the layout can be inspected
/// without launching the app. Writes PNGs under .build/snapshots.
///
/// `ImageRenderer` is not usable here: `List` and `ScrollView` are AppKit-backed and it
/// renders them blank. Hosting the view in a real `NSWindow` and asking the layer to
/// draw is what actually exercises them.
@MainActor
@Suite("View snapshots", .serialized)
struct SnapshotTests {
    static let outputDirectory = URL(fileURLWithPath: ".build/snapshots")

    /// Host `view` in a window, let it lay out, and write a PNG.
    @discardableResult
    static func snapshot(_ view: some View, size: CGSize, name: String) throws -> URL {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        // A real NSApplication has to exist before AppKit will lay anything out.
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Paint the window background the real app supplies. Without it the bitmap
        // caches as transparent-over-white while the views resolve dark-appearance
        // colours, and light text vanishes into the page.
        let framed = view
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: framed)
        host.frame = CGRect(origin: .zero, size: size)
        window.contentView = host
        window.orderFrontRegardless()

        // Give SwiftUI a few turns of the run loop to build the AppKit view tree; a
        // List populates its rows asynchronously.
        for _ in 0..<12 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        let url = outputDirectory.appendingPathComponent("\(name).png")
        try png.write(to: url)

        window.orderOut(nil)
        return url
    }

    /// Guards against a snapshot that renders as an empty page.
    static func assertNotBlank(_ url: URL, name: String) throws {
        let data = try Data(contentsOf: url)
        let rep = try #require(NSBitmapImageRep(data: data))
        var seen = Set<UInt32>()
        // Sample a grid rather than every pixel; a real UI shows many colours.
        for x in stride(from: 2, to: rep.pixelsWide, by: max(1, rep.pixelsWide / 40)) {
            for y in stride(from: 2, to: rep.pixelsHigh, by: max(1, rep.pixelsHigh / 40)) {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                let packed =
                    UInt32(color.redComponent * 255) << 16
                    | UInt32(color.greenComponent * 255) << 8
                    | UInt32(color.blueComponent * 255)
                seen.insert(packed)
            }
        }
        #expect(seen.count > 3, "\(name) looks blank — only \(seen.count) distinct colours")
    }

    // ContentView itself is deliberately not snapshotted: inside a NavigationSplitView
    // the sidebar column is drawn with a material that does not composite into an
    // offscreen cacheDisplay, so the shot shows a blank panel and proves nothing. The
    // two panes are captured separately instead.

    @Test func rendersTheSidebar() throws {
        let store = Fixtures.store(selection: Fixtures.localOnlyID)
        let url = try Self.snapshot(
            SidebarView(store: store),
            size: CGSize(width: 330, height: 660),
            name: "sidebar"
        )
        try Self.assertNotBlank(url, name: "sidebar")
    }

    @Test func rendersTheSidebarFilteredToUnpublished() throws {
        let store = Fixtures.store()
        store.filter = .unpublished
        let url = try Self.snapshot(
            SidebarView(store: store),
            size: CGSize(width: 330, height: 660),
            name: "sidebar-only-here"
        )
        try Self.assertNotBlank(url, name: "sidebar-only-here")
    }

    @Test func rendersAWorktreeWithWorkOnlyOnThisMachine() throws {
        let store = Fixtures.store(selection: Fixtures.localOnlyID)
        let worktree = try #require(store.selectedWorktree)
        let url = try Self.snapshot(
            WorktreeDetailView(
                worktree: worktree,
                repository: store.repository(for: worktree),
                store: store
            ),
            size: CGSize(width: 700, height: 660),
            name: "detail-local-only"
        )
        try Self.assertNotBlank(url, name: "detail-local-only")
    }

    @Test func rendersAPublishedWorktreeWithItsPullRequest() throws {
        let store = Fixtures.store(selection: Fixtures.publishedID)
        let worktree = try #require(store.selectedWorktree)
        let url = try Self.snapshot(
            WorktreeDetailView(
                worktree: worktree,
                repository: store.repository(for: worktree),
                store: store
            ),
            size: CGSize(width: 700, height: 660),
            name: "detail-published"
        )
        try Self.assertNotBlank(url, name: "detail-published")
    }
}

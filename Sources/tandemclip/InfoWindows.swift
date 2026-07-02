import SwiftUI
import AppKit

/// Hosts the About and Help windows for the menu-bar-only app.
final class InfoWindowController {
    private var aboutWindow: NSWindow?
    private var helpWindow: NSWindow?

    func showAbout() {
        if aboutWindow == nil {
            aboutWindow = Self.panel(title: "About TandemClip", view: AboutView())
        }
        present(aboutWindow)
    }

    func showHelp() {
        if helpWindow == nil {
            helpWindow = Self.panel(title: "TandemClip Help", view: HelpView())
        }
        present(helpWindow)
    }

    private func present(_ window: NSWindow?) {
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    private static func panel<V: View>(title: String, view: V) -> NSWindow {
        // Size the window to the SwiftUI view's own fitting size (the views
        // declare fixed frames), so it hugs content instead of stretching.
        let hosting = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: hosting)
        w.title = title
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        return w
    }
}

// MARK: - About

struct AboutView: View {
    private var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?" }
    private var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?" }

    var body: some View {
        VStack(spacing: 11) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 88, height: 88)
            Text("TandemClip").font(.system(size: 21, weight: .semibold))
            Text("Version \(version) (\(build))").font(.callout).foregroundColor(.secondary)
            Text("LAN-only clipboard sync between your Macs.\nNo cloud, no relay — everything stays on your network.")
                .font(.callout).foregroundColor(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Link("Website", destination: URL(string: "https://tandemclip.com")!)
                Text("·").foregroundColor(.secondary)
                Link("GitHub", destination: URL(string: "https://github.com/anatoliv/tandemclip")!)
            }
            .font(.callout)
            Text("© Amnesia. LAN-only clipboard sync.")
                .font(.caption2).foregroundColor(.secondary).padding(.top, 2)
        }
        .padding(.horizontal, 26).padding(.vertical, 24)
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Help

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("Getting started", [
                    ("Pair your Macs", "Install TandemClip on each Mac and enter the same pairing code (Settings → Security). Macs on the same Wi-Fi pair automatically."),
                    ("Trusted devices", "Optionally limit sync to devices you approve under Security → Trusted devices.")
                ])
                section("Sync modes", [
                    ("Mirror", "Every copy syncs to your other Macs automatically."),
                    ("Manual", "Nothing syncs until you pull a specific Mac's clipboard from the picker or menu.")
                ])
                section("Clipboard picker  (⇧⌘V)", [
                    ("Open", "Press ⇧⌘V anywhere to browse recent clips and grab another Mac's clipboard."),
                    ("Navigate", "↑ / ↓ to move, ⏎ to use, ⌘1–9 to quick-pick, ⎋ to close."),
                    ("Filter", "Use the All / Text / Images / Files chips to narrow the list; type to search."),
                    ("Files", "Picking a file copies it and opens it in its default app.")
                ])
                section("Tips", [
                    ("Menu bar", "Click the ↻ icon for status, mode, history, and the pairing code."),
                    ("Wi-Fi limit", "Restrict sync to trusted Wi-Fi networks under Security (needs Location permission)."),
                    ("Privacy", "Password-manager and transient clips are never synced.")
                ])
            }
            .padding(22)
        }
        .frame(width: 420, height: 520)
    }

    private func section(_ title: String, _ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold))
            ForEach(rows, id: \.0) { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.0).font(.system(size: 12, weight: .medium))
                    Text(row.1).font(.system(size: 12)).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

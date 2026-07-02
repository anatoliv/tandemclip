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
            Text("Shares your clipboard between your Macs over your local network — copy on one, paste on another. End-to-end encrypted with a code only you hold. No cloud, no account.")
                .font(.callout).foregroundColor(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Link("Website", destination: URL(string: "https://tandemclip.com")!)
                .font(.callout)
            Text("TandemClip — LAN clipboard sync for Macs")
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
                    ("Pair your Macs", "Install TandemClip on each Mac and enter the same pairing code (Settings → Security). The shared pairing code becomes the encryption key — being on the same Wi-Fi grants nothing on its own."),
                    ("Roles & trust", "Make a machine send-only or receive-only, and restrict sync to a trusted-device allowlist, under Security.")
                ])
                section("Sync modes", [
                    ("Mirror", "Copy anywhere and it appears everywhere. Deduped, loop-safe, and it relays across Macs that can't see each other directly."),
                    ("Manual", "Keep each Mac's clipboard its own. From the menu bar or picker, pull a specific Mac's clipboard when you want it.")
                ])
                section("Clipboard picker  (⇧⌘V)", [
                    ("Open", "Press ⇧⌘V anywhere to browse recent clips and grab another Mac's clipboard."),
                    ("Navigate", "↑ / ↓ to move, ⏎ to use, ⌘1–9 to quick-pick, ⎋ to close."),
                    ("Filter", "Use the All / Text / Images / Files chips to narrow the list; type to search."),
                    ("Files", "Picking a file copies it and opens it in its default app.")
                ])
                section("Private by design", [
                    ("No cloud, no relay", "Peers talk directly over your LAN. There is no server, no account, and nothing to breach."),
                    ("Password-manager safe", "Content marked secret by 1Password and others is never synced — same for one-time and transient copies."),
                    ("Wi-Fi limit", "Optionally restrict sync to trusted Wi-Fi networks under Security (needs Location permission).")
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

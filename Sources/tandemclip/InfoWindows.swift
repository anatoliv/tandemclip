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
    private let accent = Color(NSColor(srgbRed: 224/255, green: 122/255, blue: 75/255, alpha: 1))

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                card("Getting started", "sparkles") {
                    row("Pair your Macs", "Install TandemClip on each Mac and enter the same pairing code under Settings → Security. The pairing code becomes the encryption key — being on the same Wi-Fi grants nothing on its own.")
                    row("Roles & trust", "Make a Mac send-only or receive-only, and restrict sync to a trusted-device allowlist, under Settings → Security.")
                }

                card("Sync modes", "arrow.triangle.2.circlepath") {
                    row("Mirror", "Copy anywhere and it appears everywhere. Deduped, loop-safe, and it relays across Macs that can't see each other directly.")
                    row("Manual", "Keep each Mac's clipboard its own. From the menu bar or picker, pull a specific Mac's clipboard only when you want it.")
                }

                card("Clipboard picker", "rectangle.stack") {
                    Text("Press the shortcut anywhere to browse recent clips and grab another Mac's clipboard.")
                        .font(.system(size: 12)).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(spacing: 7) {
                        shortcut(["⇧", "⌘", "V"], "Open the picker")
                        shortcut(["↑", "↓"], "Move the selection")
                        shortcut(["⏎"], "Use the selected clip")
                        shortcut(["⌘", "1–9"], "Quick-pick by number")
                        shortcut(["⎋"], "Close")
                    }
                    .padding(.top, 2)
                    row("Filter & search", "Narrow the list with the All / Text / Images / Files chips, or just start typing to search.")
                    row("Files", "Picking a file copies it to the clipboard and opens it in its default app.")
                }

                card("Private by design", "lock.shield") {
                    row("No cloud, no relay", "Peers talk directly over your LAN. There is no server, no account, and nothing to breach.")
                    row("Password-manager safe", "Content marked secret by 1Password and others is never synced — same for one-time and transient copies.")
                    row("A code only you hold", "The shared pairing code is the encryption key. Change it any time under Settings → Security; peers reconnect once they share the new code.")
                    row("Wi-Fi limit", "Optionally restrict sync to trusted Wi-Fi networks under Settings → Security (needs Location permission).")
                }

                card("Menu bar & updates", "menubar.arrow.up.rectangle") {
                    row("Status at a glance", "Click the ↻ menu-bar icon for connected peers, current mode, clipboard size, history, and your pairing code.")
                    row("Pause & resume", "Pause syncing any time from the menu; ‘Start paused’ under Settings → General keeps it off at login.")
                    row("Stay current", "Use ‘Check for Updates…’ in the menu to get the latest version.")
                }

                card("Troubleshooting", "wrench.and.screwdriver") {
                    row("Not syncing?", "Confirm every Mac uses the same pairing code and is on the same Wi-Fi, and that this Mac isn’t paused or set to receive-only.")
                    row("A Mac won’t appear", "Give it a moment after wake — peers rediscover automatically. Two Macs should not share the same display name.")
                }
            }
            .padding(24)
        }
        .frame(width: 560, height: 660)
    }

    private var header: some View {
        HStack(spacing: 13) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text("TandemClip Help").font(.system(size: 19, weight: .semibold))
                Text("Copy on one Mac, paste on another — here’s everything.")
                    .font(.system(size: 12.5)).foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.bottom, 2)
    }

    private func card<Content: View>(_ title: String, _ symbol: String,
                                     @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundColor(accent)
                Text(title).font(.system(size: 13.5, weight: .semibold))
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.secondary.opacity(0.14)))
        .clipShape(RoundedRectangle(cornerRadius: 11))
    }

    private func row(_ title: String, _ desc: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 12.5, weight: .medium))
            Text(desc).font(.system(size: 12)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func shortcut(_ keys: [String], _ label: String) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(keys, id: \.self) { keyCap($0) }
            }
            .frame(width: 96, alignment: .leading)
            Text(label).font(.system(size: 12)).foregroundColor(.secondary)
            Spacer()
        }
    }

    private func keyCap(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Color.secondary.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

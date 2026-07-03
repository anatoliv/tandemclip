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
            Text("TandemClip").font(.system(size: 21, weight: .semibold, design: .rounded))
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
    private let accent = Color.tandemAccent
    @StateObject private var search = HelpSearchModel()
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                header
                searchField
            }
            .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if query.trimmingCharacters(in: .whitespaces).count >= 2 {
                        searchResults
                    } else {
                        shortcutsCard
                        ForEach(HelpCatalog.categories, id: \.name) { cat in
                            card(cat.name, cat.symbol) {
                                ForEach(HelpCatalog.topics(in: cat.name)) { topic in
                                    row(topic.title, topic.body)
                                }
                            }
                        }
                    }
                }
                .padding(24)
            }
        }
        .frame(width: 580, height: 700)
    }

    /// Search over every topic — instant keywords plus on-device semantic
    /// matching, so "stop sharing my clipboard" finds Privacy hold.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundColor(.secondary)
            TextField("Search help — try “stop sharing my clipboard”", text: $query)
                .textFieldStyle(.plain)
                .onChange(of: query) { q in search.update(q) }
            if !query.isEmpty {
                Button { query = ""; search.update("") } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
    }

    @ViewBuilder private var searchResults: some View {
        if search.results.isEmpty {
            Text("No help topics match “\(query)”.")
                .font(.system(size: 12.5)).foregroundColor(.secondary)
                .padding(.top, 8)
        } else {
            ForEach(search.results) { topic in
                card(topic.category, symbol(for: topic.category)) {
                    row(topic.title, topic.body)
                }
            }
        }
    }

    private func symbol(for category: String) -> String {
        HelpCatalog.categories.first { $0.name == category }?.symbol ?? "questionmark.circle"
    }

    /// Keyboard reference — kept as a hand-built card (keycaps don't fit the
    /// plain-text topic model).
    private var shortcutsCard: some View {
        card("Keyboard shortcuts", "command.square") {
            VStack(spacing: 7) {
                shortcut(["⇧", "⌘", "V"], "Open the picker")
                shortcut(["↑", "↓"], "Move the selection")
                shortcut(["⏎"], "Use the selected clip")
                shortcut(["⌘", "1–9"], "Quick-pick by number")
                shortcut(["⌘", "⌫"], "Delete the selected clip everywhere")
                shortcut(["⌘", "⏎"], "Use composed text (in compose)")
                shortcut(["⎋"], "Close the picker (unless pinned)")
            }
            .padding(.top, 2)
        }
    }

    private var header: some View {
        HStack(spacing: 13) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text("TandemClip Help").font(.system(size: 19, weight: .semibold, design: .rounded))
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

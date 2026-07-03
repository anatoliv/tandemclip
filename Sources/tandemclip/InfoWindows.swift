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

/// Two-pane help center: a left sidebar for navigation (search + category
/// sections + topic rows) and a right detail pane that renders the selected
/// article. Modeled on tonebox's HelpView so the two apps share a shape, but
/// with tandemclip's leaner plain-text topic model rendered through a small
/// inline Markdown formatter (no MarkdownUI dependency).
struct HelpView: View {
    /// Sidebar-selection id for the Welcome / overview landing panel.
    static let welcomeID = "welcome"
    /// Sidebar-selection id for the keyboard-shortcuts reference.
    static let shortcutsID = "shortcuts"
    /// Sidebar-selection id for the What's New release history.
    static let whatsNewID = "whatsnew"

    private let accent = Color.tandemAccent
    @StateObject private var search = HelpSearchModel()
    @State private var query = ""
    @State private var selection: String?

    /// Opens the Help window to a specific sidebar item (a topic id or one of
    /// the special ids). Defaults to the Welcome landing.
    init(initialSelection: String = HelpView.welcomeID) {
        _selection = State(initialValue: initialSelection)
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool { trimmedQuery.count >= 2 }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 244)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 860, height: 640)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 10)
            Divider()
            List(selection: $selection) {
                if isSearching {
                    searchResultRows
                } else {
                    Section("Start here") {
                        navRow(Self.welcomeID, "Welcome to TandemClip", "hand.wave")
                        navRow(Self.shortcutsID, "Keyboard shortcuts", "command.square")
                        navRow(Self.whatsNewID, "What's New", "sparkles")
                    }
                    ForEach(HelpCatalog.categories, id: \.name) { cat in
                        Section(cat.name) {
                            ForEach(HelpCatalog.topics(in: cat.name)) { topic in
                                navRow(topic.id, topic.title, cat.symbol)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
    }

    /// Search over every topic — instant keywords plus on-device semantic
    /// matching, so "stop sharing my clipboard" finds Privacy hold.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundColor(.secondary)
            TextField("Search help", text: $query)
                .textFieldStyle(.plain)
                .onChange(of: query) { q in search.update(q) }
            if !query.isEmpty {
                Button { query = ""; search.update("") } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary.opacity(0.6))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
    }

    @ViewBuilder private var searchResultRows: some View {
        if search.results.isEmpty {
            Text("No results for “\(trimmedQuery)”")
                .font(.system(size: 12)).foregroundColor(.secondary)
        } else {
            Section(search.results.count == 1 ? "1 result" : "\(search.results.count) results") {
                ForEach(search.results) { topic in
                    HStack(spacing: 8) {
                        Image(systemName: symbol(for: topic.category))
                            .font(.system(size: 12)).foregroundColor(.secondary)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(topic.title).font(.system(size: 12.5))
                            Text(topic.category).font(.system(size: 10.5)).foregroundColor(.secondary)
                        }
                    }
                    .tag(topic.id)
                }
            }
        }
    }

    private func navRow(_ id: String, _ title: String, _ symbol: String) -> some View {
        Label(title, systemImage: symbol).tag(id)
    }

    private func symbol(for category: String) -> String {
        HelpCatalog.categories.first { $0.name == category }?.symbol ?? "questionmark.circle"
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if selection == Self.welcomeID {
            welcomeDetail
        } else if selection == Self.shortcutsID {
            shortcutsDetail
        } else if selection == Self.whatsNewID {
            whatsNewDetail
        } else if let topic = HelpCatalog.topics.first(where: { $0.id == selection }) {
            topicDetail(topic)
        } else {
            welcomeDetail
        }
    }

    private func topicDetail(_ topic: HelpTopic) -> some View {
        detailScaffold(
            title: topic.title,
            symbol: symbol(for: topic.category),
            badge: topic.category
        ) {
            HelpMarkdown(topic.body)
        }
    }

    private var welcomeDetail: some View {
        detailScaffold(
            title: "Welcome to TandemClip",
            symbol: "hand.wave",
            badge: "Overview"
        ) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 13) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable().frame(width: 56, height: 56)
                    Text("Copy on one Mac, paste on another — end-to-end encrypted over your own network, with no cloud and no account.")
                        .font(.system(size: 13.5)).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HelpMarkdown("""
                **What it is.** TandemClip keeps the clipboards of your Macs in step. Copy on one, and it's ready to paste on the others a moment later. Everything travels directly over your local network — peers find each other with Bonjour and talk to each other; there is no server in the middle.

                **The two things you'll use most:**

                - The **menu-bar icon** shows sync state and holds the quick controls — pause/resume, pull from a peer, privacy hold, and Check for Updates.
                - The **clipboard picker** (⇧⌘V) is where everything else lives: your history, search, previews, pins, compose/AI, and per-clip actions.

                **Getting set up takes two steps:** install TandemClip on each Mac, then enter the same pairing code on all of them under Settings → Security. That code is the encryption key — sharing a network grants nothing without it.

                Use the sidebar to browse, or search at the top — it matches by meaning as well as words, so “stop sharing my clipboard” finds the Privacy hold.
                """)
            }
        }
    }

    private var shortcutsDetail: some View {
        detailScaffold(
            title: "Keyboard shortcuts",
            symbol: "command.square",
            badge: "Reference"
        ) {
            VStack(alignment: .leading, spacing: 18) {
                shortcutGroup("The clipboard picker", [
                    (["⇧", "⌘", "V"], "Open the picker (works in any app)"),
                    (["↑", "↓"], "Move the selection"),
                    (["⏎"], "Use the selected clip"),
                    (["⌘", "1–9"], "Quick-pick a clip by its number"),
                    (["⌘", "⌫"], "Delete the selected clip everywhere"),
                    (["⎋"], "Close the picker (ignored while pinned 📌)"),
                ])
                shortcutGroup("Typing & search", [
                    (["A–Z"], "Just start typing to search your clips"),
                ])
                shortcutGroup("Compose & AI (✎)", [
                    (["⌘", "⏎"], "Use the composed / rewritten text"),
                ])
                Text("The picker's hotkey (⇧⌘V) is fixed. Everything else — pause, pull, privacy hold, Check for Updates — lives in the menu-bar menu.")
                    .font(.system(size: 12)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var whatsNewDetail: some View {
        detailScaffold(
            title: "What's New",
            symbol: "sparkles",
            badge: "Release notes"
        ) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Every version of TandemClip, newest first.")
                    .font(.system(size: 12.5)).foregroundColor(.secondary)
                ForEach(Array(HelpCatalog.releases.enumerated()), id: \.element.id) { index, release in
                    releaseCard(release, isLatest: index == 0)
                }
            }
            .frame(maxWidth: 620, alignment: .leading)
        }
    }

    private func releaseCard(_ release: HelpRelease, isLatest: Bool) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Text("Version \(release.version)").font(.system(size: 15, weight: .bold))
                if isLatest {
                    Text("LATEST")
                        .font(.system(size: 9, weight: .bold)).tracking(0.5)
                        .foregroundColor(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Tokens.positive, in: Capsule())
                }
                Spacer()
                Text(release.date).font(.system(size: 12)).foregroundColor(.secondary)
            }
            Text(release.highlight)
                .font(.system(size: 12.5)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            VStack(alignment: .leading, spacing: 9) {
                ForEach(release.changes) { change in
                    HStack(alignment: .top, spacing: 10) {
                        Text(change.kind.label.uppercased())
                            .font(.system(size: 9, weight: .bold)).tracking(0.4)
                            .foregroundColor(tint(for: change.kind))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(tint(for: change.kind).opacity(0.14), in: Capsule())
                            .frame(width: 68, alignment: .leading)
                            .padding(.top, 1)
                        Text(change.text)
                            .font(.system(size: 12.5))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.secondary.opacity(0.12)))
    }

    private func tint(for kind: ReleaseChangeKind) -> Color {
        switch kind {
        case .added:    return Tokens.positive
        case .improved: return accent
        case .fixed:    return .orange
        }
    }

    private func shortcutGroup(_ title: String, _ items: [(keys: [String], label: String)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .bold)).foregroundColor(.secondary)
                .tracking(0.4)
            VStack(spacing: 7) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 10) {
                        HStack(spacing: 4) { ForEach(item.keys, id: \.self) { keyCap($0) } }
                            .frame(width: 104, alignment: .leading)
                        Text(item.label).font(.system(size: 12.5)).foregroundColor(.secondary)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private func keyCap(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Color.secondary.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    /// Shared detail chrome: a pinned header (symbol + title + category badge)
    /// over a scrolling body, matching the Help window's two-pane frame.
    private func detailScaffold<Content: View>(
        title: String, symbol: String, badge: String,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: symbol)
                        .font(.system(size: 18, weight: .medium)).foregroundColor(accent)
                    Text(title).font(.system(size: 20, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(badge.uppercased())
                    .font(.system(size: 10, weight: .bold)).foregroundColor(.secondary)
                    .tracking(0.5)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.10), in: Capsule())
            }
            .padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 16)
            Divider()
            ScrollView {
                content()
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 28).padding(.vertical, 22)
            }
        }
    }
}

/// A minimal Markdown renderer for help bodies: splits on blank lines into
/// paragraphs and bullet lists, and renders inline **bold**, `code`, and
/// links via AttributedString. Keeps articles readable without pulling in a
/// full Markdown engine.
struct HelpMarkdown: View {
    private let blocks: [Block]

    private enum Block: Identifiable {
        case paragraph(String)
        case bullets([String])
        var id: String {
            switch self {
            case .paragraph(let s): return "p:" + s
            case .bullets(let items): return "b:" + items.joined(separator: "|")
            }
        }
    }

    init(_ text: String) {
        blocks = Self.parse(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(blocks) { block in
                switch block {
                case .paragraph(let text):
                    styled(text)
                        .font(.system(size: 13.5)).lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                case .bullets(let items):
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(items, id: \.self) { item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("•").font(.system(size: 13.5)).foregroundColor(.secondary)
                                styled(item)
                                    .font(.system(size: 13.5)).lineSpacing(3)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: 620, alignment: .leading)
    }

    /// Inline Markdown (bold / code / links) via AttributedString, falling
    /// back to the raw string if parsing fails.
    private func styled(_ text: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        return Text(text)
    }

    private static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var bullets: [String] = []

        func flushParagraph() {
            let joined = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            paragraph.removeAll()
        }
        func flushBullets() {
            if !bullets.isEmpty { blocks.append(.bullets(bullets)); bullets.removeAll() }
        }

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flushParagraph(); flushBullets()
            } else if line.hasPrefix("- ") || line.hasPrefix("• ") {
                flushParagraph()
                bullets.append(String(line.dropFirst(2)))
            } else {
                flushBullets()
                paragraph.append(line)
            }
        }
        flushParagraph(); flushBullets()
        return blocks
    }
}

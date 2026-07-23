import SwiftUI
import AppKit

extension Notification.Name {
    /// Posted when something (e.g. a Settings link) wants the Help window
    /// opened. AppController observes it and calls `InfoWindowController.showHelp`.
    static let tandemOpenHelp = Notification.Name("tandemclip.openHelp")

    /// Posted (object = Tab rawValue string) to switch the Settings window to a
    /// specific tab — used by the Welcome window's deep-link buttons so they
    /// work even when Settings is already open (past its first `onAppear`).
    static let tandemSelectSettingsTab = Notification.Name("tandemclip.selectSettingsTab")
}

/// Opens the in-app Help window at a specific article — and, optionally, at a
/// specific spot *within* that article (a phrase to scroll to and briefly
/// highlight). Settings' inline "learn more" links call `open(topic:anchor:)`;
/// those links are encoded as `tchelp://<topic>?a=<phrase>` URLs and decoded by
/// `handle(_:)` from an `openURL` handler.
enum HelpDeepLink {
    /// Custom URL scheme used by inline Settings links.
    static let scheme = "tchelp"
    /// UserDefaults keys the Help window reads (via @AppStorage) to know where
    /// to jump. Shared across the two AppKit-hosted windows.
    static let topicKey = "tandemclip.help.requestedTopic"
    static let anchorKey = "tandemclip.help.requestedAnchor"

    /// Request the Help window at `topic`, optionally scrolled to `anchor`
    /// (a substring of the article body). Opens/raises the window.
    static func open(topic: String, anchor: String? = nil) {
        let defaults = UserDefaults.standard
        defaults.set(topic, forKey: topicKey)
        defaults.set(anchor ?? "", forKey: anchorKey)
        NotificationCenter.default.post(name: .tandemOpenHelp, object: nil)
    }

    /// Decode a `tchelp://<topic>?a=<phrase>` link and route it. Returns true
    /// when handled (so an `openURL` handler can claim it).
    static func handle(_ url: URL) -> Bool {
        guard url.scheme == scheme, let topic = url.host, !topic.isEmpty else { return false }
        let anchor = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "a" }?.value
        open(topic: topic, anchor: anchor)
        return true
    }

    /// Build the `tchelp://` link a Settings term points at.
    static func url(topic: String, anchor: String? = nil) -> URL? {
        var comps = URLComponents()
        comps.scheme = scheme
        comps.host = topic
        if let anchor, !anchor.isEmpty { comps.queryItems = [URLQueryItem(name: "a", value: anchor)] }
        return comps.url
    }
}

/// Hosts the About and Help windows for the menu-bar-only app.
final class InfoWindowController {
    private var aboutWindow: NSWindow?
    private var helpWindow: NSWindow?
    private var welcomeWindow: NSWindow?

    /// First-run (and reopenable) Welcome window. `openSettings` jumps Settings
    /// to a tab; `openHelp` opens the Help reader.
    func showWelcome(openSettings: @escaping (String) -> Void, openHelp: @escaping () -> Void) {
        let firstTime = welcomeWindow == nil
        if firstTime {
            let view = WelcomeView(openSettings: openSettings, openHelp: openHelp,
                                   dismiss: { [weak self] in self?.welcomeWindow?.close() })
            let w = Self.panel(title: "Welcome to TandemClip", view: view)
            w.styleMask.insert(.resizable)
            w.setContentSize(NSSize(width: 580, height: 660))
            w.contentMinSize = NSSize(width: 520, height: 460)
            welcomeWindow = w
        }
        present(welcomeWindow, center: firstTime)
    }

    func showAbout() {
        if aboutWindow == nil {
            aboutWindow = Self.panel(title: "About TandemClip", view: AboutView())
        }
        present(aboutWindow)
    }

    func showHelp() {
        let firstTime = helpWindow == nil
        if firstTime {
            let w = Self.panel(title: "TandemClip Help", view: HelpView())
            // The Help window is a full two-pane reader — let people resize it.
            // (About stays content-hugging and non-resizable.)
            w.styleMask.insert(.resizable)
            w.setContentSize(NSSize(width: 860, height: 640))
            w.contentMinSize = NSSize(width: 620, height: 420)
            helpWindow = w
        }
        present(helpWindow, center: firstTime)
    }

    private func present(_ window: NSWindow?, center: Bool = true) {
        NSApp.activate(ignoringOtherApps: true)
        // Only center on first open, so a window the user has moved or resized
        // reopens where they left it.
        if center { window?.center() }
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    private static func panel<V: View>(title: String, view: V) -> NSWindow {
        // Size the window to the SwiftUI view's own fitting size (the views
        // declare fixed or flexible frames).
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
        VStack(spacing: Tokens.Space.snug) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 88, height: 88)
            Text("TandemClip").font(Tokens.FontScale.display)
            Text("Version \(version) (\(build))").font(Tokens.FontScale.small).foregroundColor(.secondary)
            Text("Shares your clipboard between your Macs over your local network — copy on one, paste on another. End-to-end encrypted with a code only you hold. No cloud, no account.")
                .font(Tokens.FontScale.body).foregroundColor(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Link("Website", destination: URL(string: "https://tandemclip.com")!)
                .font(Tokens.FontScale.small)
                .tint(Tokens.accent)   // links use the accent, not system blue (DESIGN_SYSTEM.md §2)
            if !TandemSupportLinks.options.isEmpty {
                // Free & MIT — a compact, optional tip-jar row (full section lives in Settings).
                (Text("Support: ").foregroundColor(.secondary)
                    + Text(TandemSupportLinks.compactLinks))
                    .font(Tokens.FontScale.small)
                    .tint(Tokens.accent)   // links ride the accent (DESIGN_SYSTEM.md §2)
                    .multilineTextAlignment(.center)
            }
            Text("TandemClip — LAN clipboard sync for Macs")
                .font(Tokens.FontScale.tiny).foregroundColor(.secondary).padding(.top, Tokens.Space.row)
        }
        .padding(.horizontal, Tokens.Space.wide).padding(.vertical, Tokens.Space.wide)
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Welcome (first run)

/// First-run onboarding, shown once (see `Config.hasSeenWelcome`) and
/// reopenable from the menu bar ▸ Getting Started. Four plain-English steps:
/// what already works, the one pairing step, optional hardening, optional AI.
/// The step buttons deep-link into the matching Settings tab. The same arc
/// lives in Help's Welcome page so there's one story in two places.
struct WelcomeView: View {
    /// Open Settings at a `SettingsView.Tab` rawValue ("Security" / "AI").
    let openSettings: (String) -> Void
    let openHelp: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Space.snug) {
                    step(1, "It already works",
                         "Nothing to configure to start. Right now TandemClip syncs text, rich text, and images between your Macs automatically, runs at login, keeps a searchable history you open with ⇧⌘V, and holds back anything that looks like a password or key. (Files are the one thing off by default — turn them on in Settings ▸ Content when you want them.)")
                    step(2, "Pair your Macs — the one thing to do",
                         "Sync needs two or more Macs that share a pairing code. That code — not just “same Wi-Fi” — is what lets them find and trust each other. Install TandemClip on your other Mac, then set the same code on both. Press ⇧⌘V anytime to open the picker and grab a specific Mac’s clipboard.",
                         action: ("Set the pairing code", "Security"))
                    step(3, "Lock it down (optional, recommended)",
                         "When you’re ready to tighten things up: turn on Trusted devices to pin exactly which Macs may sync — and revoke any of them instantly — and restrict sync to your home Wi-Fi so nothing happens on public networks. Secret Guard is already catching passwords and keys for you.",
                         action: ("Open Security settings", "Security"))
                    step(4, "Add smarts (optional)",
                         "Bring your own AI model. Turn on “Enable AI text cleanup,” then sign in with ChatGPT or add an API key — a local model works too. That unlocks one-tap cleanup, ✨ smart titles for long clips, and translation of incoming foreign-language clips, all sent straight from your Mac to your model, never through us.",
                         action: ("Open AI settings", "AI"))
                }
                .padding(Tokens.Space.pane)
            }
            Divider()
            footer
        }
        .frame(minWidth: 520, idealWidth: 580, minHeight: 460, idealHeight: 660)
        .tint(Tokens.accent)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Tokens.Space.element) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: Tokens.Space.row6) {
                Text("Welcome to TandemClip").font(Tokens.FontScale.title)
                Text("It already works — copy on this Mac, paste on your other Macs. Encrypted over your own network, no cloud, no account.")
                    .font(Tokens.FontScale.body).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(Tokens.Space.pane)
    }

    private var footer: some View {
        HStack(spacing: Tokens.Space.snug) {
            Button("Get Started") { dismiss() }
                .buttonStyle(.borderedProminent).tint(Tokens.accent)
                .keyboardShortcut(.defaultAction)
            Button("Open full Help") { openHelp() }
                .buttonStyle(.bordered)
            Spacer()
            Text("Reopen from the menu bar ▸ Getting Started")
                .font(Tokens.FontScale.tiny).foregroundColor(.secondary)
        }
        .padding(.horizontal, Tokens.Space.pane)
        .padding(.vertical, Tokens.Space.regular)
    }

    private func step(_ n: Int, _ title: String, _ body: String,
                      action: (label: String, tab: String)? = nil) -> some View {
        HStack(alignment: .top, spacing: Tokens.Space.element) {
            ZStack {
                Circle().fill(Tokens.accent).frame(width: 24, height: 24)
                Text("\(n)").font(Tokens.FontScale.bodyStrong).foregroundColor(.white)
            }
            VStack(alignment: .leading, spacing: Tokens.Space.row6) {
                Text(title).font(Tokens.FontScale.sectionHeader)
                Text(body).font(Tokens.FontScale.body).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let action {
                    Button(action.label) { openSettings(action.tab) }
                        .buttonStyle(.bordered).tint(Tokens.accent)
                        .padding(.top, Tokens.Space.row)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Tokens.Space.regular)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Tokens.Radius.card).fill(Color.secondary.opacity(0.06)))
    }
}

// MARK: - Help

/// Two-pane help center: a left sidebar for navigation (search + category
/// sections + topic rows) and a right detail pane that renders the selected
/// article. A lean plain-text topic model rendered through a small
/// inline Markdown formatter (no MarkdownUI dependency).
struct HelpView: View {
    /// Sidebar-selection id for the Welcome / overview landing panel.
    static let welcomeID = "welcome"
    /// Sidebar-selection id for the keyboard-shortcuts reference.
    static let shortcutsID = "shortcuts"
    /// Sidebar-selection id for the What's New release history.
    static let whatsNewID = "whatsnew"

    /// Scroll-target id assigned to the article block a deep-link anchor points
    /// at, so `ScrollViewReader` can bring it into view.
    static let anchorBlockID = "help-anchor-block"

    private let accent = Color.tandemAccent
    @StateObject private var search = HelpSearchModel()
    @State private var query = ""
    @State private var selection: String?

    /// A phrase to scroll to + highlight inside the selected article (set by a
    /// deep-link); nil when the article was opened normally.
    @State private var anchor: String?
    /// Bumped on each deep-link so the scaffold re-scrolls even to the same topic.
    @State private var anchorNonce = 0

    /// Deep-link inbox, written by `HelpDeepLink.open` and observed here.
    @AppStorage(HelpDeepLink.topicKey) private var requestedTopic = ""
    @AppStorage(HelpDeepLink.anchorKey) private var requestedAnchor = ""

    /// Opens the Help window to a specific sidebar item (a topic id or one of
    /// the special ids). Defaults to the Welcome landing.
    init(initialSelection: String = HelpView.welcomeID) {
        _selection = State(initialValue: initialSelection)
    }

    /// Honor a pending deep-link (topic + optional anchor), then clear it so the
    /// same request isn't re-applied. Runs on appear and whenever the request
    /// changes while the window is already open.
    private func applyDeepLink() {
        let topic = requestedTopic
        guard !topic.isEmpty else { return }
        let isKnown = topic == Self.welcomeID || topic == Self.shortcutsID
            || topic == Self.whatsNewID || HelpCatalog.topics.contains { $0.id == topic }
        guard isKnown else { requestedTopic = ""; requestedAnchor = ""; return }
        query = ""
        selection = topic
        anchor = requestedAnchor.isEmpty ? nil : requestedAnchor
        anchorNonce += 1
        requestedTopic = ""
        requestedAnchor = ""
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
        // Flexible so the window is resizable: a fixed sidebar with a detail
        // pane that grows, bounded by a sensible minimum. The window's own
        // initial/min size is set in InfoWindowController.showHelp().
        .frame(minWidth: 620, maxWidth: .infinity, minHeight: 420, maxHeight: .infinity)
        // Sidebar selection + controls ride the accent (DESIGN_SYSTEM.md §2).
        .tint(Tokens.accent)
        .onAppear { applyDeepLink() }
        .onChange(of: requestedTopic) { _ in applyDeepLink() }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, Tokens.Space.snug).padding(.top, Tokens.Space.snug).padding(.bottom, Tokens.Space.medium)
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
        HStack(spacing: Tokens.Space.row6) {
            Image(systemName: "magnifyingglass").font(Tokens.FontScale.small).foregroundColor(.secondary)
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
        .padding(.horizontal, Tokens.Space.medium).padding(.vertical, Tokens.Space.row6)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
    }

    @ViewBuilder private var searchResultRows: some View {
        if search.results.isEmpty {
            Text("No results for “\(trimmedQuery)”")
                .font(Tokens.FontScale.small).foregroundColor(.secondary)
        } else {
            Section(search.results.count == 1 ? "1 result" : "\(search.results.count) results") {
                ForEach(search.results) { topic in
                    HStack(spacing: Tokens.Space.tight) {
                        Image(systemName: symbol(for: topic.category))
                            .font(Tokens.FontScale.small).foregroundColor(.secondary)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(topic.title).font(Tokens.FontScale.small)
                            Text(topic.category).font(Tokens.FontScale.tiny).foregroundColor(.secondary)
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
            badge: topic.category,
            scrollNonce: anchorNonce
        ) {
            HelpMarkdown(topic.body, highlight: anchor)
        }
    }

    private var welcomeDetail: some View {
        detailScaffold(
            title: "Welcome to TandemClip",
            symbol: "hand.wave",
            badge: "Overview"
        ) {
            VStack(alignment: .leading, spacing: Tokens.Space.regular) {
                HStack(spacing: Tokens.Space.snug) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable().frame(width: 56, height: 56)
                    Text("Copy on one Mac, paste on another — end-to-end encrypted over your own network, with no cloud and no account.")
                        .font(Tokens.FontScale.body).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HelpMarkdown("""
                **What it is.** TandemClip keeps the clipboards of your Macs in step. Copy on one, and it's ready to paste on the others a moment later. Everything travels directly over your local network — peers find each other with Bonjour and talk to each other; there is no server in the middle.

                **1. It already works.** Out of the box TandemClip syncs text, rich text, and images automatically, runs at login, keeps a searchable history you open with ⇧⌘V, and holds back anything that looks like a password or key (Secret Guard). Files are the one thing off by default — enable them under Settings → Content.

                **2. Pair your Macs — the one thing to do.** Sync needs two or more Macs that share a pairing code. That code, not just being on the same Wi-Fi, is the encryption key that lets them find and trust each other. Install TandemClip on each Mac and set the same code on all of them under Settings → Security.

                **3. Lock it down (optional, recommended).** Turn on Trusted devices to pin exactly which Macs may sync — and revoke any instantly — and restrict sync to your home Wi-Fi so nothing happens on public networks. Both live under Settings → Security; Secret Guard is already on.

                **4. Add smarts (optional).** Turn on “Enable AI text cleanup” under Settings → AI and connect a model — ChatGPT sign-in, an API key, or a local server. You get one-tap cleanup, ✨ smart titles for long clips, and translation of incoming foreign-language clips, sent straight from your Mac to your model.

                **The two things you'll use most:**

                - The **menu-bar icon** shows sync state and holds the quick controls — pause/resume, pull from a peer, privacy hold, Check for Updates, and Getting Started (reopens the welcome guide).
                - The **clipboard picker** (⇧⌘V) is where everything else lives: your history, search, previews, pins, compose/AI, and per-clip actions.

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
            VStack(alignment: .leading, spacing: Tokens.Space.regular) {
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
                    .font(Tokens.FontScale.small).foregroundColor(.secondary)
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
            VStack(alignment: .leading, spacing: Tokens.Space.regular) {
                Text("Every version of TandemClip, newest first.")
                    .font(Tokens.FontScale.small).foregroundColor(.secondary)
                ForEach(Array(HelpCatalog.releases.enumerated()), id: \.element.id) { index, release in
                    releaseCard(release, isLatest: index == 0)
                }
            }
            .frame(maxWidth: 620, alignment: .leading)
        }
    }

    private func releaseCard(_ release: HelpRelease, isLatest: Bool) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.snug) {
            HStack(spacing: Tokens.Space.tight) {
                Text("Version \(release.version)").font(Tokens.FontScale.sectionHeader)
                if isLatest {
                    Text("LATEST")
                        .font(Tokens.FontScale.micro).tracking(0.5)
                        .foregroundColor(.white)
                        .padding(.horizontal, Tokens.ChipPadding.h).padding(.vertical, Tokens.ChipPadding.v)
                        .background(Tokens.positive, in: Capsule())
                }
                Spacer()
                Text(release.date).font(Tokens.FontScale.small).foregroundColor(.secondary)
            }
            Text(release.highlight)
                .font(Tokens.FontScale.small).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            VStack(alignment: .leading, spacing: Tokens.Space.tight) {
                ForEach(release.changes) { change in
                    HStack(alignment: .top, spacing: Tokens.Space.medium) {
                        Text(change.kind.label.uppercased())
                            .font(Tokens.FontScale.micro).tracking(0.4)
                            .foregroundColor(tint(for: change.kind))
                            .padding(.horizontal, Tokens.ChipPadding.h).padding(.vertical, Tokens.ChipPadding.v)
                            .background(tint(for: change.kind).opacity(0.14), in: Capsule())
                            .frame(width: 68, alignment: .leading)
                            .padding(.top, 1)
                        Text(change.text)
                            .font(Tokens.FontScale.small)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(Tokens.Space.regular)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.card).strokeBorder(Color.secondary.opacity(0.12)))
    }

    /// Semantic color per change kind — added = positive (moss), improved =
    /// accent (terracotta), fixed = warning (amber). See DESIGN_SYSTEM.md §2.
    private func tint(for kind: ReleaseChangeKind) -> Color {
        switch kind {
        case .added:    return Tokens.positive
        case .improved: return accent
        case .fixed:    return Tokens.warning
        }
    }

    private func shortcutGroup(_ title: String, _ items: [(keys: [String], label: String)]) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.tight) {
            Text(title.uppercased())
                .font(Tokens.FontScale.tiny.weight(.bold)).foregroundColor(.secondary)
                .tracking(0.4)
            VStack(spacing: Tokens.Space.row6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(spacing: Tokens.Space.medium) {
                        HStack(spacing: Tokens.Space.row) { ForEach(item.keys, id: \.self) { keyCap($0) } }
                            .frame(width: 104, alignment: .leading)
                        Text(item.label).font(Tokens.FontScale.small).foregroundColor(.secondary)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private func keyCap(_ text: String) -> some View {
        // Rounded face is deliberate for keycaps — the one place SF Rounded
        // is used outside brand moments (DESIGN_SYSTEM.md §8).
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .padding(.horizontal, Tokens.ChipPadding.h).padding(.vertical, 3)
            .background(Color.secondary.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.control))
    }

    /// Shared detail chrome: a pinned header (symbol + title + category badge)
    /// over a scrolling body, matching the Help window's two-pane frame. When
    /// `scrollNonce` changes to a non-zero value, the body scrolls to the
    /// deep-link anchor block (if the current article contains one).
    private func detailScaffold<Content: View>(
        title: String, symbol: String, badge: String, scrollNonce: Int = 0,
        @ViewBuilder _ content: @escaping () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Tokens.Space.tight) {
                HStack(spacing: Tokens.Space.medium) {
                    Image(systemName: symbol)
                        .font(.system(size: Tokens.IconSize.regular, weight: .medium)).foregroundColor(accent)
                    Text(title).font(Tokens.FontScale.title)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(badge.uppercased())
                    .font(Tokens.FontScale.micro).foregroundColor(.secondary)
                    .tracking(0.5)
                    .padding(.horizontal, Tokens.Space.tight).padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.10), in: Capsule())
            }
            .padding(.horizontal, Tokens.Space.pane).padding(.top, Tokens.Space.wide).padding(.bottom, Tokens.Space.regular)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    content()
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Tokens.Space.pane).padding(.vertical, Tokens.Space.wide)
                }
                // Runs on appear and whenever a new deep-link arrives; a beat of
                // delay lets the body lay out before we scroll to the anchor.
                .task(id: scrollNonce) {
                    guard scrollNonce > 0 else { return }
                    try? await Task.sleep(nanoseconds: 60_000_000)
                    withAnimation(Tokens.Motion.paneCurve) {
                        proxy.scrollTo(HelpView.anchorBlockID, anchor: .center)
                    }
                }
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
    /// Deep-link phrase to scroll to + briefly highlight (nil = none).
    private let highlight: String?
    /// Index of the first block containing `highlight` (−1 = no match).
    private let matchIndex: Int
    /// Drives the fade-out of the highlight flash.
    @State private var flashed = false

    private enum Block: Identifiable {
        case paragraph(String)
        case bullets([String])
        var id: String {
            switch self {
            case .paragraph(let s): return "p:" + s
            case .bullets(let items): return "b:" + items.joined(separator: "|")
            }
        }
        var searchText: String {
            switch self {
            case .paragraph(let s): return s
            case .bullets(let items): return items.joined(separator: " ")
            }
        }
    }

    init(_ text: String, highlight: String? = nil) {
        let parsed = Self.parse(text)
        blocks = parsed
        self.highlight = highlight
        if let needle = highlight?.lowercased(), !needle.isEmpty {
            matchIndex = parsed.firstIndex { $0.searchText.lowercased().contains(needle) } ?? -1
        } else {
            matchIndex = -1
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.snug) {
            ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                blockView(block)
                    .modifier(AnchorHighlight(isTarget: index == matchIndex, flashed: flashed))
            }
        }
        .frame(maxWidth: 620, alignment: .leading)
        // Flash the anchored block once, then fade it out.
        .task(id: highlight) {
            guard matchIndex >= 0 else { return }
            flashed = false
            try? await Task.sleep(nanoseconds: 120_000_000)
            withAnimation(.easeOut(duration: 1.6)) { flashed = true }
        }
    }

    @ViewBuilder private func blockView(_ block: Block) -> some View {
        switch block {
        case .paragraph(let text):
            styled(text)
                .font(Tokens.FontScale.body).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: Tokens.Space.row6) {
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.tight) {
                        Text("•").font(Tokens.FontScale.body).foregroundColor(.secondary)
                        styled(item)
                            .font(Tokens.FontScale.body).lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// Tags the deep-link target block with the scroll id and paints a brief
    /// accent flash behind it that fades to nothing. Non-target blocks are
    /// untouched.
    private struct AnchorHighlight: ViewModifier {
        let isTarget: Bool
        let flashed: Bool
        @Environment(\.colorScheme) private var scheme
        /// Peak flash opacity. A 0.16 accent wash reads clearly on light paper
        /// but nearly vanishes over a dark surface — bump it in dark mode so the
        /// terracotta comes through and the "here's your spot" cue stays legible.
        private var peak: Double { scheme == .dark ? Tokens.HelpHighlight.dark : Tokens.HelpHighlight.light }
        func body(content: Content) -> some View {
            if isTarget {
                content
                    .padding(.horizontal, Tokens.Space.tight)
                    .padding(.vertical, Tokens.Space.row6)
                    .background(
                        RoundedRectangle(cornerRadius: Tokens.Radius.card)
                            .fill(Tokens.accent.opacity(flashed ? 0 : peak))
                    )
                    .padding(.horizontal, -Tokens.Space.tight)
                    .padding(.vertical, -Tokens.Space.row6)
                    .id(HelpView.anchorBlockID)
            } else {
                content
            }
        }
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

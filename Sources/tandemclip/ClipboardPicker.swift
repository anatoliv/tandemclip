import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Panel (borderless, can become key without activating everything)

final class PickerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Controller

final class ClipboardPickerController {
    private let config: Config
    private let engine: SyncEngine
    private var panel: PickerPanel?
    private var model: PickerModel?

    init(config: Config, engine: SyncEngine) {
        self.config = config
        self.engine = engine
    }

    func toggle() { (panel?.isVisible ?? false) ? hide() : show() }

    func show() {
        let model = self.model ?? makeModel()
        self.model = model
        model.reload(history: engine.history, peers: engine.syncablePeers(),
                     showCount: config.pickerShowCount, clipUsage: usageString())

        if panel == nil {
            let p = PickerPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 520),
                                styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel, .resizable],
                                backing: .buffered, defer: false)
            p.titleVisibility = .hidden
            p.titlebarAppearsTransparent = true
            p.isMovableByWindowBackground = true
            p.level = .floating
            // Appear over fullscreen apps and on every Space.
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.minSize = NSSize(width: 380, height: 320)
            p.standardWindowButton(.closeButton)?.isHidden = true
            p.standardWindowButton(.miniaturizeButton)?.isHidden = true
            p.standardWindowButton(.zoomButton)?.isHidden = true
            p.contentView = NSHostingView(rootView: PickerView(model: model))
            p.setFrameAutosaveName("TandemClipPicker")   // remember size + position
            if p.frame.origin == .zero { p.center() }     // first run only
            panel = p
        }
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
        panel?.orderFrontRegardless()
        Log.trace("picker", "shown; visible=\(panel?.isVisible ?? false)")
    }

    /// Live-refresh while open (called on engine status changes) so clips copied
    /// on other Macs appear without reopening. Preserves query + selection.
    func refreshIfVisible() {
        guard let panel, panel.isVisible, let model else { return }
        model.refresh(history: engine.history, peers: engine.syncablePeers(),
                      showCount: config.pickerShowCount, clipUsage: usageString())
    }

    func hide() { panel?.orderOut(nil) }

    /// Total size of everything held in clipboard history (what the picker uses).
    private func usageString() -> String {
        let history = engine.history
        guard !history.isEmpty else { return "" }
        let bytes = history.reduce(0) { $0 + $1.snapshot.totalBytes }
        let n = history.count
        return "\(n) clip\(n == 1 ? "" : "s") · \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))"
    }

    private func makeModel() -> PickerModel {
        let m = PickerModel(
            onPickHistory: { [weak self] hash in self?.engine.applyHistory(hash: hash); self?.hide() },
            onPullPeer:    { [weak self] id in self?.engine.pull(from: id); self?.hide() },
            onDropFiles:   { [weak self] urls in self?.handleDrop(urls) },
            // Deleting keeps the picker open (you may be pruning several).
            onDeleteHistory: { [weak self] hash in
                self?.engine.deleteHistory(hash: hash)
                self?.refreshIfVisible()
            },
            onClose:       { [weak self] in self?.hide() })
        m.collapsed = Set(config.collapsedGroups)   // restore fold state across relaunches
        m.onCollapsedChange = { [weak self] set in self?.config.collapsedGroups = set.sorted() }
        return m
    }

    /// Share dropped files and surface the outcome in the picker. Kept here (not
    /// in the model) so the messaging can consult config/engine state.
    private func handleDrop(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard config.role.canSend else {
            model?.flashDrop("This Mac is receive-only — can’t share.")
            return
        }
        let n = engine.shareFiles(urls)
        if n > 0 {
            model?.flashDrop("Shared \(urls.count) file\(urls.count == 1 ? "" : "s") to \(n) Mac\(n == 1 ? "" : "s")")
        } else {
            model?.flashDrop("No connected Macs to share with")
        }
        refreshIfVisible()
    }
}

// MARK: - Model

final class PickerModel: ObservableObject {
    /// Quick content-type filter for the RECENT list.
    enum ContentFilter: String, CaseIterable, Identifiable {
        case all, text, image, file
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .all:   return "square.grid.2x2"
            case .text:  return "textformat"
            case .image: return "photo"
            case .file:  return "doc"
            }
        }
        var label: String {
            switch self {
            case .all: return "All"; case .text: return "Text"
            case .image: return "Images"; case .file: return "Files"
            }
        }
        func matches(_ item: HistoryItem) -> Bool {
            switch self {
            case .all:   return true
            case .text:  return item.kindLabel == "text" || item.kindLabel == "rich text"
            case .image: return item.kindLabel == "image"
            case .file:  return item.kindLabel == "file" || item.kindLabel.hasSuffix("files")
            }
        }
    }

    @Published var query = ""
    @Published var selection = 0
    @Published var kindFilter: ContentFilter = .all { didSet { selection = 0 } }
    /// Source Macs whose group is folded up. Survives reopen (reload() leaves it
    /// alone) and relaunch: the controller seeds it from config and persists
    /// every change back.
    @Published var collapsed: Set<String> = []
    /// Called on every fold/unfold so the owner can persist the new state.
    var onCollapsedChange: ((Set<String>) -> Void)?
    @Published private(set) var items: [HistoryItem] = []
    @Published private(set) var peers: [(id: String, clip: PeerClip)] = []
    @Published private(set) var clipUsage = ""   // current clipboard "kind · size"
    @Published private(set) var dropMessage: String?   // transient toast after a drop

    let onPickHistory: (String) -> Void
    let onPullPeer: (String) -> Void
    let onDropFiles: ([URL]) -> Void
    let onDeleteHistory: (String) -> Void
    let onClose: () -> Void

    private var dropClear: DispatchWorkItem?

    init(onPickHistory: @escaping (String) -> Void,
         onPullPeer: @escaping (String) -> Void,
         onDropFiles: @escaping ([URL]) -> Void,
         onDeleteHistory: @escaping (String) -> Void,
         onClose: @escaping () -> Void) {
        self.onPickHistory = onPickHistory
        self.onPullPeer = onPullPeer
        self.onDropFiles = onDropFiles
        self.onDeleteHistory = onDeleteHistory
        self.onClose = onClose
    }

    /// Briefly show a status line after a drop, then clear it.
    func flashDrop(_ message: String) {
        dropMessage = message
        dropClear?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dropMessage = nil }
        dropClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    /// Full reset (on open).
    func reload(history: [HistoryItem], peers: [(id: String, clip: PeerClip)], showCount: Int, clipUsage: String) {
        query = ""; selection = 0
        refresh(history: history, peers: peers, showCount: showCount, clipUsage: clipUsage)
    }

    /// Live update while open — preserves query + clamps selection. Only mutates
    /// @Published state when something actually changed, so a burst of peer
    /// announcements can't re-render the list on a loop (which flickered).
    func refresh(history: [HistoryItem], peers: [(id: String, clip: PeerClip)], showCount: Int, clipUsage: String) {
        let newItems = Array(history.prefix(max(showCount, 1)))
        if !Self.sameItems(newItems, items) { items = newItems }
        let newPeers = peers.filter { $0.clip.online }
        if !Self.samePeers(newPeers, self.peers) { self.peers = newPeers }
        if clipUsage != self.clipUsage { self.clipUsage = clipUsage }
        let clamped = max(0, filtered.count - 1)
        if selection > clamped { selection = clamped }
    }

    private static func sameItems(_ a: [HistoryItem], _ b: [HistoryItem]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0.hash == $1.hash }
    }
    private static func samePeers(_ a: [(id: String, clip: PeerClip)], _ b: [(id: String, clip: PeerClip)]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy {
            $0.id == $1.id && $0.clip.online == $1.clip.online
                && $0.clip.hash == $1.clip.hash && $0.clip.size == $1.clip.size
        }
    }

    /// One per-Mac section of the list. `entries` is empty when collapsed; the
    /// badge counts always reflect what the group holds under the current
    /// query/kind filter, so a folded group still shows what's inside.
    struct Group {
        let source: String
        let isCollapsed: Bool
        /// (SF Symbol, count) per content kind, zero-count kinds omitted.
        let badges: [(symbol: String, count: Int)]
        let entries: [(index: Int, item: HistoryItem)]
    }

    /// Query/kind-filtered clips in **display order**: grouped by source Mac
    /// (groups and items each in first-seen/recency order).
    private var displayBase: (order: [String], map: [String: [HistoryItem]]) {
        var order: [String] = []
        var map: [String: [HistoryItem]] = [:]
        for it in items where kindFilter.matches(it) && matchesQuery(it) {
            if map[it.source] == nil { order.append(it.source) }
            map[it.source, default: []].append(it)
        }
        return (order, map)
    }

    /// The **visible** rows in on-screen top-to-bottom order — collapsed groups
    /// contribute nothing. Flat indices into this array drive arrow navigation,
    /// the selection highlight, and ⌘1–9, so all three agree with the screen.
    var filtered: [HistoryItem] {
        let base = displayBase
        return base.order.flatMap { collapsed.contains($0) ? [] : base.map[$0]! }
    }

    private func matchesQuery(_ it: HistoryItem) -> Bool {
        query.isEmpty
            || it.label.localizedCaseInsensitiveContains(query)
            || it.source.localizedCaseInsensitiveContains(query)
    }

    /// All per-Mac sections (collapsed ones included, for their header + badge),
    /// expanded entries carrying their flat index into `filtered`.
    var grouped: [Group] {
        let base = displayBase
        var flat = 0
        return base.order.map { src in
            let its = base.map[src]!
            let folded = collapsed.contains(src)
            var entries: [(index: Int, item: HistoryItem)] = []
            if !folded {
                entries = its.map { let e = (index: flat, item: $0); flat += 1; return e }
            }
            return Group(source: src, isCollapsed: folded, badges: Self.badges(for: its), entries: entries)
        }
    }

    func toggleGroup(_ source: String) {
        if collapsed.contains(source) { collapsed.remove(source) } else { collapsed.insert(source) }
        selection = min(selection, max(0, filtered.count - 1))
        onCollapsedChange?(collapsed)
    }

    /// Per-kind counts for a group's items. Finer-grained than the filter
    /// chips: plain and rich text get separate badges, using the same symbols
    /// as the row icons so the two stay visually consistent.
    private static func badges(for items: [HistoryItem]) -> [(symbol: String, count: Int)] {
        let kinds: [(symbol: String, matches: (String) -> Bool)] = [
            ("text.alignleft", { $0 == "text" }),
            ("textformat",     { $0 == "rich text" }),
            ("photo",          { $0 == "image" }),
            ("doc",            { $0 == "file" || $0.hasSuffix("files") }),
        ]
        return kinds.compactMap { kind in
            let n = items.filter { kind.matches($0.kindLabel) }.count
            return n > 0 ? (kind.symbol, n) : nil
        }
    }

    // Keyboard actions (driven by KeyCatcher).
    func move(_ delta: Int) {
        let n = filtered.count
        guard n > 0 else { return }
        selection = (selection + delta + n) % n
    }
    func pickSelected() {
        let f = filtered
        guard f.indices.contains(selection) else { return }
        onPickHistory(f[selection].hash)
    }
    func pickIndex(_ i: Int) {
        let f = filtered
        if f.indices.contains(i) { onPickHistory(f[i].hash) }
    }
    func deleteSelected() {
        let f = filtered
        guard f.indices.contains(selection) else { return }
        onDeleteHistory(f[selection].hash)
    }
    func type(_ s: String) { query += s; selection = 0 }
    func backspace() { if !query.isEmpty { query.removeLast(); selection = 0 } }
}

// MARK: - Key handling (works on macOS 13; avoids a focused TextField stealing arrows)

struct KeyCatcher: NSViewRepresentable {
    let model: PickerModel
    func makeNSView(context: Context) -> NSView {
        let v = CatcherView(); v.model = model
        DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let w = nsView.window, w.firstResponder !== nsView else { return }
            w.makeFirstResponder(nsView)
        }
    }
    final class CatcherView: NSView {
        weak var model: PickerModel?
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with e: NSEvent) {
            guard let m = model else { return super.keyDown(with: e) }
            switch e.keyCode {
            case 53: m.onClose()                    // esc
            case 36, 76: m.pickSelected()           // return / enter
            case 125: m.move(1)                     // down
            case 126: m.move(-1)                    // up
            case 51, 117:                           // delete: ⌘ removes the clip, plain edits the query
                if e.modifierFlags.contains(.command) { m.deleteSelected() } else { m.backspace() }
            default:
                if e.modifierFlags.contains(.command), let c = e.charactersIgnoringModifiers,
                   let n = Int(c), n >= 1, n <= 9 {  // ⌘1–9 quick pick
                    m.pickIndex(n - 1); return
                }
                if let s = e.characters, !s.isEmpty, s.first!.isLetter || s.first!.isNumber
                    || s.first! == " " || s.first!.isPunctuation {
                    m.type(s)
                }
            }
        }
    }
}

// MARK: - View

extension View {
    /// Show the pointing-hand (link) cursor while hovering a clickable row.
    func handCursorOnHover() -> some View {
        onHover { inside in inside ? NSCursor.pointingHand.push() : NSCursor.pop() }
    }
}

struct PickerView: View {
    @ObservedObject var model: PickerModel
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary).font(.system(size: 11))
                HStack(spacing: 1) {
                    Text(model.query.isEmpty ? "Search clips…" : model.query)
                        .font(.system(size: 12.5))
                        .foregroundColor(model.query.isEmpty ? .secondary : .primary)
                    SearchCaret()
                }
                Spacer(minLength: 8)
                ForEach(PickerModel.ContentFilter.allCases) { f in filterChip(f) }
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 11)
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.iBeam.push() } else { NSCursor.pop() } }
            Divider()

            ScrollViewReader { proxy in
             ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if !model.peers.isEmpty {
                        sectionHeader("GRAB A MAC’S CLIPBOARD")
                        ForEach(model.peers, id: \.id) { peer in
                            PeerRow(clip: peer.clip).contentShape(Rectangle())
                                .onTapGesture { model.onPullPeer(peer.id) }
                                .handCursorOnHover()
                        }
                        Spacer().frame(height: 8)
                    }
                    sectionHeader("RECENT")
                    if model.grouped.isEmpty {
                        Text(model.query.isEmpty ? "No clips yet — copy something, or drop files here to share." : "No matches.")
                            .foregroundColor(.secondary).font(.callout).padding(.horizontal, 14).padding(.vertical, 10)
                    } else {
                        // Grouped by source Mac; headers fold/unfold their group.
                        ForEach(model.grouped, id: \.source) { group in
                            groupHeader(group)
                            ForEach(group.entries, id: \.item.id) { e in
                                HistoryRow(item: e.item, index: e.index, selected: e.index == model.selection,
                                           onDelete: { model.onDeleteHistory(e.item.hash) })
                                    .contentShape(Rectangle())
                                    .onTapGesture { model.onPickHistory(e.item.hash) }
                                    .handCursorOnHover()
                            }
                        }
                    }
                }
                .padding(.vertical, 6)
             }
             .onChange(of: model.selection) { sel in
                 let f = model.filtered
                 guard f.indices.contains(sel) else { return }
                 withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(f[sel].id, anchor: .center) }
             }
            }

            Divider()
            HStack(spacing: 14) {
                hint("↑↓", "navigate"); hint("⏎", "use"); hint("⌘1–9", "quick"); hint("⌘⌫", "delete"); hint("⎋", "close")
                Spacer()
                if !model.clipUsage.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.clipboard").font(.system(size: 9))
                        Text(model.clipUsage).font(.system(size: 10))
                    }
                    .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .frame(minWidth: 380, minHeight: 320)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: .top)   // don't reserve the title-bar gap above search
        .background(KeyCatcher(model: model).frame(width: 0, height: 0))
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
            Self.loadFileURLs(from: providers) { model.onDropFiles($0) }
            return true
        }
        .overlay { if dropTargeted { dropOverlay } }
        .overlay(alignment: .bottom) { if let msg = model.dropMessage { dropToast(msg) } }
        .animation(.easeOut(duration: 0.15), value: dropTargeted)
        .animation(.easeOut(duration: 0.15), value: model.dropMessage)
    }

    /// Full-panel affordance shown while files are dragged over the picker.
    private var dropOverlay: some View {
        ZStack {
            Color.accentColor.opacity(0.08)
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                .foregroundColor(.accentColor.opacity(0.6))
                .padding(6)
            VStack(spacing: 9) {
                Image(systemName: "arrow.up.doc.on.clipboard").font(.system(size: 27))
                Text("Drop to share with your Macs").font(.system(size: 13.5, weight: .medium))
            }
            .foregroundColor(.accentColor)
        }
        .allowsHitTesting(false)
    }

    /// Transient status line after a drop (shared to N Macs, or a reason nothing sent).
    private func dropToast(_ msg: String) -> some View {
        Text(msg)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(Color.accentColor.opacity(0.92)))
            .padding(.bottom, 44)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// Resolve dropped item providers to on-disk file URLs, then call back on the
    /// main thread. Non-file drops (e.g. a text selection) resolve to nothing.
    private static func loadFileURLs(from providers: [NSItemProvider],
                                     _ completion: @escaping ([URL]) -> Void) {
        var urls: [URL] = []
        let lock = NSLock()
        let group = DispatchGroup()
        for p in providers {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL { lock.lock(); urls.append(url); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(urls) }
    }

    private func filterChip(_ f: PickerModel.ContentFilter) -> some View {
        let active = model.kindFilter == f
        return Button { model.kindFilter = f } label: {
            Image(systemName: f.symbol)
                .font(.system(size: 10, weight: active ? .semibold : .regular))
                .foregroundColor(active ? .white : .secondary)
                .frame(width: 22, height: 17)
                .background(active ? Color.accentColor : Color.secondary.opacity(0.12))
                .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .help(f.label)
    }

    /// Per-Mac group header: fold chevron, source name, and per-kind count
    /// badges. Clicking anywhere on it folds/unfolds the group.
    private func groupHeader(_ group: PickerModel.Group) -> some View {
        HStack(spacing: 6) {
            Image(systemName: group.isCollapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(.secondary.opacity(0.8))
                .frame(width: 9)
            Text(group.source).font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
            ForEach(group.badges, id: \.symbol) { badge in
                HStack(spacing: 3) {
                    Image(systemName: badge.symbol).font(.system(size: 8.5))
                    Text("\(badge.count)").font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                }
                .foregroundColor(.secondary)
                .padding(.horizontal, 5).padding(.vertical, 1.5)
                .background(Capsule().fill(Color.secondary.opacity(0.12)))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 1)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeOut(duration: 0.12)) { model.toggleGroup(group.source) } }
        .handCursorOnHover()
    }

    private func sectionHeader(_ t: String) -> some View {
        Text(t).font(.system(size: 10.5, weight: .semibold)).tracking(0.6)
            .foregroundColor(.secondary).padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 2)
    }
    private func hint(_ k: String, _ t: String) -> some View {
        HStack(spacing: 4) {
            Text(k).font(.system(size: 10, design: .monospaced)).padding(.horizontal, 4).padding(.vertical, 1)
                .background(Color.secondary.opacity(0.15)).cornerRadius(3)
            Text(t).font(.system(size: 10)).foregroundColor(.secondary)
        }
    }
}

/// Static (non-blinking) caret. A blinking caret drove a 0.55s timer that
/// re-rendered the picker and made the list flicker; a steady bar avoids that.
private struct SearchCaret: View {
    var body: some View {
        Rectangle().fill(Color.accentColor.opacity(0.8)).frame(width: 1.5, height: 14)
    }
}

private struct HistoryRow: View {
    let item: HistoryItem
    let index: Int
    let selected: Bool
    let onDelete: () -> Void
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 10) {
            thumb
            VStack(alignment: .leading, spacing: 2) {
                Text(item.label.isEmpty ? item.kindLabel : item.label).lineLimit(1).font(.system(size: 13))
                HStack(spacing: 6) {
                    Text(item.source).font(.system(size: 10.5)).foregroundColor(.secondary)
                    Text("·").foregroundColor(.secondary)
                    Text(age(item.timestamp)).font(.system(size: 10.5)).foregroundColor(.secondary)
                }
            }
            Spacer()
            if hovering {
                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Delete from history on all Macs")
            } else if index < 9 {
                Text("⌘\(index + 1)").font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary.opacity(0.7))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(selected ? Color.accentColor.opacity(0.22) : Color.clear)
        .cornerRadius(6).padding(.horizontal, 6)
        .onHover { hovering = $0 }
    }
    @ViewBuilder private var thumb: some View {
        if let d = item.imageData, let img = NSImage(data: d) {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                .frame(width: 30, height: 30).clipShape(RoundedRectangle(cornerRadius: 5))
        } else {
            Image(systemName: icon(item.kindLabel)).frame(width: 30, height: 30)
                .background(Color.secondary.opacity(0.12)).cornerRadius(5).foregroundColor(.secondary)
        }
    }
}

private struct PeerRow: View {
    let clip: PeerClip
    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Color.green).frame(width: 7, height: 7)
            Text(clip.name).font(.system(size: 13))
            Spacer()
            if let k = clip.kindLabel { Text(k).font(.system(size: 10.5)).foregroundColor(.secondary) }
            if let s = clip.size { Text(ByteCountFormatter.string(fromByteCount: Int64(s), countStyle: .file))
                .font(.system(size: 10.5)).foregroundColor(.secondary) }
            Image(systemName: "arrow.down.circle").foregroundColor(.secondary).font(.system(size: 12))
        }
        .padding(.horizontal, 14).padding(.vertical, 7).padding(.horizontal, 6)
    }
}

private func icon(_ kind: String) -> String {
    if kind == "image" { return "photo" }
    if kind == "rich text" { return "textformat" }
    if kind == "file" || kind.hasSuffix("files") { return "doc" }
    return "text.alignleft"
}
private func age(_ ts: Double) -> String {
    let s = Int(Date().timeIntervalSince1970 - ts)
    if s < 5 { return "just now" }; if s < 60 { return "\(s)s ago" }
    if s < 3600 { return "\(s/60)m ago" }; return "\(s/3600)h ago"
}

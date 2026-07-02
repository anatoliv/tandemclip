import AppKit
import SwiftUI

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
        model.reload(history: engine.history, peers: engine.sortedPeers(), showCount: config.pickerShowCount)

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
        model.refresh(history: engine.history, peers: engine.sortedPeers(), showCount: config.pickerShowCount)
    }

    func hide() { panel?.orderOut(nil) }

    private func makeModel() -> PickerModel {
        PickerModel(
            onPickHistory: { [weak self] hash in self?.engine.applyHistory(hash: hash); self?.hide() },
            onPullPeer:    { [weak self] id in self?.engine.pull(from: id); self?.hide() },
            onClose:       { [weak self] in self?.hide() })
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
    @Published private(set) var items: [HistoryItem] = []
    @Published private(set) var peers: [(id: String, clip: PeerClip)] = []

    let onPickHistory: (String) -> Void
    let onPullPeer: (String) -> Void
    let onClose: () -> Void

    init(onPickHistory: @escaping (String) -> Void,
         onPullPeer: @escaping (String) -> Void,
         onClose: @escaping () -> Void) {
        self.onPickHistory = onPickHistory
        self.onPullPeer = onPullPeer
        self.onClose = onClose
    }

    /// Full reset (on open).
    func reload(history: [HistoryItem], peers: [(id: String, clip: PeerClip)], showCount: Int) {
        query = ""; selection = 0
        refresh(history: history, peers: peers, showCount: showCount)
    }

    /// Live update while open — preserves query + clamps selection.
    func refresh(history: [HistoryItem], peers: [(id: String, clip: PeerClip)], showCount: Int) {
        items = Array(history.prefix(max(showCount, 1)))
        self.peers = peers.filter { $0.clip.online }
        if selection >= filtered.count { selection = max(0, filtered.count - 1) }
    }

    /// Query-filtered clips in **display order**: grouped by source Mac (groups
    /// and items each in first-seen/recency order). Flat indices into this array
    /// therefore match the on-screen top-to-bottom order, so arrow navigation,
    /// the selection highlight, and ⌘1–9 all agree.
    var filtered: [HistoryItem] {
        let base = items.filter { kindFilter.matches($0) && matchesQuery($0) }
        var order: [String] = []
        var map: [String: [HistoryItem]] = [:]
        for it in base {
            if map[it.source] == nil { order.append(it.source) }
            map[it.source, default: []].append(it)
        }
        return order.flatMap { map[$0]! }
    }

    private func matchesQuery(_ it: HistoryItem) -> Bool {
        query.isEmpty
            || it.label.localizedCaseInsensitiveContains(query)
            || it.source.localizedCaseInsensitiveContains(query)
    }

    /// The display-ordered `filtered` list carved into per-Mac sections, each
    /// entry carrying its flat index (for selection highlight + ⌘1–9).
    var grouped: [(source: String, entries: [(index: Int, item: HistoryItem)])] {
        var order: [String] = []
        var map: [String: [(Int, HistoryItem)]] = [:]
        for (i, it) in filtered.enumerated() {
            if map[it.source] == nil { order.append(it.source) }
            map[it.source, default: []].append((i, it))
        }
        return order.map { src in (src, map[src]!.map { (index: $0.0, item: $0.1) }) }
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
            case 51, 117: m.backspace()             // delete
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

struct PickerView: View {
    @ObservedObject var model: PickerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary).font(.system(size: 12))
                HStack(spacing: 1) {
                    Text(model.query.isEmpty ? "Search clips…" : model.query)
                        .font(.system(size: 13))
                        .foregroundColor(model.query.isEmpty ? .secondary : .primary)
                    SearchCaret()
                }
                Spacer(minLength: 8)
                ForEach(PickerModel.ContentFilter.allCases) { f in filterChip(f) }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
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
                        }
                        Spacer().frame(height: 8)
                    }
                    sectionHeader("RECENT")
                    if model.filtered.isEmpty {
                        Text(model.query.isEmpty ? "No clips yet — copy something." : "No matches.")
                            .foregroundColor(.secondary).font(.callout).padding(.horizontal, 14).padding(.vertical, 10)
                    } else {
                        // Grouped by source Mac.
                        ForEach(model.grouped, id: \.source) { group in
                            HStack(spacing: 6) {
                                Circle().fill(Color.secondary.opacity(0.5)).frame(width: 5, height: 5)
                                Text(group.source).font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 1)
                            ForEach(group.entries, id: \.item.id) { e in
                                HistoryRow(item: e.item, index: e.index, selected: e.index == model.selection)
                                    .contentShape(Rectangle())
                                    .onTapGesture { model.onPickHistory(e.item.hash) }
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
                hint("↑↓", "navigate"); hint("⏎", "use"); hint("⌘1–9", "quick"); hint("⎋", "close")
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .frame(minWidth: 380, minHeight: 320)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(KeyCatcher(model: model).frame(width: 0, height: 0))
    }

    private func filterChip(_ f: PickerModel.ContentFilter) -> some View {
        let active = model.kindFilter == f
        return Button { model.kindFilter = f } label: {
            Image(systemName: f.symbol)
                .font(.system(size: 11, weight: active ? .semibold : .regular))
                .foregroundColor(active ? .white : .secondary)
                .frame(width: 24, height: 20)
                .background(active ? Color.accentColor : Color.secondary.opacity(0.12))
                .cornerRadius(5)
        }
        .buttonStyle(.plain)
        .help(f.label)
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

/// Isolated so its 0.55s blink re-renders only the caret — not the whole
/// picker (which caused the list to flicker while the search was open).
private struct SearchCaret: View {
    @State private var on = true
    var body: some View {
        Rectangle().fill(Color.accentColor).frame(width: 1.5, height: 15)
            .opacity(on ? 1 : 0)
            .onReceive(Timer.publish(every: 0.55, on: .main, in: .common).autoconnect()) { _ in on.toggle() }
    }
}

private struct HistoryRow: View {
    let item: HistoryItem
    let index: Int
    let selected: Bool
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
            if index < 9 {
                Text("⌘\(index + 1)").font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary.opacity(0.7))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(selected ? Color.accentColor.opacity(0.22) : Color.clear)
        .cornerRadius(6).padding(.horizontal, 6)
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

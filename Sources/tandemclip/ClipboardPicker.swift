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
            let p = PickerPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 440),
                                styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            p.titleVisibility = .hidden
            p.titlebarAppearsTransparent = true
            p.isMovableByWindowBackground = true
            p.level = .floating
            // Appear over fullscreen apps and on every Space — you summon the
            // picker from anywhere, including a fullscreen editor/terminal.
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.standardWindowButton(.closeButton)?.isHidden = true
            p.standardWindowButton(.miniaturizeButton)?.isHidden = true
            p.standardWindowButton(.zoomButton)?.isHidden = true
            p.contentView = NSHostingView(rootView: PickerView(model: model))
            panel = p
        }
        panel?.center()
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
        panel?.orderFrontRegardless()
        Log.trace("picker", "shown; visible=\(panel?.isVisible ?? false)")
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
    @Published var query = ""
    @Published var selection = 0
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

    func reload(history: [HistoryItem], peers: [(id: String, clip: PeerClip)], showCount: Int) {
        items = Array(history.prefix(max(showCount, 1)))
        self.peers = peers.filter { $0.clip.online }
        query = ""
        selection = 0
    }

    var filtered: [HistoryItem] {
        query.isEmpty ? items
            : items.filter { $0.label.localizedCaseInsensitiveContains(query) || $0.source.localizedCaseInsensitiveContains(query) }
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
        DispatchQueue.main.async { nsView.window?.makeFirstResponder(nsView) }
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
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                Text(model.query.isEmpty ? "Search clips…" : model.query)
                    .foregroundColor(model.query.isEmpty ? .secondary : .primary)
                Spacer()
                Image(systemName: "arrow.triangle.2.circlepath").foregroundColor(.secondary).font(.system(size: 12))
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            Divider()

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
                    let f = model.filtered
                    if f.isEmpty {
                        Text(model.query.isEmpty ? "No clips yet — copy something." : "No matches.")
                            .foregroundColor(.secondary).font(.callout).padding(.horizontal, 14).padding(.vertical, 10)
                    } else {
                        ForEach(Array(f.enumerated()), id: \.element.id) { idx, item in
                            HistoryRow(item: item, index: idx, selected: idx == model.selection)
                                .contentShape(Rectangle())
                                .onTapGesture { model.onPickHistory(item.hash) }
                        }
                    }
                }
                .padding(.vertical, 6)
            }

            Divider()
            HStack(spacing: 14) {
                hint("↑↓", "navigate"); hint("⏎", "use"); hint("⌘1–9", "quick"); hint("⎋", "close")
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .frame(width: 480, height: 440)
        .background(KeyCatcher(model: model).frame(width: 0, height: 0))
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

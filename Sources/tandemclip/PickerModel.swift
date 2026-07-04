import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Model

final class PickerModel: ObservableObject {
    /// Quick content-type filter for the RECENT list.
    enum ContentFilter: String, CaseIterable, Identifiable {
        case all, text, image, document, media, file
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .all:      return "square.grid.2x2"
            case .text:     return "textformat"
            case .image:    return "photo"
            case .document: return "doc.text"
            case .media:    return "play.rectangle"
            case .file:     return "shippingbox"
            }
        }
        var label: String {
            switch self {
            case .all: return "All"; case .text: return "Text"
            case .image: return "Images"; case .document: return "Documents"
            case .media: return "Audio & Video"; case .file: return "Files"
            }
        }
        func matches(_ item: HistoryItem) -> Bool {
            switch self {
            case .all:      return true
            case .text:     return item.category == .text || item.category == .richText
            case .image:    return item.category == .image      // includes picture files
            case .document: return item.category == .document   // PDF / Office / text-like files
            case .media:    return item.category == .audio || item.category == .video
            case .file:     return item.category == .file       // archives, binaries, the rest
            }
        }
    }

    @Published var query = "" { didSet { if query != oldValue { recomputeSemantic() } } }
    @Published var selection = 0
    /// Bumped when the on-device index (embeddings/OCR) learns something new,
    /// so computed search results re-render live.
    @Published var indexRevision = 0

    /// Injected by the controller (ClipIndex-backed). Nil in tests → keyword only.
    var semanticLookup: ((String) -> Set<String>)?
    var ocrLookup: ((String) -> String?)?
    private var semanticHashes: Set<String> = []

    func recomputeSemantic() {
        semanticHashes = query.count >= 3 ? (semanticLookup?(query) ?? []) : []
    }
    @Published var kindFilter: ContentFilter = .all { didSet { selection = 0 } }
    /// Source Macs whose group is folded up. Survives reopen (reload() leaves it
    /// alone) and relaunch: the controller seeds it from config and persists
    /// every change back.
    @Published var collapsed: Set<String> = []
    /// Folded per-type sub-sections within expanded groups, keyed by
    /// `subKey(source, title)`. Same lifecycle as `collapsed`.
    @Published var collapsedSubs: Set<String> = []
    /// Called on every fold/unfold (groups, sub-sections) so the owner can
    /// persist the new state.
    var onCollapsedChange: ((_ groups: Set<String>, _ subs: Set<String>) -> Void)?

    /// Privacy hold — nothing of ours leaves this Mac while on (mirrors
    /// config.privacyHold; the controller seeds + persists it).
    @Published var privacyHold = false
    /// Pinned — the panel stays open after picking/pulling.
    @Published var pinned = false
    var onPrivacyChange: ((Bool) -> Void)?
    var onPinnedChange: ((Bool) -> Void)?

    func togglePrivacy() { privacyHold.toggle(); onPrivacyChange?(privacyHold) }
    func togglePin() { pinned.toggle(); onPinnedChange?(pinned) }

    // MARK: Compose + AI cleanup

    /// Compose mode swaps the list for a text area where the user can write or
    /// paste text, optionally run AI cleanup on it, then copy the result (which
    /// syncs like any local copy).
    @Published var composing = false
    @Published var composeText = ""
    @Published private(set) var composeBusy = false
    @Published private(set) var composeError: String?
    /// Pre-cleanup text, kept for one-tap Undo after an AI rewrite.
    @Published private(set) var composeOriginal: String?
    /// The model's one-line changelog (from the §§CHANGES§§ sentinel).
    @Published private(set) var composeChanges: String?

    /// Tone presets + the one applied by "Clean Up" (persisted via callback).
    @Published var presets: [AIPreset] = AIPreset.bundled
    @Published var selectedPresetID: String = "cleanup"
    var onPresetSelect: ((String) -> Void)?
    /// Whether AI is configured — gates the ✨ row action.
    @Published var aiConfigured = false
    /// AirDrop availability — gates the share row action.
    @Published var airDropAvailable = false
    var onAirDrop: ((HistoryItem) -> Void)?

    /// Pinned clips (persist + sync); displayed above RECENT.
    @Published var pinnedItems: [HistoryItem] = []
    var pinnedHashes: Set<String> { Set(pinnedItems.map(\.hash)) }
    var onPin: ((HistoryItem) -> Void)?
    var onUnpin: ((String) -> Void)?
    var onPickPinned: ((String) -> Void)?

    var selectedPreset: AIPreset {
        presets.first { $0.id == selectedPresetID } ?? presets.first ?? AIPreset.bundled[0]
    }

    func selectPreset(_ id: String) {
        selectedPresetID = id
        onPresetSelect?(id)
    }

    /// Provided by the controller: nil when AI isn't configured/enabled.
    var makeCleanupStream: ((String, AIPreset) -> AsyncThrowingStream<String, Error>?)?
    var onComposeCopy: ((String) -> Void)?
    private var cleanupTask: Task<Void, Never>?

    func startCompose() { composing = true; composeError = nil }

    /// Leaving compose (Back / Cancel / Esc / after Use) discards the draft —
    /// a fresh compose always starts empty. A click-away that merely hides the
    /// panel does NOT come through here, so an accidental defocus keeps the
    /// draft.
    func endCompose() {
        clearAsk()
        cleanupTask?.cancel()
        composeBusy = false
        composing = false
        composeText = ""
        composeOriginal = nil
        composeError = nil
        composeChanges = nil
    }

    /// ✨ on a history row: open compose with the clip's text and run the
    /// selected preset on it straight away.
    func cleanUpItem(_ item: HistoryItem) {
        guard let text = item.snapshot.plainText, !text.isEmpty else { return }
        composeText = text
        composeChanges = nil
        composeOriginal = nil
        startCompose()
        runCleanup()
    }

    /// Stream the AI rewrite into the editor (cumulative), hiding the
    /// changelog tail behind the sentinel. On failure the original
    /// text is restored — words are never lost.
    func runCleanup() {
        guard !composeBusy else { return }
        // Privacy hold promises nothing leaves this Mac — that includes the
        // AI endpoint, even a local one (keep the promise simple).
        guard !privacyHold else {
            composeError = "Privacy hold is on (✋) — AI calls are paused until you switch it off."
            return
        }
        let input = composeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        guard let stream = makeCleanupStream?(input, selectedPreset) else {
            composeError = "Set up AI cleanup in Settings → AI first."
            return
        }
        composeOriginal = composeText
        composeBusy = true
        composeError = nil
        composeChanges = nil
        cleanupTask = Task { @MainActor [weak self] in
            var acc = ""
            do {
                for try await delta in stream {
                    guard let self, self.composing else { return }
                    acc += delta
                    self.composeText = AIClient.splitChanges(acc).body
                }
                if acc.isEmpty { throw AIClient.AIError.emptyResponse }
                let (body, changes) = AIClient.splitChanges(acc)
                self?.composeText = body
                self?.composeChanges = changes
            } catch is CancellationError {
                self?.composeText = self?.composeOriginal ?? acc
            } catch {
                self?.composeError = AIClient.friendlyMessage(for: error)
                self?.composeText = self?.composeOriginal ?? acc
            }
            self?.composeBusy = false
        }
    }

    func undoCleanup() {
        guard let original = composeOriginal else { return }
        composeText = original
        composeOriginal = nil
        composeChanges = nil
    }

    /// Called after Use so the owner can close the panel (unless pinned).
    var onComposeDone: (() -> Void)?

    /// Accept the composed text: put it on the clipboard (it syncs like any
    /// local copy) and leave compose, mirroring what picking a clip does.
    func useCompose() {
        let text = composeText
        guard !text.isEmpty else { return }
        onComposeCopy?(text)
        endCompose()
        flashDrop("On the clipboard — syncs like any copy")
        onComposeDone?()
    }

    // MARK: Hover preview

    /// The row the pointer is dwelling on (drives the preview card). Hover is
    /// deliberately separate from `selection`: the keyboard selection stays
    /// where it is until the user picks something else.
    @Published private(set) var hoverItem: HistoryItem?
    private var hoverWork: DispatchWorkItem?
    private var hoverClear: DispatchWorkItem?
    /// True while the pointer is inside the preview card itself — the card is
    /// interactive (quick actions, copy-text, summarize), so leaving the row
    /// toward the card must not dismiss it.
    private var cardHovering = false

    /// Show the preview after a short dwell so it doesn't flash while the
    /// pointer travels across the list.
    func beginHover(_ item: HistoryItem) {
        hoverClear?.cancel()
        hoverWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hoverItem = item }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    func endHover(_ item: HistoryItem) {
        hoverWork?.cancel()
        scheduleHoverClear(matching: item.id)
    }

    func cardHover(_ inside: Bool) {
        cardHovering = inside
        if inside { hoverClear?.cancel() } else { scheduleHoverClear(matching: nil) }
    }

    /// Grace period before the card hides, so the pointer can travel from the
    /// row into the card without the card vanishing underneath it.
    private func scheduleHoverClear(matching id: String?) {
        hoverClear?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.cardHovering else { return }
            if id == nil || self.hoverItem?.id == id { self.hoverItem = nil }
        }
        hoverClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30, execute: work)
    }

    // MARK: Preview-card intelligence (OCR copy, quick actions, summaries)

    /// AI summaries by content hash (cached for the session).
    @Published private(set) var summaries: [String: String] = [:]
    @Published private(set) var summarizingHash: String?
    /// Controller-provided; nil when AI isn't configured.
    var makeSummaryStream: ((String) -> AsyncThrowingStream<String, Error>?)?
    /// Engine-owned auto-translations of incoming clips, by hash.
    var translationLookup: ((String) -> String?)?

    // MARK: Ask your clipboard (retrieval-grounded answers)

    @Published private(set) var askAnswer: String?
    @Published private(set) var askSources: [String] = []
    @Published private(set) var askBusy = false
    /// Controller-provided: builds the retrieval context + stream. Nil when AI
    /// isn't configured.
    var makeAskStream: ((String) -> (stream: AsyncThrowingStream<String, Error>, sources: [String])?)?
    private var askTask: Task<Void, Never>?

    /// Answer the composed question from clipboard history (+ pins), grounded
    /// in the top semantic matches.
    func askClipboard() {
        guard !askBusy, !composeBusy else { return }
        let question = composeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        guard !privacyHold else {
            composeError = "Privacy hold is on (✋) — AI calls are paused."
            return
        }
        guard let made = makeAskStream?(question) else {
            composeError = "Set up AI in Settings → AI first."
            return
        }
        askBusy = true
        composeError = nil
        askAnswer = ""
        askSources = made.sources
        askTask = Task { @MainActor [weak self] in
            var acc = ""
            do {
                for try await delta in made.stream {
                    guard let self, self.composing else { return }
                    acc += delta
                    self.askAnswer = acc
                }
            } catch {
                self?.composeError = AIClient.friendlyMessage(for: error)
                self?.askAnswer = nil
                self?.askSources = []
            }
            self?.askBusy = false
        }
    }

    func clearAsk() {
        askTask?.cancel()
        askAnswer = nil
        askSources = []
        askBusy = false
    }

    func summarize(_ item: HistoryItem) {
        guard summarizingHash == nil, summaries[item.hash] == nil,
              let text = item.snapshot.plainText else { return }
        guard !privacyHold else {
            flashDrop("Privacy hold is on (✋) — AI calls are paused.", isError: true)
            return
        }
        guard let stream = makeSummaryStream?(text) else {
            flashDrop("Set up AI in Settings → AI first.", isError: true)
            return
        }
        summarizingHash = item.hash
        Task { @MainActor [weak self] in
            var acc = ""
            do {
                for try await delta in stream { acc += delta }
                self?.summaries[item.hash] = acc.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                self?.flashDrop(AIClient.friendlyMessage(for: error), isError: true)
            }
            self?.summarizingHash = nil
        }
    }

    func copyText(_ text: String, toast: String) {
        onComposeCopy?(text)
        flashDrop(toast)
    }

    func runQuickAction(_ action: QuickAction, on item: HistoryItem) {
        if let note = action.perform(on: item) { flashDrop(note) }
    }

    /// Text excerpt for the preview card: the clip's own text, or the bytes of
    /// a single text-like document.
    static func previewText(_ item: HistoryItem) -> String? {
        if let t = item.snapshot.plainText, !t.isEmpty { return String(t.prefix(600)) }
        if item.snapshot.files.count == 1, let f = item.snapshot.files.first,
           ClipSnapshot.textLikeExtensions.contains((f.name as NSString).pathExtension.lowercased()),
           let s = String(data: f.data.prefix(4096), encoding: .utf8) {
            return String(s.prefix(600))
        }
        return nil
    }

    /// File list for the preview card (name + individual size).
    static func previewFiles(_ item: HistoryItem) -> [(name: String, size: Int)] {
        item.snapshot.files.map { ($0.name, $0.data.count) }
    }

    /// Unit separator keeps composite keys unambiguous even if a Mac's name
    /// contains punctuation.
    static func subKey(_ source: String, _ title: String) -> String { "\(source)\u{1F}\(title)" }
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

    /// Briefly show a status line after a drop/use, then clear it. Failures
    /// render neutral, never accent-colored — accent means success here.
    func flashDrop(_ message: String, isError: Bool = false) {
        dropMessage = message
        dropIsError = isError
        dropClear?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dropMessage = nil }
        dropClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }
    @Published private(set) var dropIsError = false

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
        if let h = hoverItem, !items.contains(where: { $0.hash == h.hash }) { hoverItem = nil }
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

    /// One per-Mac section of the list, carved into per-type sub-sections
    /// (Text / Images / Files — rich text lives with text). `sections` is empty
    /// when the group is collapsed; a collapsed *sub-section* keeps its header
    /// (with count) but has no entries. Badge/total counts always reflect what
    /// the group holds under the current query/kind filter, so folded things
    /// still show what's inside.
    struct Group {
        let source: String
        let isCollapsed: Bool
        /// All items in the group under the current filter (the total badge).
        let total: Int
        /// (SF Symbol, count) per content kind, zero-count kinds omitted.
        let badges: [(symbol: String, count: Int)]
        let sections: [Section]
        /// All rows regardless of sub-section, in display order.
        var entries: [(index: Int, item: HistoryItem)] { sections.flatMap(\.entries) }
    }

    struct Section {
        let title: String
        let isCollapsed: Bool
        let count: Int
        let entries: [(index: Int, item: HistoryItem)]
    }

    /// Sub-section rank/title within a Mac group. Recency is preserved inside
    /// each sub-section.
    private static func section(of item: HistoryItem) -> (rank: Int, title: String) {
        switch item.category {
        case .text, .richText: return (0, "Text")
        case .image:           return (1, "Images")
        case .document:        return (2, "Documents")
        case .audio:           return (3, "Audio")
        case .video:           return (4, "Video")
        case .file:            return (5, "Files")
        }
    }

    /// Query/kind-filtered clips in **display order**: grouped by source Mac
    /// (groups in first-seen/recency order), each group's items ordered by
    /// sub-section then recency.
    private var displayBase: (order: [String], map: [String: [HistoryItem]]) {
        var order: [String] = []
        var map: [String: [HistoryItem]] = [:]
        for it in items where kindFilter.matches(it) && matchesQuery(it) {
            if map[it.source] == nil { order.append(it.source) }
            map[it.source, default: []].append(it)
        }
        // Stable sort into sub-section order (sort() alone isn't stable).
        for (src, its) in map {
            map[src] = its.enumerated()
                .sorted { (Self.section(of: $0.element).rank, $0.offset)
                        < (Self.section(of: $1.element).rank, $1.offset) }
                .map(\.element)
        }
        return (order, map)
    }

    /// The **visible** rows in on-screen top-to-bottom order — collapsed groups
    /// and collapsed sub-sections contribute nothing. Flat indices into this
    /// array drive arrow navigation, the selection highlight, and ⌘1–9, so all
    /// three agree with the screen.
    var filtered: [HistoryItem] {
        let base = displayBase
        return base.order.flatMap { src in
            collapsed.contains(src) ? [] : base.map[src]!.filter {
                !collapsedSubs.contains(Self.subKey(src, Self.section(of: $0).title))
            }
        }
    }

    private func matchesQuery(_ it: HistoryItem) -> Bool {
        if query.isEmpty { return true }
        if it.label.localizedCaseInsensitiveContains(query) { return true }
        if it.source.localizedCaseInsensitiveContains(query) { return true }
        // Full text of text clips (label only carries the first 64 chars).
        if let body = it.snapshot.plainText, body.localizedCaseInsensitiveContains(query) { return true }
        // Text recognized inside image clips (on-device OCR).
        if let ocr = ocrLookup?(it.hash), ocr.localizedCaseInsensitiveContains(query) { return true }
        // Meaning, not just words (on-device embeddings).
        return semanticHashes.contains(it.hash)
    }

    /// All per-Mac sections (collapsed ones included, for their header + badge),
    /// expanded entries carrying their flat index into `filtered`.
    var grouped: [Group] {
        let base = displayBase
        var flat = 0
        return base.order.map { src in
            let its = base.map[src]!
            let folded = collapsed.contains(src)
            var sections: [Section] = []
            if !folded {
                // Items arrive pre-sorted by section, so consecutive runs of one
                // title form that title's sub-section.
                var runs: [(title: String, items: [HistoryItem])] = []
                for it in its {
                    let title = Self.section(of: it).title
                    if runs.last?.title != title { runs.append((title, [])) }
                    runs[runs.count - 1].items.append(it)
                }
                sections = runs.map { run in
                    let subFolded = collapsedSubs.contains(Self.subKey(src, run.title))
                    var entries: [(index: Int, item: HistoryItem)] = []
                    if !subFolded {
                        entries = run.items.map { let e = (index: flat, item: $0); flat += 1; return e }
                    }
                    return Section(title: run.title, isCollapsed: subFolded,
                                   count: run.items.count, entries: entries)
                }
            }
            return Group(source: src, isCollapsed: folded, total: its.count,
                         badges: Self.badges(for: its), sections: sections)
        }
    }

    func toggleGroup(_ source: String) {
        if collapsed.contains(source) { collapsed.remove(source) } else { collapsed.insert(source) }
        collapseChanged()
    }

    func toggleSub(_ source: String, _ title: String) {
        let key = Self.subKey(source, title)
        if collapsedSubs.contains(key) { collapsedSubs.remove(key) } else { collapsedSubs.insert(key) }
        collapseChanged()
    }

    private func collapseChanged() {
        selection = min(selection, max(0, filtered.count - 1))
        onCollapsedChange?(collapsed, collapsedSubs)
    }

    /// Per-kind counts for a group's items. Finer-grained than the filter
    /// chips: plain and rich text get separate badges, using the same symbols
    /// as the row icons so the two stay visually consistent. Picture files
    /// count as images.
    private static func badges(for items: [HistoryItem]) -> [(symbol: String, count: Int)] {
        let kinds: [(symbol: String, category: ClipCategory)] = [
            ("text.alignleft", .text),
            ("textformat",     .richText),
            ("photo",          .image),
            ("doc.text",       .document),
            ("waveform",       .audio),
            ("film",           .video),
            ("shippingbox",    .file),
        ]
        return kinds.compactMap { kind in
            let n = items.filter { $0.category == kind.category }.count
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

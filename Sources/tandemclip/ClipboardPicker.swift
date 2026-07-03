import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Panel (borderless, can become key without activating everything)

final class PickerPanel: NSPanel {
    /// Esc fallback: when first responder is something other than the
    /// KeyCatcher (a just-clicked button, nothing at all), the unhandled Esc
    /// walks the responder chain and lands here instead of beeping.
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
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

    /// The app the user was in when they opened the picker — the paste
    /// destination, used to steer the AI rewrite's tone. Captured before we
    /// activate (activation would make us frontmost).
    private var frontAppBundleID: String?

    func toggle() { (panel?.isVisible ?? false) ? hide() : show() }

    func show() {
        frontAppBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let model = self.model ?? makeModel()
        self.model = model
        model.reload(history: engine.history, peers: engine.syncablePeers(),
                     showCount: config.pickerShowCount, clipUsage: usageString())
        model.presets = config.aiPresets
        model.selectedPresetID = config.aiSelectedPresetID
        model.aiConfigured = AIClient.fromConfig(config) != nil
        model.airDropAvailable = AirDropper.isAvailable
        model.pinnedItems = engine.pins.compactMap(\.historyItem)
        ClipIndex.shared.index(engine.history)

        if panel == nil {
            let p = PickerPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 520),
                                styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel, .resizable],
                                backing: .buffered, defer: false)
            p.titleVisibility = .hidden
            p.titlebarAppearsTransparent = true
            // Movable by the transparent title-bar strip only. NOT by the whole
            // background: that steals mouse-drag from the rows' .onDrag, breaking
            // drag-out (the window would slide instead of the clip lifting).
            p.isMovableByWindowBackground = false
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
            p.onCancel = { [weak self] in
                if self?.model?.composing == true { self?.model?.endCompose() }
                else if self?.model?.pinned != true { self?.hide() }
            }
            p.setFrameAutosaveName("TandemClipPicker")   // remember size + position
            if p.frame.origin == .zero { p.center() }     // first run only
            // Unpinned, the picker is a transient panel: clicking away (the
            // panel resigning key) dismisses it — which also guarantees Esc
            // works whenever the panel can hear keys at all. Pinned, it
            // floats until unpinned or toggled away. A compose draft survives
            // this hide (only Back/Cancel/Use clear it — see endCompose).
            NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: p, queue: .main
            ) { [weak self] _ in
                guard let self, self.model?.pinned != true else { return }
                self.hide()
            }
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
        model.pinnedItems = engine.pins.compactMap(\.historyItem)
        ClipIndex.shared.index(engine.history)
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
            // Pinned: stay open after picking/pulling (Esc still closes).
            onPickHistory: { [weak self] hash in
                self?.engine.applyHistory(hash: hash)
                self?.hideUnlessPinned()
            },
            onPullPeer: { [weak self] id in
                self?.engine.pull(from: id)
                self?.hideUnlessPinned()
            },
            onDropFiles:   { [weak self] urls in self?.handleDrop(urls) },
            // Deleting keeps the picker open (you may be pruning several).
            onDeleteHistory: { [weak self] hash in
                self?.engine.deleteHistory(hash: hash)
                self?.refreshIfVisible()
            },
            // Esc closes the picker — unless pinned (unpin or ⇧⌘V to close then).
            onClose:       { [weak self] in
                if self?.model?.pinned != true { self?.hide() }
            })
        // Restore fold state (groups + sub-sections) across relaunches.
        m.collapsed = Set(config.collapsedGroups)
        m.collapsedSubs = Set(config.collapsedSubgroups)
        m.onCollapsedChange = { [weak self] groups, subs in
            self?.config.collapsedGroups = groups.sorted()
            self?.config.collapsedSubgroups = subs.sorted()
        }
        wireClipIndex(m)
        m.translationLookup = { [weak self] hash in
            let t = self?.engine.translations[hash]
            return (t?.isEmpty ?? true) ? nil : t
        }
        // Privacy hold + pin: seeded from config, persisted on toggle.
        m.privacyHold = config.privacyHold
        m.pinned = config.pickerPinned
        m.onPrivacyChange = { [weak self] on in
            self?.config.privacyHold = on
            self?.engine.onStatusChange?()   // menu state line + icon update
        }
        m.onPinnedChange = { [weak self] on in self?.config.pickerPinned = on }
        m.onPin = { [weak self] item in
            guard let self else { return }
            if self.engine.pin(item) {
                self.model?.flashDrop("Pinned — synced to your Macs and kept past restarts")
            } else {
                self.model?.flashDrop("Too large to pin (over the clip size limit)", isError: true)
            }
            self.refreshIfVisible()
        }
        m.onUnpin = { [weak self] hash in
            self?.engine.unpin(hash: hash)
            self?.refreshIfVisible()
        }
        m.onPickPinned = { [weak self] hash in
            self?.engine.applyPinned(hash: hash)
            self?.hideUnlessPinned()
        }
        // AirDrop: hand the clip to the system sheet, then step aside (the
        // sheet is its own window; the picker closes unless pinned).
        m.onAirDrop = { [weak self] item in
            if AirDropper.shared.share(item) {
                self?.hideUnlessPinned()
            } else {
                self?.model?.flashDrop("Nothing AirDrop-able in this clip", isError: true)
            }
        }
        // Compose + AI cleanup: the stream factory returns nil when AI isn't
        // configured, which the model surfaces as a pointer to Settings → AI.
        // System prompt = tone preset + destination-app steer + changelog ask.
        m.makeCleanupStream = { [weak self] text, preset in
            guard let self, let client = AIClient.fromConfig(self.config) else { return nil }
            var system = preset.prompt
            if self.config.aiAutoTone,
               let tone = AIAutoTone.instruction(forBundleID: self.frontAppBundleID) {
                system += "\n\n" + tone
            }
            system += "\n\n" + AIClient.changesInstruction
            let capped = String(text.prefix(Config.aiMaxInputChars))
            return AIClient.streamWithFallback(
                primary: client,
                fallback: AIClient.fallbackFromConfig(self.config),
                messages: [.init(role: .system, content: system),
                           .init(role: .user, content: capped)])
        }
        m.onPresetSelect = { [weak self] id in self?.config.aiSelectedPresetID = id }
        // Ask: retrieve the top semantic matches (plus recency fallback) and
        // answer ONLY from them — a miniature of tonebox's Ask pane.
        m.makeAskStream = { [weak self] question in
            guard let self, let client = AIClient.fromConfig(self.config) else { return nil }
            var items = ClipIndex.shared.topMatches(for: question, limit: 5)
                .compactMap { match in self.engine.history.first { $0.hash == match.hash } }
            if items.count < 3 {
                for it in self.engine.history.prefix(6)
                where !items.contains(where: { $0.hash == it.hash }) { items.append(it) }
                items = Array(items.prefix(6))
            }
            guard !items.isEmpty else { return nil }
            let context = items.enumerated().map { i, it -> String in
                let body = it.snapshot.plainText ?? ClipIndex.shared.ocrText(for: it.hash) ?? it.label
                return "[\(i + 1)] from \(it.source): \(String(body.prefix(1500)))"
            }.joined(separator: "\n\n")
            let system = """
                You answer questions using ONLY the user's clipboard clips \
                provided below. If the answer is not in the clips, say so \
                plainly. Be brief and direct; cite clip numbers like [2] when \
                helpful. No preamble.
                """
            let stream = AIClient.streamWithFallback(
                primary: client, fallback: AIClient.fallbackFromConfig(self.config),
                messages: [.init(role: .system, content: system),
                           .init(role: .user, content: "QUESTION: \(question)\n\nCLIPS:\n\(context)")])
            return (stream, items.map { String($0.label.prefix(28)) })
        }

        // Preview-card summaries ride the Summarize preset (no auto-tone or
        // changelog — a summary is an annotation, not a rewrite).
        m.makeSummaryStream = { [weak self] text in
            guard let self, let client = AIClient.fromConfig(self.config) else { return nil }
            let prompt = self.config.aiPresets.first { $0.id == "summarize" }?.prompt
                ?? AIPreset.bundled[4].prompt
            let capped = String(text.prefix(Config.aiMaxInputChars))
            return AIClient.streamWithFallback(
                primary: client, fallback: AIClient.fallbackFromConfig(self.config),
                messages: [.init(role: .system, content: prompt),
                           .init(role: .user, content: capped)])
        }
        m.onComposeCopy = { text in
            // A plain local copy: the watcher captures it on the next poll and
            // it syncs (or not) exactly per the current mode/privacy settings.
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
        }
        // Using the composed text behaves like picking a clip: the panel
        // closes unless pinned.
        m.onComposeDone = { [weak self] in self?.hideUnlessPinned() }
        return m
    }

    /// Live re-render + fresh semantic results when the background index
    /// finishes a clip (embeddings or OCR).
    private func wireClipIndex(_ m: PickerModel) {
        m.semanticLookup = { ClipIndex.shared.semanticHashes(for: $0) }
        m.ocrLookup = { ClipIndex.shared.ocrText(for: $0) }
        ClipIndex.shared.onUpdate = { [weak self] in
            guard let self, let model = self.model else { return }
            model.recomputeSemantic()
            model.indexRevision += 1
        }
    }

    private func hideUnlessPinned() {
        if model?.pinned == true { refreshIfVisible() } else { hide() }
    }

    /// Share dropped files and surface the outcome in the picker. Kept here (not
    /// in the model) so the messaging can consult config/engine state.
    private func handleDrop(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard !config.privacyHold else {
            model?.flashDrop("Privacy hold is on — nothing is shared.", isError: true)
            return
        }
        guard config.role.canSend else {
            model?.flashDrop("This Mac is receive-only — can’t share.", isError: true)
            return
        }
        // Honest reporting: say what was actually sent, to how many Macs, and
        // why anything was skipped — no more "No connected Macs" when the real
        // problem was an oversized file.
        let outcome = engine.shareFiles(urls)
        if outcome.sent == 0 {
            model?.flashDrop(outcome.skipped > 0
                ? "Nothing sent — items were over the size limit or unreadable"
                : "No connected Macs to share with", isError: true)
        } else {
            var msg = "Shared \(outcome.sent) file\(outcome.sent == 1 ? "" : "s")"
            msg += outcome.peers > 0 ? " to \(outcome.peers) Mac\(outcome.peers == 1 ? "" : "s")" : " — no Macs connected right now"
            if outcome.skipped > 0 { msg += " · \(outcome.skipped) skipped (too large)" }
            model?.flashDrop(msg)
        }
        refreshIfVisible()
    }
}

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

    /// Stream the AI rewrite into the editor (cumulative, tonebox-style),
    /// hiding the changelog tail behind the sentinel. On failure the original
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

// MARK: - Key handling (works on macOS 13; avoids a focused TextField stealing arrows)

struct KeyCatcher: NSViewRepresentable {
    let model: PickerModel
    func makeNSView(context: Context) -> NSView {
        let v = CatcherView(); v.model = model
        DispatchQueue.main.async { if !model.composing { v.window?.makeFirstResponder(v) } }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            // Compose mode needs a real text editor: stop stealing focus, and
            // hand it back if we currently hold it.
            if model.composing {
                if nsView.window?.firstResponder === nsView { nsView.window?.makeFirstResponder(nil) }
                return
            }
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
    @FocusState private var composeFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary).font(.system(size: Tokens.CompactSize.meta))
                HStack(spacing: 1) {
                    Text(model.query.isEmpty ? "Search clips…" : model.query)
                        .font(.system(size: Tokens.CompactSize.rowText))
                        .foregroundColor(model.query.isEmpty ? .secondary : .primary)
                    SearchCaret()
                }
                Spacer(minLength: 8)
                if !model.query.isEmpty {
                    Button { model.query = ""; model.selection = 0 } label: {
                        Image(systemName: "xmark.circle.fill")
                            .imageScale(.small).foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
                ForEach(PickerModel.ContentFilter.allCases) { f in filterChip(f) }
            }
            // 14pt horizontal aligns the search icon with row content below.
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 13)
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.iBeam.push() } else { NSCursor.pop() } }
            Divider()

            if model.composing {
                composeView
            } else {
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
                    if !model.pinnedItems.isEmpty, model.query.isEmpty {
                        sectionHeader("PINNED")
                        ForEach(model.pinnedItems) { item in
                            HistoryRow(item: item, index: -1, selected: false,
                                       onDelete: { model.onUnpin?(item.hash) },
                                       onCleanup: nil,
                                       onAirDrop: model.airDropAvailable
                                           ? { model.onAirDrop?(item) } : nil,
                                       deleteSymbol: "pin.slash",
                                       deleteHelp: "Unpin on all Macs",
                                       deleteOffset: 0.5)
                                .contentShape(Rectangle())
                                .onTapGesture { model.onPickPinned?(item.hash) }
                                .onDrag { DragOutStager.provider(for: item) }
                                .onHover { inside in
                                    if inside { model.beginHover(item) } else { model.endHover(item) }
                                }
                                .handCursorOnHover()
                        }
                        Spacer().frame(height: 6)
                    }
                    sectionHeader("RECENT")
                    if model.grouped.isEmpty {
                        Text(model.query.isEmpty ? "No clips yet — copy something, or drop files here to share." : "No matches.")
                            .foregroundColor(.secondary).font(.callout).padding(.horizontal, 14).padding(.vertical, 10)
                    } else {
                        // Grouped by source Mac; headers fold/unfold their group.
                        // Within a group, items sit in per-type sub-sections
                        // (labels shown only when there's more than one type).
                        ForEach(model.grouped, id: \.source) { group in
                            groupHeader(group)
                            ForEach(group.sections, id: \.title) { section in
                                if group.sections.count > 1 || section.isCollapsed {
                                    subHeader(group.source, section)
                                }
                                ForEach(section.entries, id: \.item.id) { e in
                                    HistoryRow(item: e.item, index: e.index, selected: e.index == model.selection,
                                               onDelete: { model.onDeleteHistory(e.item.hash) },
                                               onCleanup: model.aiConfigured
                                                   && (e.item.category == .text || e.item.category == .richText)
                                                   ? { model.cleanUpItem(e.item) } : nil,
                                               onAirDrop: model.airDropAvailable
                                                   ? { model.onAirDrop?(e.item) } : nil,
                                               onPin: model.pinnedHashes.contains(e.item.hash)
                                                   ? nil : { model.onPin?(e.item) })
                                        .contentShape(Rectangle())
                                        .onTapGesture { model.onPickHistory(e.item.hash) }
                                        // Drag a clip out to Finder or any app.
                                        .onDrag { DragOutStager.provider(for: e.item) }
                                        .onHover { inside in
                                            if inside { model.beginHover(e.item) } else { model.endHover(e.item) }
                                        }
                                        .handCursorOnHover()
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 6)
             }
             .onChange(of: model.selection) { sel in
                 let f = model.filtered
                 guard f.indices.contains(sel) else { return }
                 withAnimation(Tokens.Motion.microCurve) { proxy.scrollTo(f[sel].id, anchor: .center) }
             }
            }
            }

            Divider()
            HStack(spacing: 9) {
                hint("↑↓", "navigate"); hint("⏎", "use"); hint("⌘1–9", "quick"); hint("⌘⌫", "delete"); hint("⎋", "close")
                Spacer(minLength: 6)
                if !model.clipUsage.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.clipboard").font(.system(size: Tokens.CompactSize.badge))
                        Text(model.clipUsage).font(.system(size: Tokens.CompactSize.label)).lineLimit(1)
                    }
                    .foregroundColor(.secondary)
                    .layoutPriority(-1)   // first to give way when the panel is narrow
                }
                footerToggle("square.and.pencil", active: model.composing,
                             help: "Compose: write or paste text, clean it up with AI, then copy") {
                    model.composing ? model.endCompose() : model.startCompose()
                }
                footerToggle("hand.raised" + (model.privacyHold ? ".fill" : ""),
                             active: model.privacyHold,
                             help: model.privacyHold
                                ? "Privacy hold is ON — nothing you copy leaves this Mac. Click to resume sharing."
                                : "Privacy hold: stop sending your copies to other Macs") { model.togglePrivacy() }
                footerToggle("pin" + (model.pinned ? ".fill" : ""),
                             active: model.pinned,
                             help: model.pinned
                                ? "Pinned — the picker stays open after picking. Click to unpin."
                                : "Pin: keep the picker open after picking a clip") { model.togglePin() }
                pickerHelp("picker-open", help: "Help — how the picker works")
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .frame(minWidth: 380, minHeight: 320)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: .top)   // don't reserve the title-bar gap above search
        .background(KeyCatcher(model: model).frame(width: 0, height: 0))
        // AppKit drop target: unlike .onDrop(of: [.fileURL]) it also accepts
        // file *promises* (Outlook/Mail emails, Photos, browser images).
        // Disabled in compose so text drags reach the editor.
        .background {
            if !model.composing {
                PromiseDropTarget(targeted: $dropTargeted) { model.onDropFiles($0) }
            }
        }
        .overlay { if dropTargeted { dropOverlay } }
        .overlay(alignment: .bottom) { if let msg = model.dropMessage { dropToast(msg) } }
        .overlay(alignment: .bottomTrailing) {
            if let item = model.hoverItem { PreviewCard(item: item, model: model) }
        }
        .animation(Tokens.Motion.paneCurve, value: dropTargeted)
        .animation(Tokens.Motion.paneCurve, value: model.dropMessage)
        .animation(Tokens.Motion.microCurve, value: model.hoverItem?.id)
    }

    /// Compose mode: write/paste text, optionally AI-clean it, copy the result.
    private var composeView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button { model.endCompose() } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").font(.system(size: Tokens.CompactSize.badge, weight: .semibold))
                        Text("Back").font(.system(size: Tokens.CompactSize.meta))
                    }
                }
                .buttonStyle(.plain).foregroundColor(.secondary)
                Text("COMPOSE").font(.system(size: Tokens.CompactSize.label, weight: .semibold)).tracking(0.6)
                    .foregroundColor(.secondary)
                Spacer()
                if model.composeBusy { ProgressView().controlSize(.small) }
                pickerHelp("compose", help: "Help — Compose & AI cleanup")
            }
            TextEditor(text: $model.composeText)
                .font(.system(size: Tokens.CompactSize.rowText))
                .focused($composeFocused)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: Tokens.Radius.card).fill(Color.secondary.opacity(0.07)))
                .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.card).strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5))
                .disabled(model.composeBusy)
            if let err = model.composeError {
                Text(err).font(.system(size: Tokens.CompactSize.label)).foregroundColor(.red).lineLimit(2)
            }
            if let answer = model.askAnswer {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 4) {
                        Image(systemName: "questionmark.bubble").font(.system(size: Tokens.CompactSize.badge))
                        Text("From your clipboard").font(.system(size: Tokens.CompactSize.label, weight: .semibold))
                        if model.askBusy { ProgressView().controlSize(.mini) }
                        Spacer()
                        pickerHelp("ask", help: "Help — Ask your clipboard")
                        Button { model.clearAsk() } label: {
                            Image(systemName: "xmark.circle.fill").imageScale(.small)
                                .foregroundStyle(.tertiary)
                        }.buttonStyle(.plain)
                    }
                    ScrollView {
                        Text(answer).font(.system(size: Tokens.CompactSize.meta)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 140)
                    if !model.askSources.isEmpty {
                        Text("Clips used: " + model.askSources.joined(separator: " · "))
                            .font(.system(size: Tokens.CompactSize.badge)).foregroundColor(.secondary).lineLimit(2)
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: Tokens.Radius.card).fill(Color.secondary.opacity(0.07)))
            }
            if let changes = model.composeChanges {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles").font(.system(size: Tokens.CompactSize.badge))
                    Text("Changed: \(changes)").font(.system(size: Tokens.CompactSize.label)).lineLimit(2)
                }
                .foregroundColor(.secondary)
            }
            HStack(spacing: 8) {
                Button {
                    model.runCleanup()
                } label: {
                    Label(model.composeBusy ? "Working…" : model.selectedPreset.name,
                          systemImage: "sparkles")
                        .font(.system(size: Tokens.CompactSize.meta, weight: .medium))
                }
                .disabled(model.composeBusy || model.composeText.isEmpty)
                // Tone preset switcher: the button above runs whichever is checked.
                Menu {
                    ForEach(model.presets) { p in
                        Button {
                            model.selectPreset(p.id)
                        } label: {
                            if p.id == model.selectedPresetID {
                                Label(p.name, systemImage: "checkmark")
                            } else {
                                Text(p.name)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: Tokens.CompactSize.badge, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 24)
                .disabled(model.composeBusy)
                if model.composeOriginal != nil, !model.composeBusy {
                    Button("Undo") { model.undoCleanup() }.font(.system(size: Tokens.CompactSize.meta))
                }
                Button {
                    model.askClipboard()
                } label: {
                    Label(model.askBusy ? "Asking…" : "Ask Clipboard", systemImage: "questionmark.bubble")
                        .font(.system(size: Tokens.CompactSize.meta, weight: .medium))
                }
                .disabled(model.askBusy || model.composeBusy || model.composeText.isEmpty)
                .help("Answer this question from your clip history (retrieval + AI)")
                Spacer()
                Button("Cancel") { model.endCompose() }
                    .font(.system(size: Tokens.CompactSize.meta))
                    .keyboardShortcut(.cancelAction)
                Button {
                    model.useCompose()
                } label: {
                    Label("Use", systemImage: "checkmark.circle")
                        .font(.system(size: Tokens.CompactSize.meta, weight: .medium))
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.composeText.isEmpty || model.composeBusy)
            }
        }
        .padding(12)
        // Focus lands in the note field the moment compose opens (tiny delay
        // lets the KeyCatcher release first responder first), and returns
        // there after an AI run re-enables the editor.
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { composeFocused = true }
        }
        .onChange(of: model.composeBusy) { busy in
            if !busy && model.composing {
                DispatchQueue.main.async { composeFocused = true }
            }
        }
    }

    /// Full-panel affordance shown while files are dragged over the picker.
    private var dropOverlay: some View {
        ZStack {
            Color.tandemAccent.opacity(0.08)
            RoundedRectangle(cornerRadius: Tokens.Radius.sheet)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                .foregroundColor(Tokens.accent.opacity(0.6))
                .padding(6)
            VStack(spacing: 9) {
                Image(systemName: "arrow.up.doc.on.clipboard").font(.system(size: Tokens.CompactSize.hero))
                Text("Drop to share with your Macs").font(.system(size: Tokens.CompactSize.rowTitle, weight: .medium))
            }
            .foregroundColor(.tandemAccent)
        }
        .allowsHitTesting(false)
    }

    /// Transient status line after a drop (shared to N Macs, or a reason nothing sent).
    private func dropToast(_ msg: String) -> some View {
        Text(msg)
            .font(.system(size: Tokens.CompactSize.meta, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(model.dropIsError
                ? Color(white: 0.25).opacity(0.94)          // neutral notice — never accent
                : Color.tandemAccent.opacity(0.92)))
            .padding(.bottom, 44)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func filterChip(_ f: PickerModel.ContentFilter) -> some View {
        let active = model.kindFilter == f
        return Button { model.kindFilter = f } label: {
            Image(systemName: f.symbol)
                .font(.system(size: Tokens.CompactSize.label, weight: active ? .semibold : .regular))
                .foregroundColor(active ? .white : .secondary)
                .frame(width: 22, height: 17)
                .background(active ? Color.tandemAccent : Color.secondary.opacity(0.12))
                .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .help(f.label)
    }

    /// Per-Mac group header: fold chevron, source name, total count, and
    /// per-kind count badges. Clicking anywhere on it folds/unfolds the group.
    private func groupHeader(_ group: PickerModel.Group) -> some View {
        HStack(spacing: 6) {
            Image(systemName: group.isCollapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: Tokens.CompactSize.tiny, weight: .semibold))
                .foregroundColor(.secondary.opacity(0.8))
                .frame(width: 9)
            Text(group.source).font(.system(size: Tokens.CompactSize.meta, weight: .medium)).foregroundColor(.secondary)
            Text("\(group.total)")
                .font(.system(size: Tokens.CompactSize.badge, weight: .bold, design: .monospaced))
                .foregroundColor(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 1.5)
                .background(Capsule().fill(Color.secondary.opacity(0.2)))
            ForEach(group.badges, id: \.symbol) { badge in
                HStack(spacing: 3) {
                    Image(systemName: badge.symbol).font(.system(size: Tokens.CompactSize.tiny))
                    Text("\(badge.count)").font(.system(size: Tokens.CompactSize.badge, weight: .semibold, design: .monospaced))
                }
                .foregroundColor(.secondary)
                .padding(.horizontal, 5).padding(.vertical, 1.5)
                .background(Capsule().fill(Color.secondary.opacity(0.12)))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 1)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(Tokens.Motion.microCurve) { model.toggleGroup(group.source) } }
        .handCursorOnHover()
    }

    private func sectionHeader(_ t: String) -> some View {
        Text(t).font(.system(size: Tokens.CompactSize.label, weight: .semibold)).tracking(0.6)
            .foregroundColor(.secondary).padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 2)
    }

    /// Per-type sub-header inside a Mac group — quieter and indented so the
    /// group header stays the dominant level. Clicking folds/unfolds the
    /// sub-section; the count shows what's inside either way.
    private func subHeader(_ source: String, _ section: PickerModel.Section) -> some View {
        HStack(spacing: 4) {
            Image(systemName: section.isCollapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: Tokens.CompactSize.mini, weight: .semibold))
                .foregroundColor(.secondary.opacity(0.55))
                .frame(width: 7)
            Text(section.title.uppercased()).font(.system(size: Tokens.CompactSize.badge, weight: .semibold)).tracking(0.8)
                .foregroundColor(.secondary.opacity(0.65))
            Text("\(section.count)")
                .font(.system(size: Tokens.CompactSize.tiny, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.65))
                .padding(.horizontal, 4.5).padding(.vertical, 1)
                .background(Capsule().fill(Color.secondary.opacity(0.1)))
            Spacer(minLength: 0)
        }
        .padding(.leading, 29).padding(.top, 4).padding(.bottom, 1)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(Tokens.Motion.microCurve) { model.toggleSub(source, section.title) } }
        .handCursorOnHover()
    }
    /// Small stateful icon button for the footer (privacy hold, pin). Accent
    /// tint + filled symbol when active so the state reads at a glance.
    private func footerToggle(_ symbol: String, active: Bool, help: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: { withAnimation(Tokens.Motion.microCurve) { action() } }) {
            Image(systemName: symbol)
                .font(.system(size: Tokens.CompactSize.meta, weight: .medium))
                .foregroundColor(active ? .white : .secondary)
                .frame(width: 24, height: 18)
                .background(RoundedRectangle(cornerRadius: Tokens.Radius.control)
                    .fill(active ? Color.tandemAccent : Color.secondary.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func hint(_ k: String, _ t: String) -> some View {
        HStack(spacing: 3) {
            Text(k).font(.system(size: Tokens.CompactSize.label, design: .monospaced)).lineLimit(1).padding(.horizontal, 4).padding(.vertical, 1)
                .background(Color.secondary.opacity(0.15)).cornerRadius(3)
            Text(t).font(.system(size: Tokens.CompactSize.label)).lineLimit(1).foregroundColor(.secondary)
        }
        .fixedSize()
    }

    /// A "?" button that opens the Help window at a specific article (bidirectional
    /// with Settings' inline links) — via the same `HelpDeepLink` route. Borderless
    /// so it reads as auxiliary next to the footer's action toggles.
    private func pickerHelp(_ topic: String, anchor: String? = nil, help: String) -> some View {
        Button { HelpDeepLink.open(topic: topic, anchor: anchor) } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: Tokens.CompactSize.meta, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Static (non-blinking) caret. A blinking caret drove a 0.55s timer that
/// re-rendered the picker and made the list flicker; a steady bar avoids that.
private struct SearchCaret: View {
    var body: some View {
        Rectangle().fill(Color.tandemAccent.opacity(0.8)).frame(width: 1.5, height: 14)
    }
}

private struct HistoryRow: View {
    let item: HistoryItem
    let index: Int
    let selected: Bool
    let onDelete: () -> Void
    /// AI cleanup action — nil hides the ✨ (non-text clip or AI unconfigured).
    var onCleanup: (() -> Void)?
    /// AirDrop action — nil hides the share button (AirDrop unavailable).
    var onAirDrop: (() -> Void)?
    /// Pin action — nil when already pinned (or for pinned rows themselves).
    var onPin: (() -> Void)?
    /// The trailing destructive-ish button is delete for history rows and
    /// unpin for pinned rows.
    var deleteSymbol = "xmark.circle.fill"
    var deleteHelp = "Delete from history on all Macs"
    /// Optical nudge for the delete glyph — 0 for the centered ✕, small for
    /// high-reading symbols like pin.slash.
    var deleteOffset: CGFloat = 0
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 10) {
            thumb
            VStack(alignment: .leading, spacing: 2) {
                if item.label.hasPrefix(HistoryItem.smartTitlePrefix) {
                    // Smart title: a crisp accent glyph reads far better than the
                    // raw ✨ emoji baked into the string (tiny, off-palette).
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles")
                            .font(.system(size: Tokens.CompactSize.rowTitle))
                            .foregroundColor(Tokens.accent)
                        Text(String(item.label.dropFirst(HistoryItem.smartTitlePrefix.count)))
                            .lineLimit(1).font(.system(size: Tokens.CompactSize.rowTitle))
                    }
                } else {
                    Text(item.label.isEmpty ? item.kindLabel : item.label).lineLimit(1).font(.system(size: Tokens.CompactSize.rowTitle))
                }
                HStack(spacing: 6) {
                    Text(item.source).font(.system(size: Tokens.CompactSize.label)).foregroundColor(.secondary)
                    Text("·").foregroundColor(.secondary)
                    Text(age(item.timestamp)).font(.system(size: Tokens.CompactSize.label)).foregroundColor(.secondary)
                    Text("·").foregroundColor(.secondary)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(item.snapshot.totalBytes), countStyle: .file))
                        .font(.system(size: Tokens.CompactSize.label)).foregroundColor(.secondary)
                }
            }
            Spacer()
            if hovering {
                // Equal 17pt frames put the action icons on one row. The share
                // glyph's weight is in its box (the arrow above is thin), so
                // bounding-box centering makes the box sit LOW — it's raised to
                // put the box on the ✕'s center. Offsets picked from a
                // full-row center-guide render.
                if let onAirDrop {
                    Button(action: onAirDrop) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: Tokens.CompactSize.rowText))
                            .foregroundColor(.secondary)
                            .offset(y: -1)
                            .frame(width: 17, height: 17)
                    }
                    .buttonStyle(.plain)
                    .help("AirDrop to a nearby device (iPhone, iPad, any Mac)")
                }
                if let onCleanup {
                    Button(action: onCleanup) {
                        Image(systemName: "sparkles")
                            .font(.system(size: Tokens.CompactSize.rowText))
                            .foregroundColor(.secondary)
                            .frame(width: 17, height: 17)
                    }
                    .buttonStyle(.plain)
                    .help("Clean up with AI (opens in compose)")
                }
                if let onPin {
                    Button(action: onPin) {
                        Image(systemName: "pin")
                            .font(.system(size: Tokens.CompactSize.meta))
                            .foregroundColor(.secondary)
                            .offset(y: 0.5)
                            .frame(width: 17, height: 17)
                    }
                    .buttonStyle(.plain)
                    .help("Pin — keep past restarts, on every Mac")
                }
                Button(action: onDelete) {
                    Image(systemName: deleteSymbol)
                        .font(.system(size: Tokens.CompactSize.rowTitle))
                        .foregroundColor(.secondary)
                        .offset(y: deleteOffset)
                        .frame(width: 17, height: 17)
                }
                .buttonStyle(.plain)
                .help(deleteHelp)
            } else if index >= 0 && index < 9 {
                Text("⌘\(index + 1)").font(.system(size: Tokens.CompactSize.label, design: .monospaced)).foregroundColor(.secondary.opacity(0.7))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        // Selection (keyboard/⌘n target) is the solid accent fill and stays put
        // until the user picks elsewhere; hover is its own lighter state — a
        // faint wash + hairline accent outline — so the two never fight.
        .background(selected ? Color.tandemAccent.opacity(0.22)
                    : hovering ? Color.secondary.opacity(0.07) : Color.clear)
        .overlay {
            if hovering && !selected {
                RoundedRectangle(cornerRadius: Tokens.Radius.card)
                    .strokeBorder(Color.tandemAccent.opacity(0.35), lineWidth: 1)
            }
        }
        .cornerRadius(6).padding(.horizontal, 6)
        .onHover { hovering = $0 }
    }
    @ViewBuilder private var thumb: some View {
        if let d = item.imageData, let img = NSImage(data: d) {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                .frame(width: 30, height: 30).clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.control))
        } else {
            Image(systemName: icon(item.category)).frame(width: 30, height: 30)
                .background(Color.secondary.opacity(0.12)).cornerRadius(5).foregroundColor(.secondary)
        }
    }
}

/// Hover preview: enough content to know what a clip is without applying it.
/// Fixed to the panel's bottom-trailing corner (stable — no flicker chasing
/// the pointer). Text/rich clips show an excerpt; images a larger thumbnail;
/// documents/files their file list, plus an excerpt for a text-like document
/// or a first-page render for a PDF.
private struct PreviewCard: View {
    let item: HistoryItem
    @ObservedObject var model: PickerModel
    /// QuickLook thumbnail + media duration, loaded async per hovered item.
    @State private var generated = PreviewThumbnailer.Result()

    private var ocrText: String? { model.ocrLookup?(item.hash) }
    private var actions: [QuickAction] { QuickAction.detect(for: item, ocrText: ocrText) }
    private var summarizable: Bool {
        model.aiConfigured && (item.snapshot.plainText?.count ?? 0) > 600
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: icon(item.category)).font(.system(size: Tokens.CompactSize.label))
                Text(item.kindLabel).font(.system(size: Tokens.CompactSize.label, weight: .semibold))
                Text("·").foregroundColor(.secondary)
                Text(ByteCountFormatter.string(fromByteCount: Int64(item.snapshot.totalBytes), countStyle: .file))
                    .font(.system(size: Tokens.CompactSize.label))
                if let d = generated.duration {
                    Text("·").foregroundColor(.secondary)
                    Text(PreviewThumbnailer.durationLabel(d)).font(.system(size: Tokens.CompactSize.label))
                }
                Spacer(minLength: 0)
                Text(exactTime(item.timestamp)).font(.system(size: Tokens.CompactSize.label)).foregroundColor(.secondary)
                Button { HelpDeepLink.open(topic: "picker-preview") } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: Tokens.CompactSize.badge))
                        .foregroundColor(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Help — Hover previews & quick actions")
            }
            Divider()
            content
            if let summary = model.summaries[item.hash] {
                Divider()
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "sparkles").font(.system(size: Tokens.CompactSize.badge)).padding(.top, 2)
                    Text(summary).font(.system(size: Tokens.CompactSize.label)).lineLimit(6)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundColor(.secondary)
            }
            if let translation = model.translationLookup?(item.hash) {
                Divider()
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "globe").font(.system(size: Tokens.CompactSize.badge)).padding(.top, 2)
                    Text(translation).font(.system(size: Tokens.CompactSize.label)).lineLimit(8)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .foregroundColor(.secondary)
            }
            if !actions.isEmpty || summarizable || ocrText != nil {
                Divider()
                // Quick actions: detected links/emails/phones, file save, OCR
                // copy, AI summarize — the "do something with it" row.
                FlowishActionRow {
                    ForEach(actions) { action in
                        cardButton(action.title, action.symbol) {
                            model.runQuickAction(action, on: item)
                        }
                    }
                    if let ocr = ocrText {
                        cardButton("Copy Text", "text.viewfinder") {
                            model.copyText(ocr, toast: "Image text copied — syncs like any copy")
                        }
                    }
                    if summarizable && model.summaries[item.hash] == nil {
                        cardButton(model.summarizingHash == item.hash ? "Summarizing…" : "Summarize",
                                   "sparkles") {
                            model.summarize(item)
                        }
                    }
                }
            }
        }
        .padding(10)
        .frame(width: 250, alignment: .leading)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: Tokens.Radius.sheet))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.sheet).strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
        .padding(.trailing, 12).padding(.bottom, 44)
        .onHover { model.cardHover($0) }   // grace: entering the card keeps it up
        .task(id: item.id) {
            generated = PreviewThumbnailer.Result()
            guard !item.snapshot.files.isEmpty, item.imageData == nil else { return }
            generated = await PreviewThumbnailer.shared.preview(for: item)
        }
    }

    private func cardButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: Tokens.CompactSize.badge))
                Text(title).font(.system(size: Tokens.CompactSize.label, weight: .medium)).lineLimit(1)
            }
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(Color.secondary.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var content: some View {
        if let data = item.imageData, let img = NSImage(data: data) {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                .frame(maxWidth: 230, maxHeight: 150)
                .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.control))
            Text("\(Int(img.size.width)) × \(Int(img.size.height))")
                .font(.system(size: Tokens.CompactSize.badge)).foregroundColor(.secondary)
            if let ocr = ocrText {
                Text(ocr).font(.system(size: Tokens.CompactSize.badge, design: .monospaced))
                    .lineLimit(3).foregroundColor(.secondary)
            }
        } else if !item.snapshot.files.isEmpty {
            // QuickLook render of the first file — PDF first page, Office
            // document, video frame, … — when the system can produce one.
            if let thumb = generated.image {
                Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 230, maxHeight: 140)
                    .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.control))
            }
            ForEach(PickerModel.previewFiles(item).prefix(6), id: \.name) { f in
                HStack(spacing: 5) {
                    Image(systemName: "doc").font(.system(size: Tokens.CompactSize.badge)).foregroundColor(.secondary)
                    Text(f.name).font(.system(size: Tokens.CompactSize.label)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(f.size), countStyle: .file))
                        .font(.system(size: Tokens.CompactSize.badge)).foregroundColor(.secondary)
                }
            }
            if item.snapshot.files.count > 6 {
                Text("+\(item.snapshot.files.count - 6) more").font(.system(size: Tokens.CompactSize.badge)).foregroundColor(.secondary)
            }
            if let excerpt = PickerModel.previewText(item) {
                Divider()
                Text(excerpt).font(.system(size: Tokens.CompactSize.label, design: .monospaced))
                    .lineLimit(8).foregroundColor(.secondary)
            }
        } else if let excerpt = PickerModel.previewText(item) {
            Text(excerpt).font(.system(size: Tokens.CompactSize.meta))
                .lineLimit(10).fixedSize(horizontal: false, vertical: true)
        } else {
            Text("No preview").font(.system(size: Tokens.CompactSize.label)).foregroundColor(.secondary)
        }
    }

    private func exactTime(_ ts: Double) -> String {
        let f = DateFormatter()
        f.dateStyle = .none; f.timeStyle = .short
        return f.string(from: Date(timeIntervalSince1970: ts))
    }
}

/// Wrapping-ish action row: a simple two-line layout for up to ~5 chips.
private struct FlowishActionRow<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        // LazyVGrid with adaptive columns handles wrapping without a custom
        // layout; chips size to content within the card's fixed width.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), alignment: .leading)],
                  alignment: .leading, spacing: 5) {
            content
        }
    }
}

private struct PeerRow: View {
    let clip: PeerClip
    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Color.green).frame(width: 7, height: 7)
            Text(clip.name).font(.system(size: Tokens.CompactSize.rowTitle))
            Spacer()
            if let k = clip.kindLabel { Text(k).font(.system(size: Tokens.CompactSize.label)).foregroundColor(.secondary) }
            if let s = clip.size { Text(ByteCountFormatter.string(fromByteCount: Int64(s), countStyle: .file))
                .font(.system(size: Tokens.CompactSize.label)).foregroundColor(.secondary) }
            Image(systemName: "arrow.down.circle").foregroundColor(.secondary).font(.system(size: Tokens.CompactSize.rowText))
        }
        .padding(.horizontal, 14).padding(.vertical, 7).padding(.horizontal, 6)
    }
}

private func icon(_ category: ClipCategory) -> String {
    switch category {
    case .image:    return "photo"
    case .richText: return "textformat"
    case .document: return "doc.text"
    case .audio:    return "waveform"
    case .video:    return "film"
    case .file:     return "shippingbox"
    case .text:     return "text.alignleft"
    }
}
private func age(_ ts: Double) -> String {
    let s = Int(Date().timeIntervalSince1970 - ts)
    if s < 5 { return "just now" }; if s < 60 { return "\(s)s ago" }
    if s < 3600 { return "\(s/60)m ago" }; return "\(s/3600)h ago"
}

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
        // answer ONLY from them — a retrieval-grounded Ask pane.
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

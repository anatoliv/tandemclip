import AppKit
import SwiftUI
import UniformTypeIdentifiers

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

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Static (non-blinking) caret. A blinking caret drove a 0.55s timer that
/// re-rendered the picker and made the list flicker; a steady bar avoids that.
struct SearchCaret: View {
    var body: some View {
        Rectangle().fill(Color.tandemAccent.opacity(0.8)).frame(width: 1.5, height: 14)
    }
}

struct HistoryRow: View {
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
struct PreviewCard: View {
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
struct FlowishActionRow<Content: View>: View {
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

struct PeerRow: View {
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

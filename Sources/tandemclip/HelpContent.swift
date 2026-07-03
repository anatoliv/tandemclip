import Foundation
import NaturalLanguage

/// One help entry. The catalog below is the single source of truth the Help
/// window renders and searches.
struct HelpTopic: Identifiable, Equatable {
    let id: String
    let category: String
    let title: String
    let body: String
}

/// Everything the Help window knows, grouped by category (rendering order).
enum HelpCatalog {
    static let categories: [(name: String, symbol: String)] = [
        ("Getting started", "sparkles"),
        ("Clipboard picker", "rectangle.stack"),
        ("Settings — General", "gearshape"),
        ("Settings — Sync", "arrow.triangle.2.circlepath"),
        ("Settings — Content", "doc.on.clipboard"),
        ("Settings — AI", "wand.and.stars"),
        ("Settings — Security", "lock.shield"),
        ("Private by design", "hand.raised"),
        ("Troubleshooting", "wrench.and.screwdriver"),
    ]

    static let topics: [HelpTopic] = [
        // MARK: Getting started
        .init(id: "pair", category: "Getting started", title: "Pair your Macs",
              body: "Install TandemClip on each Mac and enter the same pairing code under Settings → Security. The code is the encryption key — being on the same Wi-Fi grants nothing by itself."),
        .init(id: "first-sync", category: "Getting started", title: "Your first sync",
              body: "With two paired Macs in Mirror mode, copy some text on one and paste on the other — that's the whole loop. The menu-bar icon shows sync state; the picker (⇧⌘V) shows everything else."),

        // MARK: Picker
        .init(id: "picker-open", category: "Clipboard picker", title: "Open & navigate",
              body: "Press ⇧⌘V anywhere. Arrow keys move the selection, ⏎ uses the selected clip, ⌘1–9 pick by number, ⌘⌫ deletes the selected clip everywhere, and Esc closes (unless pinned). Just start typing to search your clips."),
        .init(id: "picker-filter", category: "Clipboard picker", title: "Filter & groups",
              body: "The chips narrow the list to Text, Images, Documents, Audio & Video, or Files. Clips group by the Mac they came from; click a group header (or a Text/Images/… sub-header) to fold it. Fold state is remembered."),
        .init(id: "picker-preview", category: "Clipboard picker", title: "Hover previews",
              body: "Rest the pointer on a clip to see what it is without applying it: a text excerpt, a bigger image, a PDF's first page, an Office document or video frame, file names with sizes, and duration for audio and video."),
        .init(id: "picker-files", category: "Clipboard picker", title: "Files",
              body: "Picking a file clip copies it to the clipboard and opens it in its default app. Received files are cached on disk (Settings → Content → Storage controls how much)."),
        .init(id: "drop-share", category: "Clipboard picker", title: "Drop to share",
              body: "Drag files from Finder — or emails from Outlook/Mail, photos from Photos, images from a browser — onto the picker to send them to your other Macs right away. Works in both Mirror and Manual mode; folders travel as .zip archives (as does copying a folder with ⌘C)."),
        .init(id: "semantic-search", category: "Clipboard picker", title: "Search by meaning",
              body: "The picker's search matches more than words: it looks at each clip's full text, the text inside screenshots (recognized on this Mac), and the meaning of what you type — \"that container command\" finds your docker clip. Everything runs on-device; searching sends nothing anywhere."),
        .init(id: "ocr", category: "Clipboard picker", title: "Text inside images",
              body: "Screenshots and image clips get their text recognized on-device. It shows in the hover preview with a Copy Text button, it's searchable, and links or phone numbers found in it become quick actions."),
        .init(id: "quick-actions", category: "Clipboard picker", title: "Quick actions",
              body: "The hover preview offers one-click actions for what it finds in a clip: Open a link, Email an address, Copy a phone number, Save files to Downloads — detected locally. Long text clips add a Summarize button (uses your AI endpoint); pins, AirDrop, and drag-out round it out."),
        .init(id: "pinned", category: "Clipboard picker", title: "Pinned clips",
              body: "Hover a clip and click the pin to keep it permanently: pins survive restarts, sync to your other Macs, and sit in a PINNED section above RECENT (up to 20). Click one to put it back on the clipboard; the pin.slash button unpins everywhere. Deleting a clip everywhere unpins it too."),
        .init(id: "drag-out", category: "Clipboard picker", title: "Drag a clip out",
              body: "Drag any clip from the picker into Finder or another app: text drags as text, a file clip as the file itself, multi-file clips as a folder named after the clip."),
        .init(id: "ask", category: "Clipboard picker", title: "Ask your clipboard",
              body: "In compose (✎), type a question and hit Ask Clipboard: the best-matching clips from your history are found on-device and handed to your AI endpoint as the only allowed context — \"what was that address Sofia sent?\" gets answered from the clip, with the clips it used listed under the answer."),
        .init(id: "services", category: "Clipboard picker", title: "Send from any app",
              body: "Select text or files in any app and use the app menu ▸ Services ▸ \"Send to TandemClip\" (also in the right-click Services submenu) to share it to your Macs immediately — no copying first. Appears after the first launch following an update; log out/in if macOS is slow to pick it up."),
        .init(id: "airdrop", category: "Clipboard picker", title: "AirDrop a clip",
              body: "Hover a clip and click the share button to AirDrop it to any nearby Apple device — an iPhone, iPad, or a Mac that isn't in your pairing group. Text goes as a small .txt, images as .png, files as themselves. TandemClip syncs your paired Macs; AirDrop covers everything else."),
        .init(id: "delete-everywhere", category: "Clipboard picker", title: "Delete everywhere",
              body: "Hover a clip and click ✕ (or press ⌘⌫) to remove it from history on every Mac — including any clipboard or received file still holding it. Deletions are signed and can't be forged or replayed."),
        .init(id: "privacy-hold", category: "Clipboard picker", title: "Privacy hold ✋",
              body: "The hand button in the picker footer stops anything you copy from leaving this Mac — no broadcasts, no pull serving, no previews, and AI cleanup calls are paused too — until you switch it off. Receiving keeps working. The menu-bar icon shows a raised hand while it's on. Example: turn it on before copying passwords or unreleased numbers, then off when done."),
        .init(id: "pin", category: "Clipboard picker", title: "Pin 📌",
              body: "The pin keeps the picker open: it stays up after picking a clip, survives clicking into other apps, and ignores Esc until you unpin it. Unpinned, the picker is transient — Esc or clicking away closes it."),
        .init(id: "compose", category: "Clipboard picker", title: "Compose & AI cleanup ✎",
              body: "The pencil button opens a text area: write or paste something, pick a tone preset (Clean up, Email reply, Summarize, Translate, …), and the AI rewrite streams in. Undo restores your original; Use (⌘⏎) puts the result on the clipboard so it syncs like any copy. Needs an endpoint configured under Settings → AI."),

        // MARK: Settings — General
        .init(id: "general-startup", category: "Settings — General", title: "Startup",
              body: "Launch at login opens TandemClip automatically. Start paused keeps syncing off after launch until you hit Resume in the menu — nothing is shared right after boot."),
        .init(id: "general-name", category: "Settings — General", title: "Display name",
              body: "The name your other Macs see for this computer — in the picker's group headers, the peer list, and sync history. Two Macs should not share a name."),
        .init(id: "general-diagnostics", category: "Settings — General", title: "Verbose logging",
              body: "Records detailed activity (connections, syncs) to /tmp/tandemclip.err.log. Turn it on when chasing a problem, off otherwise."),

        // MARK: Settings — Sync (with worked examples for every combination)
        .init(id: "sync-mirror", category: "Settings — Sync", title: "Mode: Mirror",
              body: "Every copy is sent to your other Macs the moment you make it, and their copies land here. Deduped, loop-safe, relayed across Macs that can't see each other directly. Example: two Macs on one desk — copy a link on the laptop, ⌘V on the desktop a second later."),
        .init(id: "sync-manual", category: "Settings — Sync", title: "Mode: Manual",
              body: "Nothing moves by itself. Your copies stay on this Mac until another Mac asks; you grab a peer's clipboard from the picker (or menu) when you want it. Example: a shared family Mac where you only occasionally need something from your work laptop — open the picker, click the laptop's entry, done."),
        .init(id: "sync-role-sendreceive", category: "Settings — Sync", title: "Role: Send & receive",
              body: "The default — this Mac participates fully in both directions. Use it unless you have a reason not to."),
        .init(id: "sync-role-receiveonly", category: "Settings — Sync", title: "Role: Receive only",
              body: "This Mac takes clips in but never sends its own clipboard anywhere. Example: a presentation or meeting-room Mac — it mirrors what you copy on your main Mac, but nothing you copy on it (speaker notes, credentials) can leak out."),
        .init(id: "sync-role-sendonly", category: "Settings — Sync", title: "Role: Send only",
              body: "This Mac shares its copies but never lets another Mac overwrite its clipboard. Example: your main workstation feeding a test Mac — the test Mac's clipboard chaos never lands back on your workstation."),
        .init(id: "sync-peer-preview", category: "Settings — Sync", title: "Peer preview",
              body: "How much other Macs can see about your current clip before pulling it. Metadata: they see \"image · 2 MB · 3m ago\". Live text preview: they also see the first 80 characters of text. Names only: they see nothing but your Mac's name. Example: on a Mac where you handle sensitive text, pick Names only — peers can still pull when you allow it, but nothing is previewed."),
        .init(id: "sync-auto-apply", category: "Settings — Sync", title: "Apply incoming clips automatically",
              body: "Makes clips copied on your other Macs land on this clipboard with no clicking, even in Manual mode (Mirror always applies). Example: \"quiet sender, automatic receiver\" — set Manual + this toggle on, and your copies stay private until pulled while everything your other Macs copy just appears here."),
        .init(id: "sync-recipes", category: "Settings — Sync", title: "Common setups (recipes)",
              body: "Two desks, one person: Mirror + Send & receive on both. Presentation Mac: Mirror + Receive only on it. Workstation + scratch Mac: Send only on the workstation. Occasional sharing between family Macs: Manual everywhere. Receive-everything-share-nothing: Manual + Apply incoming automatically. Temporarily stop sharing from any setup: the ✋ privacy hold in the picker."),
        .init(id: "sync-max-size", category: "Settings — Sync", title: "Max clipboard size",
              body: "The biggest clip that will sync (default 5 MB, up to 100 MB — large clips travel in chunks automatically; all Macs need a recent version past ~25 MB). Anything larger falls back to just its plain text, or is skipped if there's no text. Raise it if you often copy large images or files between Macs."),

        // MARK: Settings — Content
        .init(id: "content-kinds", category: "Settings — Content", title: "What to sync",
              body: "Plain text always syncs. Rich text and Images are extra representations carried with each copy so pasting keeps full fidelity. Files (by content) controls only automatic sending — file copies always land in your history and can be pulled or drop-shared either way."),
        .init(id: "content-storage", category: "Settings — Content", title: "Received-files storage",
              body: "Files received from your Macs are cached on disk so paste keeps working. Past the limit (10 MB–1 GB, default 200 MB) the oldest clips are evicted automatically — picking them from history re-materializes them. The clip currently on your clipboard is never evicted."),
        .init(id: "content-history", category: "Settings — Content", title: "History",
              body: "In-memory for the session only — quitting clears it. Choose how many clips to remember and how many the picker shows. Clear History Now also wipes the received-files cache from disk."),

        // MARK: Settings — AI
        .init(id: "ai-setup", category: "Settings — AI", title: "Setting up AI cleanup",
              body: "Pick a provider preset (Anthropic, OpenAI, OpenRouter, Groq — or a local Ollama / LM Studio, which keeps text entirely on your machine), paste an API key, and hit Test Connection. Calls go directly from this Mac to that endpoint; there is no middleman and the key lives in the Keychain."),
        .init(id: "ai-presets", category: "Settings — AI", title: "Tone presets",
              body: "Each preset is a rewrite instruction: Clean up, Email reply, Casual chat, Commit message, Summarize, Translate — all editable, and you can add your own. Pick which one runs from the ▾ next to the button in compose."),
        .init(id: "ai-autotone", category: "Settings — AI", title: "Auto-tone by destination",
              body: "When on, the rewrite adapts to the app you opened the picker over: professional for email, casual for chat, literal for code editors and terminals, structured prose for notes apps."),
        .init(id: "ai-on-receive", category: "Settings — AI", title: "Automatic AI on clips",
              body: "Two separate opt-ins (off by default, since they send clip text to your endpoint automatically): Smart titles give long clips a short AI-generated name (marked ✨) in the picker; Translate incoming shows a translation in the hover preview when a clip arrives in another language — detection is on-device, the clip itself is never altered."),
        .init(id: "ai-fallback", category: "Settings — AI", title: "Fallback endpoint",
              body: "Optional second endpoint tried once when the primary fails with a rate limit, server error, or network problem. Example: local Ollama as primary with a cloud endpoint as fallback — free and private normally, still working when the local server is off."),

        // MARK: Settings — Security
        .init(id: "security-pairing", category: "Settings — Security", title: "Pairing code",
              body: "The shared secret that keys the encryption. Enter the same code on every Mac; Apply re-keys immediately (peers drop until they have the new code); Regenerate makes a fresh strong one. Change it any time you suspect it leaked."),
        .init(id: "security-allowlist", category: "Settings — Security", title: "Trusted devices",
              body: "Off, any Mac holding the pairing code can sync — the code is the trust boundary. On, only checked devices sync, pinned by their signing key: unchecking one revokes it instantly even though it still knows the code. Example: you sold a Mac that once had the code — revoke it here instead of rotating the code everywhere."),
        .init(id: "security-wifi", category: "Settings — Security", title: "Wi-Fi allowlist",
              body: "Restrict syncing to named Wi-Fi networks — nothing is shared on networks you haven't listed. On Ethernet or VPN there's no network name to verify, so sync pauses unless you allow it explicitly."),

        // MARK: Privacy
        .init(id: "privacy-lan", category: "Private by design", title: "No cloud, no relay",
              body: "Peers talk directly over your LAN. There is no server, no account, and nothing to breach. The website only hosts downloads and updates."),
        .init(id: "privacy-passwords", category: "Private by design", title: "Password managers",
              body: "Content a password manager marks as secret is never synced — same for one-time and transient copies. This relies on the source app setting the marker (1Password, Keychain and most managers do); treat unmanaged secrets with care, or flip on the ✋ privacy hold first."),
        .init(id: "secret-guard", category: "Private by design", title: "Secret guard",
              body: "Copies that look like credentials — API keys, private keys, card numbers, lone random tokens — are held on this Mac instead of syncing. The menu bar shows the hold and \"Send Held Clip Anyway\" releases it; the next copy clears it automatically. Toggle under Settings → Security. This backstops apps that don't mark passwords as concealed."),
        .init(id: "privacy-quarantine", category: "Private by design", title: "Received files are quarantined",
              body: "Files that arrive from peers are written with restrictive permissions and macOS quarantine, and are revealed in Finder rather than auto-opened — you decide what runs."),

        // MARK: Troubleshooting
        .init(id: "ts-not-syncing", category: "Troubleshooting", title: "Not syncing?",
              body: "Check, in order: same pairing code on every Mac; same Wi-Fi (and that network is allowed under Settings → Security); not paused (menu); not in privacy hold (✋); role isn't Receive only on the sender; the clip isn't over the size limit."),
        .init(id: "ts-peer-missing", category: "Troubleshooting", title: "A Mac won't appear",
              body: "Give it a moment after wake — peers rediscover automatically every few seconds. Make sure the two Macs don't share a display name, and that your network allows Bonjour (some guest networks block it)."),
        .init(id: "ts-updates", category: "Troubleshooting", title: "Stay current",
              body: "Use \"Check for Updates…\" in the menu. Updates are signed and verified; the app can't be tricked into downgrading."),
    ]

    static func topics(in category: String) -> [HelpTopic] {
        topics.filter { $0.category == category }
    }
}

/// Help search: instant keyword match blended with on-device semantic
/// similarity (Apple's NaturalLanguage sentence embeddings — no network, in
/// keeping with the app's no-cloud stance). Semantic lets "stop sharing my
/// clipboard" find "Privacy hold" without shared words; keyword keeps exact
/// terms instant. Falls back to keyword-only if the embedding model is
/// unavailable.
final class HelpSearchModel: ObservableObject {
    @Published private(set) var results: [HelpTopic] = []

    private var embedding: NLEmbedding?
    private var topicVectors: [String: [[Double]]] = [:]

    init() {
        // Prepare embeddings off the main thread; searches before it finishes
        // just run keyword-only.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let emb = NLEmbedding.sentenceEmbedding(for: .english) else { return }
            var vectors: [String: [[Double]]] = [:]
            for topic in HelpCatalog.topics {
                vectors[topic.id] = Self.embeddingTexts(for: topic).compactMap { emb.vector(for: $0) }
            }
            DispatchQueue.main.async {
                self?.embedding = emb
                self?.topicVectors = vectors
            }
        }
    }

    /// One embedding per title and per body sentence — a long body diluted
    /// into a single vector ranks poorly; max-over-sentences discriminates.
    static func embeddingTexts(for topic: HelpTopic) -> [String] {
        var texts = [topic.title]
        texts += topic.body.split(separator: ".").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count > 15 }
        return texts
    }

    func update(_ query: String) {
        results = Self.search(query, embedding: embedding, vectors: topicVectors)
    }

    /// Pure scoring core (static + injectable for tests).
    static func search(_ query: String, embedding: NLEmbedding?, vectors: [String: [[Double]]]) -> [HelpTopic] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard q.count >= 2 else { return [] }

        let queryVector = embedding?.vector(for: q)
        var scored: [(topic: HelpTopic, score: Double)] = []

        for topic in HelpCatalog.topics {
            var score = 0.0
            let title = topic.title.lowercased()
            let body = topic.body.lowercased()
            if title.contains(q) { score = 1.0 }
            else if body.contains(q) { score = 0.7 }
            else {
                // Token overlap: every query word prefix-matching some topic word.
                let qWords = q.split(separator: " ").filter { $0.count >= 3 }
                if !qWords.isEmpty {
                    let text = title + " " + body
                    let hits = qWords.filter { text.contains($0) }.count
                    score = 0.55 * Double(hits) / Double(qWords.count)
                }
            }
            if let qv = queryVector, let tvs = vectors[topic.id], !tvs.isEmpty {
                // Best sentence wins. Calibrated for NLEmbedding's sentence
                // model, whose related-topic cosines sit around 0.45–0.55.
                let best = tvs.map { cosine(qv, $0) }.max() ?? 0
                if best >= 0.46 { score = max(score, 0.3 + (best - 0.46) * 2) }
            }
            if score > 0.28 { scored.append((topic, score)) }
        }
        return scored.sorted { $0.score > $1.score }.map(\.topic)
    }

    static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        let denom = (na * nb).squareRoot()
        return denom > 0 ? dot / denom : 0
    }
}

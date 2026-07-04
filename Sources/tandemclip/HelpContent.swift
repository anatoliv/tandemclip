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

// MARK: - Release history (What's New)

/// The kind of a single What's New line item — colors and labels the badge.
enum ReleaseChangeKind {
    case added, improved, fixed

    var label: String {
        switch self {
        case .added:    return "New"
        case .improved: return "Improved"
        case .fixed:    return "Fixed"
        }
    }
}

/// One line item within a release.
struct ReleaseChange: Identifiable {
    let id = UUID()
    let kind: ReleaseChangeKind
    let text: String
    init(_ kind: ReleaseChangeKind, _ text: String) { self.kind = kind; self.text = text }
}

/// A single shipped version — a card in the What's New panel. Patch releases
/// are folded into the meaningful version that carried the feature, so the
/// list reads as a story rather than a raw tag dump.
struct HelpRelease: Identifiable {
    let version: String
    let date: String
    let highlight: String
    let changes: [ReleaseChange]
    var id: String { version }
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
        .init(id: "menu-bar", category: "Getting started", title: "The menu-bar menu",
              body: "TandemClip has no Dock icon — the menu-bar icon is home base. The icon itself reflects state: syncing normally, a raised hand while privacy hold is on, a warning when paused because the Wi-Fi isn't allowed. Open the menu for the live status and quick controls.\n\nWhat you'll find there:\n- A **status line** — the current state and how many Macs are connected.\n- The **current clipboard** — its kind, size, which Mac it came from, and how long ago.\n- **Pause / Resume** syncing, and **pull a peer's clipboard** on demand.\n- **Copy Pairing Code** — puts the code on your clipboard to type into another Mac.\n- **Check for Updates…**, Settings, this Help window, and Quit.\n\nThe picker (⇧⌘V) is the other half: history, search, previews, pins, and compose all live there."),

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
              body: "The hover preview offers one-click actions for what it finds in a clip: Open a link, Email an address, Copy a phone number, Save files to Downloads — all detected locally. When AI cleanup is set up, a text clip longer than about 600 characters also gets a **Summarize** button. Pins, AirDrop, and drag-out round it out."),
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
              body: "The pencil button opens a text area: write or paste something, pick a tone preset (Clean up, Email reply, Summarize, Translate, …), and the AI rewrite streams in. Undo restores your original; **Use (⌘⏎)** puts the result on the clipboard so it syncs like any copy. Needs an endpoint configured under Settings → AI.\n\nShortcut: when AI is set up, hovering a text clip shows a **✨ button** on the row that opens compose already filled with that clip and runs your selected tone preset right away — a one-click way to clean up something already in your history."),

        // MARK: Settings — General
        .init(id: "general-startup", category: "Settings — General", title: "Startup",
              body: "Launch at login opens TandemClip automatically. Start paused keeps syncing off after launch until you hit Resume in the menu — nothing is shared right after boot."),
        .init(id: "general-name", category: "Settings — General", title: "Display name",
              body: "The name your other Macs see for this computer — in the picker's group headers, the peer list, and sync history. Two Macs should not share a name."),
        .init(id: "general-appearance", category: "Settings — General", title: "Appearance (light / dark)",
              body: "Sets how TandemClip looks: **System** follows your Mac's light/dark setting and switches with it; **Light** and **Dark** pin the app to that look no matter what the system does. The change applies instantly to the picker, Settings, and these windows, and is remembered. Default is System."),
        .init(id: "general-diagnostics", category: "Settings — General", title: "Verbose logging",
              body: "Records detailed activity (connections, syncs) to `/tmp/tandemclip.err.log`. Turn it on when chasing a problem, off otherwise."),

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
              body: "Your clip history is kept **in memory for the session only** — quitting clears it. **Keep clipboard history** is the master switch: turn it off and TandemClip stops remembering clips entirely (the count and picker controls disappear with it). With it on, choose how many clips to remember and how many the picker shows. **Clear History Now** empties the list and also wipes the received-files cache from disk."),

        // MARK: Settings — AI
        .init(id: "ai-setup", category: "Settings — AI", title: "Setting up AI cleanup",
              body: "AI cleanup is optional — set it up once and the compose (✎) rewrites and Summarize/Ask actions light up. Pick a **provider preset** to fill the endpoint and a sensible default model, choose how it authenticates, then hit **Test Connection**.\n\nEvery call goes **directly from this Mac to the endpoint you chose** — there is no TandemClip server in between, and your API key is stored in the macOS Keychain, never synced to your other Macs.\n\nThree ways to connect (the preset sets this for you):\n- **API key / local server** — the usual path. Paste a key for a cloud provider, or point at a local server (Ollama, LM Studio, llama.cpp) where nothing leaves your Mac at all.\n- **ChatGPT sign-in (OAuth)** — run cleanup off a ChatGPT Plus/Pro subscription with no API key. See “Sign in with ChatGPT.”\n- **Azure OpenAI** — sends the key in an `api-key` header against your Azure resource URL.\n\nThere's a cap of **20,000 characters** per run — longer clips are trimmed before sending so a giant paste can't run up a huge request."),
        .init(id: "ai-providers", category: "Settings — AI", title: "Choosing a provider",
              body: "The preset dropdown is curated cost-first — OpenAI is there because most people start there; the rest are ways to spend less or stay local:\n- **Paid cloud:** OpenAI (gpt-4o-mini), Anthropic Claude, OpenRouter, Azure OpenAI, Groq (very cheap, fast), Together AI, Fireworks AI.\n- **Free tier:** GitHub Models (free personal tier — good for trying it out).\n- **Local & private:** Ollama, LM Studio, llama.cpp — these run on your own machine, so clip text never leaves it.\n- **No API key:** ChatGPT Plus/Pro via sign-in.\n\nPicking a preset also switches the auth mode to match. You can edit the endpoint and model afterward, or hand-configure any OpenAI-compatible service."),
        .init(id: "ai-chatgpt", category: "Settings — AI", title: "Sign in with ChatGPT",
              body: "If you pay for **ChatGPT Plus or Pro**, you can use that subscription for cleanup with no API key. Pick the “ChatGPT Plus/Pro (sign in — no API key)” preset and click Sign in — a browser window handles a standard OAuth sign-in with OpenAI, and TandemClip stores only the resulting token in the Keychain.\n\nOnce signed in, Settings shows your account email and plan, and a Sign Out button. The endpoint is fixed to OpenAI's Codex backend and isn't editable; only the model field is (default `gpt-5.4-mini`).\n\n**Automatic fallback:** if the sign-in token is later revoked or expires and you've set a fallback endpoint (see “Fallback endpoint”), cleanup quietly reroutes there instead of failing, and stays on the fallback until sign-in works again."),
        .init(id: "ai-presets", category: "Settings — AI", title: "Tone presets",
              body: "Each preset is a rewrite instruction: **Clean up**, **Email reply**, **Casual chat**, **Commit message**, **Summarize**, **Translate** — all editable, and you can add your own. Pick which one runs from the ▾ next to the button in compose."),
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
              body: "Restrict syncing to named Wi-Fi networks — nothing is shared on networks you haven't listed. On Ethernet or VPN there's no Wi-Fi name to verify, so by default sync pauses there; the **“Allow sync when Wi-Fi can't be verified”** toggle (off by default) lets it run anyway on those connections.\n\nmacOS only hands apps the exact Wi-Fi name if you grant **Location** permission. Without it, TandemClip guesses the network a rougher way, so if a network won't add or shows a placeholder name, granting Location (the app will prompt) fixes it."),

        // MARK: Privacy
        .init(id: "privacy-lan", category: "Private by design", title: "No cloud, no relay",
              body: "Peers talk directly over your LAN. There is no server, no account, and nothing to breach. The website only hosts downloads and updates."),
        .init(id: "privacy-passwords", category: "Private by design", title: "Password managers",
              body: "Content a password manager marks as secret is never synced — same for one-time and transient copies. This relies on the source app setting the marker (1Password, Keychain and most managers do); treat unmanaged secrets with care, or flip on the ✋ privacy hold first."),
        .init(id: "secret-guard", category: "Private by design", title: "Secret guard",
              body: "Copies that *look* like credentials are held on this Mac instead of syncing — a backstop for apps that don't mark passwords as concealed. It recognizes a lot: **API keys and tokens** (Stripe, GitHub, GitLab, Slack, AWS, Google, npm, Shopify, Hugging Face, DigitalOcean and more), **private keys**, **JWTs**, **payment-card numbers** (Luhn-checked), **IBANs**, `PASSWORD=…` / `api_key:…` assignments inside text, and lone high-entropy random tokens — all detected on-device, with obvious placeholders skipped.\n\nWhen a copy is held, the menu bar shows it and **“Send Held Clip Anyway”** releases that one; your next copy clears the hold automatically. Turn the whole feature on or off under Settings → Security."),
        .init(id: "privacy-quarantine", category: "Private by design", title: "Received files are quarantined",
              body: "Files that arrive from peers are written with restrictive permissions and macOS quarantine, and are revealed in Finder rather than auto-opened — you decide what runs."),

        // MARK: Troubleshooting
        .init(id: "ts-not-syncing", category: "Troubleshooting", title: "Not syncing?",
              body: "Check, in order:\n- Same **pairing code** on every Mac.\n- Same **Wi-Fi**, and that network is allowed under Settings → Security (on Ethernet/VPN, either allow the unverifiable-network toggle or grant Location).\n- Not **paused** (menu) and not in **privacy hold** (✋).\n- The sender's **role** isn't Receive only.\n- The clip isn't over the **size limit**, and it isn't being held by Secret guard.\n- With Trusted devices on, the target Mac is actually checked."),
        .init(id: "ts-peer-missing", category: "Troubleshooting", title: "A Mac won't appear",
              body: "Give it a moment after wake — peers rediscover automatically every few seconds. Make sure the two Macs don't share a display name, and that your network allows Bonjour (some guest networks block it)."),
        .init(id: "ts-updates", category: "Troubleshooting", title: "Stay current",
              body: "Use \"Check for Updates…\" in the menu. Updates are signed and verified; the app can't be tricked into downgrading."),
    ]

    static func topics(in category: String) -> [HelpTopic] {
        topics.filter { $0.category == category }
    }

    /// Release history, newest first. Curated from the shipped versions so
    /// each entry tells you what actually changed and when.
    static let releases: [HelpRelease] = [
        .init(version: "0.22.7", date: "July 3, 2026",
              highlight: "A friendly first run.",
              changes: [
                .init(.added, "New Macs get a Welcome window on first launch — a plain-English guide to what already works out of the box, the one pairing step to sync, and optional next steps to lock down security and turn on AI. Its buttons jump straight to the right Settings. Reopen it anytime from the menu bar ▸ Getting Started, or read the same guide in Help."),
              ]),
        .init(version: "0.22.6", date: "July 3, 2026",
              highlight: "A clearer smart-title mark.",
              changes: [
                .init(.improved, "Smart-titled clips now show a crisp accent ✨ sparkles icon in the picker instead of a tiny inline emoji — easier to spot and read in both light and dark mode."),
              ]),
        .init(version: "0.22.5", date: "July 3, 2026",
              highlight: "Smart titles that actually turn on.",
              changes: [
                .init(.fixed, "The automatic AI toggles — Smart titles, Translate incoming, Adapt tone — now stay disabled until “Enable AI text cleanup” is on. Before, you could switch them on while AI was off and they’d silently do nothing, so smart titles never appeared."),
              ]),
        .init(version: "0.22.4", date: "July 3, 2026",
              highlight: "Drag a clip out again.",
              changes: [
                .init(.fixed, "Dragging a clip out of the picker into Finder or another app works again — it used to just slide the whole window instead of lifting the clip."),
              ]),
        .init(version: "0.22.3", date: "July 3, 2026",
              highlight: "Clearer in dark mode.",
              changes: [
                .init(.fixed, "When a setting jumps you into Help, the highlighted spot is now clearly visible in dark mode too (it used to nearly vanish)."),
              ]),
        .init(version: "0.22.2", date: "July 3, 2026",
              highlight: "Help on the hover preview, too.",
              changes: [
                .init(.improved, "The hover preview card now has a ? that opens the “Hover previews & quick actions” article — help is a click away wherever you are in the picker."),
              ]),
        .init(version: "0.22.1", date: "July 3, 2026",
              highlight: "Help, right where you are.",
              changes: [
                .init(.added, "Help buttons in the clipboard picker — a ? in the footer, in compose, and on “Ask your clipboard” open the matching Help article, so guidance is one click away from the picker too."),
              ]),
        .init(version: "0.22.0", date: "July 3, 2026",
              highlight: "Settings that explain themselves.",
              changes: [
                .init(.added, "Every setting name in Settings is now a link — click it to jump straight to the exact spot in Help that explains it, not just the right page."),
              ]),
        .init(version: "0.21.4", date: "July 3, 2026",
              highlight: "Consistency, all the way down.",
              changes: [
                .init(.improved, "Finished bringing the clipboard picker onto the shared design scale — the same familiar layout, now fully consistent with the rest of the app."),
              ]),
        .init(version: "0.21.3", date: "July 3, 2026",
              highlight: "The whole app, one consistent look.",
              changes: [
                .init(.improved, "Rolled the design system across Settings and the picker — crisper corners and controls that use the brand color instead of system blue."),
              ]),
        .init(version: "0.21.2", date: "July 3, 2026",
              highlight: "A cleaner, more consistent look.",
              changes: [
                .init(.improved, "Polished the Help window to TandemClip's design system — consistent type and spacing, crisper cards, and a documented set of shared style tokens."),
              ]),
        .init(version: "0.21.1", date: "July 3, 2026",
              highlight: "Make yourself at home.",
              changes: [
                .init(.improved, "The Help window is now resizable, and reopens at the size and place you left it."),
              ]),
        .init(version: "0.21.0", date: "July 3, 2026",
              highlight: "A record of how we got here.",
              changes: [
                .init(.added, "This What's New page — every version of TandemClip, newest first."),
              ]),
        .init(version: "0.20.0", date: "July 3, 2026",
              highlight: "A help center you can actually navigate.",
              changes: [
                .init(.added, "Two-pane Help with left-hand navigation and search-by-meaning."),
                .init(.improved, "Expanded and corrected articles: appearance, the menu-bar menu, the full AI provider list, ChatGPT sign-in, and secret guard."),
              ]),
        .init(version: "0.19.0", date: "July 3, 2026",
              highlight: "Run AI cleanup off your ChatGPT subscription — no API key needed.",
              changes: [
                .init(.added, "Three ways to connect AI: API key / local server, Azure OpenAI, and Sign in with ChatGPT (OAuth)."),
                .init(.added, "Twelve curated provider presets, from free (GitHub Models) to fully local (Ollama, LM Studio, llama.cpp)."),
                .init(.improved, "If a ChatGPT sign-in token expires, cleanup quietly reroutes to your fallback endpoint instead of failing."),
              ]),
        .init(version: "0.18.0", date: "July 3, 2026",
              highlight: "Light, dark, or follow the system.",
              changes: [
                .init(.added, "Appearance setting under Settings → General — System, Light, or Dark, applied live."),
              ]),
        .init(version: "0.17.0", date: "July 3, 2026",
              highlight: "The intelligence bundle — a dozen features that make your history smarter and safer.",
              changes: [
                .init(.added, "Search by meaning, plus on-device text recognition (OCR) inside screenshots and images."),
                .init(.added, "Secret guard holds credential-shaped copies on this Mac instead of syncing them."),
                .init(.added, "Pinned clips, one-click quick actions, Ask your clipboard, and chunked transfer for large clips."),
                .init(.improved, "Live AI connection tests and more robust “Send to TandemClip” Services."),
              ]),
        .init(version: "0.16.0", date: "July 3, 2026",
              highlight: "AirDrop any clip to a nearby device.",
              changes: [
                .init(.added, "Share button in the picker AirDrops a clip to any nearby Apple device — even ones outside your pairing group."),
              ]),
        .init(version: "0.15.0", date: "July 3, 2026",
              highlight: "A warmer look and richer drag-and-drop.",
              changes: [
                .init(.improved, "Adopted tonebox's design system — terracotta accent, tuned motion, honest toasts."),
                .init(.added, "Drag emails from Outlook/Mail, photos from Photos, and images from a browser straight onto the picker."),
              ]),
        .init(version: "0.14.0", date: "July 3, 2026",
              highlight: "Folder sync and a straighter story about what's happening.",
              changes: [
                .init(.added, "Folders travel between Macs as .zip archives, on copy or drop."),
                .init(.improved, "Help overhaul, honest sync toasts, and a refreshed security audit."),
              ]),
        .init(version: "0.13.0", date: "July 3, 2026",
              highlight: "Receive without lifting a finger.",
              changes: [
                .init(.added, "“Apply incoming clips automatically” lands peers' copies on this clipboard even in Manual mode."),
                .init(.improved, "Bullet-list descriptions on every settings section; compose keeps focus."),
              ]),
        .init(version: "0.12.0", date: "July 2, 2026",
              highlight: "Previews, and a calmer picker.",
              changes: [
                .init(.added, "QuickLook hover previews for images, PDFs, Office docs, and video."),
                .init(.improved, "The picker is transient unless pinned, Esc always closes it, and an abandoned compose draft is discarded."),
              ]),
        .init(version: "0.11.0", date: "July 2, 2026",
              highlight: "Settings, reorganized.",
              changes: [
                .init(.improved, "Sidebar navigation in Settings and unified dropdown controls."),
              ]),
        .init(version: "0.10.0", date: "July 2, 2026",
              highlight: "AI text cleanup arrives.",
              changes: [
                .init(.added, "AI cleanup suite — tone presets, auto-tone by destination app, provenance, and a fallback endpoint."),
                .init(.added, "Audio & Video groups in the picker."),
              ]),
        .init(version: "0.9.0", date: "July 2, 2026",
              highlight: "Privacy hold and pins.",
              changes: [
                .init(.added, "Privacy hold (✋) stops copies from leaving this Mac; pin (📌) keeps the picker open."),
                .init(.improved, "Reorganized menu-bar menu and smaller storage options."),
              ]),
        .init(version: "0.8.0", date: "July 2, 2026",
              highlight: "Storage you control.",
              changes: [
                .init(.added, "Configurable received-files storage limit with per-item sizes."),
              ]),
        .init(version: "0.5.0", date: "July 2, 2026",
              highlight: "A picker that organizes itself.",
              changes: [
                .init(.added, "Collapsible per-Mac groups with content-type badges, sub-sections, and group totals."),
              ]),
        .init(version: "0.4.0", date: "July 2, 2026",
              highlight: "Delete everywhere.",
              changes: [
                .init(.added, "Remove a clip from history on every Mac at once, with signed, replay-proof deletes."),
                .init(.fixed, "Relay-echo transport bug; activate the app before a user-initiated update check."),
              ]),
        .init(version: "0.3.0", date: "July 2, 2026",
              highlight: "Drop to share.",
              changes: [
                .init(.added, "Drag files from Finder onto the picker to send them; file copies are always captured to history."),
              ]),
        .init(version: "0.1.4", date: "July 2, 2026",
              highlight: "More than plain text.",
              changes: [
                .init(.added, "Rich text and image sync, file sync by content, and session clipboard history."),
                .init(.improved, "Wired Sentry crash reporting (opt-in, PII-scrubbed)."),
              ]),
        .init(version: "0.1.1", date: "July 2, 2026",
              highlight: "Secure by default, from the first build.",
              changes: [
                .init(.added, "In-app pairing-code entry with live re-keying."),
                .init(.improved, "Pairing code stored in the Keychain; encryption key derived via HKDF-SHA256."),
              ]),
    ]
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

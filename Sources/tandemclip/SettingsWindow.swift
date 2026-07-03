import SwiftUI
import AppKit

/// Observable bridge over `Config`: each property mirrors a setting and writes
/// back through on change (persisting to UserDefaults + posting Config.didChange).
final class SettingsModel: ObservableObject {
    let config: Config
    let engine: SyncEngine

    @Published var mode: SyncMode { didSet { config.mode = mode } }
    @Published var previewLevel: PreviewLevel { didSet { config.previewLevel = previewLevel } }
    @Published var role: Role { didSet { config.role = role } }
    @Published var maxMB: Double { didSet { config.maxClipBytes = Int(maxMB * 1_000_000); engine.applyConfig() } }
    @Published var autoApplyIncoming: Bool = false { didSet { config.autoApplyIncoming = autoApplyIncoming } }
    @Published var syncRichText: Bool { didSet { config.syncRichText = syncRichText } }
    @Published var syncImages: Bool { didSet { config.syncImages = syncImages } }
    @Published var syncFiles: Bool { didSet { config.syncFiles = syncFiles } }
    @Published var receivedCacheMB: Int {
        didSet {
            config.receivedCacheCap = receivedCacheMB * 1_000_000
            engine.applyConfig()   // lowering the cap evicts immediately
            cacheUsage = engine.watcher.receivedCacheUsage()
        }
    }
    /// Current on-disk size of the received-files cache (for the readout).
    @Published var cacheUsage: Int = 0

    /// Wipe history + the received-files cache (was the menu's "Clear history";
    /// the menu History submenu is gone — the picker owns browsing).
    func clearHistory() {
        engine.clearHistory()
        cacheUsage = engine.watcher.receivedCacheUsage()
    }

    // MARK: AI settings

    @Published var aiEnabled: Bool = false { didSet { config.aiEnabled = aiEnabled } }
    @Published var aiEndpoint: String = "" { didSet { config.aiEndpoint = aiEndpoint } }
    @Published var aiModel: String = "" { didSet { config.aiModel = aiModel } }
    @Published var aiKey: String = "" { didSet { config.aiAPIKey = aiKey } }   // Keychain-backed
    @Published var aiAutoTone: Bool = true { didSet { config.aiAutoTone = aiAutoTone } }
    @Published var aiFallbackEndpoint: String = "" { didSet { config.aiFallbackEndpoint = aiFallbackEndpoint } }
    @Published var aiFallbackModel: String = "" { didSet { config.aiFallbackModel = aiFallbackModel } }
    @Published var aiFallbackKey: String = "" { didSet { config.aiFallbackAPIKey = aiFallbackKey } }
    /// Result of the last "Test connection" probe (nil = not run yet).
    @Published var aiProbe: (ok: Bool, message: String)?
    @Published var aiProbing = false

    // Tone presets: the whole list persists on every edit; `aiEditingID`
    // selects which one the editor fields show.
    @Published var aiPresets: [AIPreset] = [] { didSet { if !aiPresets.isEmpty { config.aiPresets = aiPresets } } }
    @Published var aiEditingID: String = "cleanup"

    var aiEditingIndex: Int? { aiPresets.firstIndex { $0.id == aiEditingID } }

    func addAIPreset() {
        let p = AIPreset(id: UUID().uuidString, name: "New preset",
                         prompt: "Rewrite this text… Output only the rewritten text.")
        aiPresets.append(p)
        aiEditingID = p.id
    }

    func deleteAIPreset() {
        guard aiPresets.count > 1, let i = aiEditingIndex else { return }   // keep at least one
        aiPresets.remove(at: i)
        aiEditingID = aiPresets.first!.id
    }

    func restoreBundledPresets() {
        aiPresets = AIPreset.bundled
        aiEditingID = "cleanup"
    }

    func applyPreset(_ p: AIProviderPreset) {
        aiEndpoint = p.endpoint
        aiModel = p.model
        aiProbe = nil
    }

    /// Real end-to-end probe, tonebox-style: tiny request, report latency.
    func testAIConnection() {
        guard let client = AIClient.fromConfig(config) ?? forcedClient() else {
            aiProbe = (false, "Enter an endpoint URL and model first.")
            return
        }
        aiProbing = true; aiProbe = nil
        let start = Date()
        Task { @MainActor in
            do {
                let reply = try await client.complete(
                    [.init(role: .user, content: "Reply with the single word OK.")])
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                aiProbe = (true, "OK · \(ms) ms · \(reply.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))")
            } catch {
                aiProbe = (false, AIClient.friendlyMessage(for: error))
            }
            aiProbing = false
        }
    }

    /// The probe should work even while the feature toggle is still off.
    private func forcedClient() -> AIClient? {
        guard let url = URL(string: aiEndpoint), !aiModel.isEmpty else { return nil }
        guard AIClient.isAcceptableEndpoint(url) else {
            aiProbe = (false, "Plain http is only allowed for local/LAN endpoints — use https for anything on the internet.")
            return nil
        }
        return AIClient(endpoint: url, model: aiModel, apiKey: aiKey)
    }

    @Published var launchAtLogin: Bool { didSet { config.launchAtLogin = launchAtLogin; LaunchAtLogin.set(launchAtLogin) } }
    @Published var startPaused: Bool { didSet { config.startPaused = startPaused } }
    @Published var verboseLogging: Bool { didSet { config.verboseLogging = verboseLogging; Log.verbose = verboseLogging } }
    @Published var historyEnabled: Bool { didSet { config.historyEnabled = historyEnabled } }
    @Published var historyKeep: Int { didSet { config.historyLimit = historyKeep } }
    @Published var pickerShow: Int { didSet { config.pickerShowCount = pickerShow } }

    @Published var deviceDisplayName: String { didSet { config.deviceDisplayName = deviceDisplayName } }
    @Published var pairingCode: String

    @Published var allowlistEnabled: Bool { didSet { config.allowlistEnabled = allowlistEnabled } }
    @Published var networkAllowlistEnabled: Bool { didSet { config.networkAllowlistEnabled = networkAllowlistEnabled } }
    @Published var allowedSSIDs: [String] { didSet { config.allowedSSIDs = allowedSSIDs } }
    @Published var wifiFailOpen: Bool { didSet { config.wifiFailOpen = wifiFailOpen } }

    init(config: Config, engine: SyncEngine) {
        self.config = config
        self.engine = engine
        mode = config.mode
        previewLevel = config.previewLevel
        role = config.role
        maxMB = Double(config.maxClipBytes) / 1_000_000
        autoApplyIncoming = config.autoApplyIncoming
        syncRichText = config.syncRichText
        syncImages = config.syncImages
        syncFiles = config.syncFiles
        receivedCacheMB = config.receivedCacheCap / 1_000_000
        cacheUsage = engine.watcher.receivedCacheUsage()
        aiEnabled = config.aiEnabled
        aiEndpoint = config.aiEndpoint
        aiModel = config.aiModel
        aiKey = config.aiAPIKey
        aiAutoTone = config.aiAutoTone
        aiFallbackEndpoint = config.aiFallbackEndpoint
        aiFallbackModel = config.aiFallbackModel
        aiFallbackKey = config.aiFallbackAPIKey
        aiPresets = config.aiPresets
        aiEditingID = config.aiPresets.first?.id ?? "cleanup"
        launchAtLogin = config.launchAtLogin
        startPaused = config.startPaused
        verboseLogging = config.verboseLogging
        historyEnabled = config.historyEnabled
        historyKeep = config.historyLimit
        pickerShow = config.pickerShowCount
        deviceDisplayName = config.deviceDisplayName
        pairingCode = config.pairingCode
        activeCode = config.pairingCode
        allowlistEnabled = config.allowlistEnabled
        networkAllowlistEnabled = config.networkAllowlistEnabled
        allowedSSIDs = config.allowedSSIDs
        wifiFailOpen = config.wifiFailOpen
    }

    /// The code the transport is currently keyed with (to detect edits).
    @Published var activeCode: String

    func applyPairingCode() {
        let code = Config.normalizedPairingCode(pairingCode)
        guard !code.isEmpty, code != activeCode else { return }
        guard Config.isAcceptablePairingCode(code) else { return }
        pairingCode = code
        config.setPairingCode(code)
        engine.reloadPairing()          // re-key transport live — no relaunch
        activeCode = code
    }

    func regeneratePairingCode() {
        let c = Config.generateCode()
        pairingCode = c
        config.setPairingCode(c)
        engine.reloadPairing()
        activeCode = c
    }

    func copyPairingCode() {
        SecretPasteboard.copy(activeCode)
    }
    /// Status shown under the Wi-Fi list after an add attempt.
    @Published var ssidHint = ""
    /// Manual network-name entry (bypasses auto-detection quirks e.g. hotspots).
    @Published var newSSID = ""

    func addSSIDManually() {
        let s = newSSID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        if !allowedSSIDs.contains(s) { allowedSSIDs.append(s) }
        ssidHint = "Added “\(s)”."
        newSSID = ""
    }

    func addCurrentSSID() {
        guard let s = NetworkGuard.currentSSID(), !s.isEmpty else {
            ssidHint = "Couldn't read the Wi-Fi name — are you connected to Wi-Fi (not Ethernet/VPN)?"
            return
        }
        // Add the current network so sync is allowed on it. If the OS scrubbed
        // the name to a "<…>" placeholder (some environments do), it still gets
        // added (hidden from the list) and matches the guard — just don't reveal
        // the placeholder text in the confirmation.
        let scrubbed = s.hasPrefix("<")
        if allowedSSIDs.contains(s) {
            ssidHint = scrubbed ? "Current network is already allowed." : "“\(s)” is already in the list."
        } else {
            allowedSSIDs.append(s)
            ssidHint = scrubbed ? "Added the current network." : "Added “\(s)”."
        }
    }
    func removeSSID(_ ssid: String) {
        allowedSSIDs.removeAll { $0 == ssid }
    }

    var pairingCodeDirty: Bool {
        let c = Config.normalizedPairingCode(pairingCode)
        return Config.isAcceptablePairingCode(c) && c != activeCode
    }
}

/// Presents the SwiftUI settings in a window from the menu-bar-only app.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model: SettingsModel

    init(config: Config, engine: SyncEngine) {
        model = SettingsModel(config: config, engine: engine)
    }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(model: model))
            let w = NSWindow(contentViewController: hosting)
            w.title = "TandemClip Settings"
            // Resizable, tonebox-style: sidebar + roomy detail pane; the
            // user can size it to taste and the frame is remembered.
            w.styleMask = [.titled, .closable, .resizable]
            w.minSize = NSSize(width: 680, height: 480)
            // Default 20% roomier than the minimum; the autosaved frame wins
            // on later opens once the user resizes.
            w.setContentSize(NSSize(width: 816, height: 576))
            w.setFrameAutosaveName("TandemClipSettings")
            w.isReleasedWhenClosed = false
            w.delegate = self
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        if window?.frameAutosaveName.isEmpty ?? true { window?.center() }
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }
}

/// Bullet-list section footer: one line per setting — bold setting name, plain
/// explanation, hanging indent — instead of a wall of prose.
struct SettingsBullets: View {
    let items: [(term: String, text: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(items, id: \.term) { item in
                HStack(alignment: .top, spacing: 6) {
                    Text("•")
                    (Text(item.term).fontWeight(.semibold) + Text(" — ") + Text(item.text))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// The house dropdown for Settings rows: a compact menu button pinned to the
/// row's trailing edge whose label always reads the current selection (with a
/// checkmark on it inside the menu). Replaces Form's default Picker so every
/// dropdown shares one look.
struct SettingsDropdown<Value: Hashable>: View {
    let title: String
    let options: [(value: Value, label: String)]
    @Binding var selection: Value
    /// Shown when the selection matches no option (e.g. hand-edited fields).
    var fallbackLabel = "Choose…"

    private var currentLabel: String {
        options.first { $0.value == selection }?.label ?? fallbackLabel
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Menu {
                ForEach(options, id: \.value) { opt in
                    Button {
                        selection = opt.value
                    } label: {
                        if opt.value == selection {
                            Label(opt.label, systemImage: "checkmark")
                        } else {
                            Text(opt.label)
                        }
                    }
                }
            } label: {
                Text(currentLabel)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @State private var peers: [(id: String, clip: PeerClip)] = []
    @State private var currentSSID: String = ""
    @State private var tab: Tab = .general

    enum Tab: String, CaseIterable, Identifiable {
        case general = "General", sync = "Sync", content = "Content", ai = "AI", security = "Security"
        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .general:  return "gearshape"
            case .sync:     return "arrow.triangle.2.circlepath"
            case .content:  return "doc.on.clipboard"
            case .ai:       return "sparkles"
            case .security: return "lock.shield"
            }
        }
    }

    /// Sidebar navigation (tonebox's Settings layout): categories on the left,
    /// detail pane on the right, both growing with the resizable window. The
    /// selected pane persists across closes.
    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 180)
            Divider()
            Group {
                switch tab {
                case .general:  generalTab
                case .sync:     syncTab
                case .content:  contentTab
                case .ai:       aiTab
                case .security: securityTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 680, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
        .onAppear {
            if let saved = UserDefaults.standard.string(forKey: "settingsSelectedTab"),
               let t = Tab(rawValue: saved) { tab = t }
        }
        .onChange(of: tab) { t in
            UserDefaults.standard.set(t.rawValue, forKey: "settingsSelectedTab")
        }
    }

    private var sidebar: some View {
        List(selection: $tab) {
            ForEach(Tab.allCases) { t in
                Label(t.rawValue, systemImage: t.symbol)
                    .tag(t)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    // MARK: General — startup, this Mac, diagnostics

    private var generalTab: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $model.launchAtLogin)
                Toggle("Start paused", isOn: $model.startPaused)
            } header: {
                Text("Startup")
            } footer: {
                SettingsBullets(items: [
                    ("Launch at login", "open TandemClip automatically when you log in."),
                    ("Start paused", "launch with syncing off until you hit Resume in the menu — nothing is shared right after boot."),
                ])
            }
            Section {
                TextField("Display name", text: $model.deviceDisplayName,
                          prompt: Text(Host.current().localizedName ?? "Mac"))
            } header: {
                Text("This Mac")
            } footer: {
                SettingsBullets(items: [
                    ("Display name", "the name your other Macs see for this computer."),
                ])
            }
            Section {
                Toggle("Verbose logging", isOn: $model.verboseLogging)
            } header: {
                Text("Diagnostics")
            } footer: {
                SettingsBullets(items: [
                    ("Verbose logging", "records detailed activity (connections, syncs) to /tmp/tandemclip.err.log — useful when chasing a problem, otherwise leave it off."),
                ])
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Sync — behavior + limits

    private var syncTab: some View {
        Form {
            Section {
                SettingsDropdown(title: "Mode", options: [
                    (SyncMode.mirror, "Mirror — auto-sync"),
                    (SyncMode.manual, "Manual — pull on demand"),
                ], selection: $model.mode)
                SettingsDropdown(title: "This Mac's role", options: [
                    (Role.sendReceive, "Send & receive"),
                    (Role.receiveOnly, "Receive only"),
                    (Role.sendOnly, "Send only"),
                ], selection: $model.role)
                SettingsDropdown(title: "Peer preview", options: [
                    (PreviewLevel.metadata, "Metadata — age + size"),
                    (PreviewLevel.preview, "Live text preview"),
                    (PreviewLevel.names, "Names only"),
                ], selection: $model.previewLevel)
                Toggle("Apply incoming clips automatically", isOn: $model.autoApplyIncoming)
                    .disabled(model.mode == .mirror)
            } header: {
                Text("Behavior")
            } footer: {
                SettingsBullets(items: [
                    ("Mode", "Mirror sends every copy to your other Macs the moment you copy it. Manual keeps your copies here until another Mac asks for them."),
                    ("This Mac's role", "limits direction. Receive only never sends anything from this Mac; Send only never takes anything in."),
                    ("Peer preview", "what other Macs can see about your current clip before pulling it: just its age and size, a snippet of the text, or nothing at all."),
                    ("Apply incoming clips automatically", "clips copied on your other Macs land on this clipboard by themselves. Mirror always does this; turn it on to get the same in Manual mode."),
                ])
            }
            Section {
                SettingsDropdown(title: "Max clipboard size",
                                 options: [1.0, 2.0, 5.0, 10.0, 25.0].map { ($0, "\(Int($0)) MB") },
                                 selection: $model.maxMB)
            } header: {
                Text("Limits")
            } footer: {
                SettingsBullets(items: [
                    ("Max clipboard size", "the biggest clip that will sync. Anything larger falls back to just its plain text, or is skipped entirely if there's no text."),
                ])
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Content — what to sync + history/picker

    private var contentTab: some View {
        Form {
            Section {
                Toggle("Rich text", isOn: $model.syncRichText)
                Toggle("Images", isOn: $model.syncImages)
                Toggle("Files (by content)", isOn: $model.syncFiles)
            } header: {
                Text("What to sync")
            } footer: {
                SettingsBullets(items: [
                    ("Plain text", "always syncs — it can't be turned off."),
                    ("Rich text / Images", "each copy carries every enabled representation, so pasting on the other Mac keeps full formatting."),
                    ("Files (by content)", "whether copied files are sent to your Macs automatically. Even when off, file copies land in your history and can still be pulled or drop-shared."),
                ])
            }
            Section {
                SettingsDropdown(title: "Received-files limit",
                                 options: [10, 25, 50, 100, 200, 500, 1000].map {
                                     ($0, $0 >= 1000 ? "\($0 / 1000) GB" : "\($0) MB")
                                 },
                                 selection: $model.receivedCacheMB)
            } header: {
                Text("Storage")
            } footer: {
                SettingsBullets(items: [
                    ("Received-files limit", "files from your Macs are cached on disk so paste keeps working — currently \(ByteCountFormatter.string(fromByteCount: Int64(model.cacheUsage), countStyle: .file)) of \(model.receivedCacheMB >= 1000 ? "\(model.receivedCacheMB / 1000) GB" : "\(model.receivedCacheMB) MB"). Past the limit the oldest clips are removed automatically; picking them from history brings them back."),
                ])
            }
            Section {
                Toggle("Keep clipboard history", isOn: $model.historyEnabled)
                if model.historyEnabled {
                    SettingsDropdown(title: "Keep in history",
                                     options: [10, 20, 50, 100, 150, 200].map { ($0, "\($0) clips") },
                                     selection: $model.historyKeep)
                    SettingsDropdown(title: "Show in picker",
                                     options: [5, 8, 10, 12, 15, 20, 30, 50].map { ($0, "\($0) clips") },
                                     selection: $model.pickerShow)
                    Button("Clear History Now") { model.clearHistory() }
                }
            } header: {
                Text("History")
            } footer: {
                SettingsBullets(items: [
                    ("Keep clipboard history", "remember recent clips for this session (in memory only — cleared when the app quits). Browse them in the picker with ⇧⌘V."),
                    ("Keep in history / Show in picker", "how many clips are remembered, and how many of those the picker lists."),
                    ("Clear History Now", "wipes the session history and the received-files cache from disk."),
                ])
            }
        }
        .formStyle(.grouped)
    }

    // MARK: AI — bring-your-own-LLM text cleanup (tonebox pattern)

    private var aiTab: some View {
        Form {
            Section {
                Toggle("Enable AI text cleanup", isOn: $model.aiEnabled)
            } footer: {
                SettingsBullets(items: [
                    ("Enable AI text cleanup", "adds a compose area to the picker (✎) where AI rewrites text to be cleaner and more readable before you copy it. Calls go directly from this Mac to the endpoint below — there is no middleman."),
                ])
            }
            Section {
                // Applying a preset fills the fields below; the label reflects
                // whichever provider the current fields match ("Custom" if
                // they've been hand-edited).
                SettingsDropdown(title: "Provider preset",
                                 options: AIProviderPreset.all.map { ($0.id, $0.name) },
                                 selection: Binding(
                                     get: {
                                         AIProviderPreset.all.first {
                                             $0.endpoint == model.aiEndpoint
                                                 && ($0.model.isEmpty || $0.model == model.aiModel)
                                         }?.id ?? "custom"
                                     },
                                     set: { id in
                                         if let p = AIProviderPreset.all.first(where: { $0.id == id }) {
                                             model.applyPreset(p)
                                         }
                                     }),
                                 fallbackLabel: model.aiEndpoint.isEmpty ? "Choose…" : "Custom")
                TextField("Endpoint URL", text: $model.aiEndpoint,
                          prompt: Text("https://api…/v1/chat/completions"))
                    .autocorrectionDisabled()
                TextField("Model", text: $model.aiModel, prompt: Text("e.g. claude-haiku-4-5-20251001"))
                    .autocorrectionDisabled()
                SecureField("API key", text: $model.aiKey,
                            prompt: Text("empty is fine for local servers"))
                HStack {
                    Button(model.aiProbing ? "Testing…" : "Test Connection") { model.testAIConnection() }
                        .disabled(model.aiProbing)
                    if let probe = model.aiProbe {
                        Image(systemName: probe.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(probe.ok ? .green : .red)
                        Text(probe.message).font(.system(size: 11)).foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                }
            } header: {
                Text("Endpoint")
            } footer: {
                SettingsBullets(items: [
                    ("Provider preset", "fills the fields below for a known provider. Any OpenAI-compatible server works — a local Ollama / LM Studio keeps text entirely on your machine."),
                    ("Endpoint URL / Model", "where requests go and which model handles them."),
                    ("API key", "stored in the Keychain, never in preferences. Local servers usually need none."),
                    ("Test Connection", "sends a tiny real request and reports the round-trip time."),
                ])
            }
            Section {
                SettingsDropdown(title: "Preset",
                                 options: model.aiPresets.map { ($0.id, $0.name) },
                                 selection: $model.aiEditingID)
                if let i = model.aiEditingIndex {
                    TextField("Name", text: Binding(
                        get: { model.aiPresets[i].name },
                        set: { model.aiPresets[i].name = $0 }))
                    TextEditor(text: Binding(
                        get: { model.aiPresets[i].prompt },
                        set: { model.aiPresets[i].prompt = $0 }))
                        .font(.system(size: 11.5))
                        .frame(minHeight: 96)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.06)))
                }
                HStack {
                    Button("Add Preset") { model.addAIPreset() }
                    Button("Delete") { model.deleteAIPreset() }
                        .disabled(model.aiPresets.count <= 1)
                    Spacer()
                    Button("Restore Bundled Presets") { model.restoreBundledPresets() }
                }
            } header: {
                Text("Tone presets")
            } footer: {
                SettingsBullets(items: [
                    ("Tone presets", "each is a rewrite instruction the compose area can apply — Clean up, Email reply, Summarize, Translate, or your own. Edit the prompt here; pick which to run from the compose area."),
                    ("Input cap", "at most \(Config.aiMaxInputChars / 1000)k characters are sent per run, so a giant clip can't become a giant bill."),
                ])
            }
            Section {
                Toggle("Adapt tone to the destination app", isOn: $model.aiAutoTone)
            } footer: {
                SettingsBullets(items: [
                    ("Adapt tone to the destination app", "the rewrite is steered by the app you opened the picker over — professional for email, casual for chat, literal for code editors and terminals, structured prose for notes."),
                ])
            }
            Section {
                TextField("Fallback endpoint URL", text: $model.aiFallbackEndpoint,
                          prompt: Text("optional — e.g. a cloud endpoint behind local Ollama"))
                    .autocorrectionDisabled()
                TextField("Fallback model", text: $model.aiFallbackModel)
                    .autocorrectionDisabled()
                SecureField("Fallback API key", text: $model.aiFallbackKey)
            } header: {
                Text("Fallback")
            } footer: {
                SettingsBullets(items: [
                    ("Fallback endpoint", "tried once when the primary fails with a rate limit, server error, or network problem before producing any output. Config mistakes (bad key, wrong model) don't fail over — they'd fail everywhere."),
                ])
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Security — pairing, trusted devices, Wi-Fi

    private var securityTab: some View {
        Form {
            Section {
                TextField("Pairing code", text: $model.pairingCode)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit { model.applyPairingCode() }
                HStack {
                    Button("Copy") { model.copyPairingCode() }
                    Button("Regenerate") { model.regeneratePairingCode() }
                    Spacer()
                    Button("Apply") { model.applyPairingCode() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.pairingCodeDirty)
                }
            } header: {
                Text("Pairing code")
            } footer: {
                SettingsBullets(items: [
                    ("Pairing code", "the shared secret that encrypts everything. Enter the same code on every Mac you want in the group."),
                    ("Apply", "re-keys the connection immediately — peers drop until they also have the new code (no relaunch needed)."),
                    ("Regenerate", "makes a fresh strong code; copy it to your other Macs afterwards."),
                ])
            }

            Section {
                Toggle("Only sync with trusted devices", isOn: $model.allowlistEnabled)
                if model.allowlistEnabled {
                    if peers.isEmpty {
                        Text("No devices seen yet.").foregroundColor(.secondary)
                    } else {
                        ForEach(peers, id: \.id) { peer in
                            Toggle(isOn: Binding(
                                get: { peer.clip.publicKey != nil && model.config.trustedDevices[peer.id] == peer.clip.publicKey },
                                set: { model.config.setTrusted(peer.id, publicKey: peer.clip.publicKey, trusted: $0) }
                            )) {
                                HStack(spacing: 7) {
                                    Circle().fill(model.engine.isSynced(peer.id) ? Color.green : Color.secondary.opacity(0.4))
                                        .frame(width: 7, height: 7)
                                    Text(peer.clip.name)
                                }
                            }
                            .disabled(peer.clip.publicKey == nil)
                        }
                    }
                }
            } header: {
                Text("Trusted devices")
            } footer: {
                SettingsBullets(items: [
                    ("Only sync with trusted devices", model.allowlistEnabled
                        ? "on — only the devices you check can sync. Unchecking one revokes it immediately, even if it still knows the pairing code: the safe way to cut off a Mac you've stopped using."
                        : "off — any Mac with the pairing code can sync. Turn this on to pin specific devices and revoke one without changing the code everywhere."),
                ])
            }

            Section {
                Toggle("Sync only on selected Wi-Fi networks", isOn: $model.networkAllowlistEnabled)
                // Only show the current network when we actually have a real
                // name — hidden when it can't be read (empty, or a "<…>"
                // placeholder, e.g. an environment that scrubs Wi-Fi names).
                if !currentSSID.isEmpty && !currentSSID.hasPrefix("<") {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Current network").font(.caption).foregroundColor(.secondary)
                        Text(currentSSID)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if model.networkAllowlistEnabled {
                    if model.allowedSSIDs.isEmpty {
                        Label("No networks added — sync is paused until you add one.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundColor(.orange)
                    }
                    ForEach(model.allowedSSIDs, id: \.self) { ssid in
                        let hidden = ssid.hasPrefix("<")
                        HStack(alignment: .top) {
                            Image(systemName: "wifi").foregroundColor(.secondary)
                            Text(hidden ? "This network (name hidden on this Mac)" : ssid)
                                .foregroundColor(hidden ? .secondary : .primary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)   // full name, wrap if long
                            Spacer()
                            Button { model.removeSSID(ssid) } label: {
                                Image(systemName: "minus.circle.fill").foregroundColor(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help("Remove this network")
                        }
                    }
                    Button { model.addCurrentSSID() } label: {
                        Label("Add current network", systemImage: "plus")
                    }
                    HStack {
                        TextField("Or type a network name…", text: $model.newSSID)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { model.addSSIDManually() }
                        Button("Add") { model.addSSIDManually() }
                            .disabled(model.newSSID.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if !model.ssidHint.isEmpty {
                        Text(model.ssidHint).font(.caption).foregroundColor(.secondary)
                    }
                    Toggle("Allow sync when Wi-Fi can’t be verified", isOn: $model.wifiFailOpen)
                }
            } header: {
                Text("Wi-Fi networks")
            } footer: {
                SettingsBullets(items: [
                    ("Wi-Fi networks", "when the list is on, sync runs only on these networks — nothing is shared on coffee-shop Wi-Fi you haven't listed."),
                    ("Allow sync when Wi-Fi can't be verified", "on Ethernet or VPN there's no network name to match, so sync pauses by default; turn this on to allow it there instead."),
                ])
            }
        }
        .formStyle(.grouped)
        .onAppear {
            refreshSecurity()
            // Ask for Location so CoreWLAN can return the exact SSID (the name
            // other apps/System Settings show). Without it we fall back to
            // ipconfig, which can differ. Re-read once the user responds.
            LocationAuthorizer.shared.ensureAuthorized { _ in
                DispatchQueue.main.async { refreshSecurity() }
            }
        }
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in
            refreshSecurity()   // keep the peer list + current network live while open
        }
    }

    private func refreshSecurity() {
        peers = model.engine.sortedPeers()
        // Reading the SSID may shell out to ipconfig — do it off the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            let ssid = NetworkGuard.currentSSID() ?? ""
            DispatchQueue.main.async { if ssid != currentSSID { currentSSID = ssid } }
        }
    }
}

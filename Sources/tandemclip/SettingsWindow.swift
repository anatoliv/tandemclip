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
    @Published var syncRichText: Bool { didSet { config.syncRichText = syncRichText } }
    @Published var syncImages: Bool { didSet { config.syncImages = syncImages } }

    @Published var launchAtLogin: Bool { didSet { config.launchAtLogin = launchAtLogin; LaunchAtLogin.set(launchAtLogin) } }
    @Published var startPaused: Bool { didSet { config.startPaused = startPaused } }
    @Published var verboseLogging: Bool { didSet { config.verboseLogging = verboseLogging; Log.verbose = verboseLogging } }

    @Published var deviceDisplayName: String { didSet { config.deviceDisplayName = deviceDisplayName } }
    @Published var pairingCode: String

    @Published var allowlistEnabled: Bool { didSet { config.allowlistEnabled = allowlistEnabled } }
    @Published var networkAllowlistEnabled: Bool { didSet { config.networkAllowlistEnabled = networkAllowlistEnabled } }
    @Published var allowedSSIDs: [String] { didSet { config.allowedSSIDs = allowedSSIDs } }

    init(config: Config, engine: SyncEngine) {
        self.config = config
        self.engine = engine
        mode = config.mode
        previewLevel = config.previewLevel
        role = config.role
        maxMB = Double(config.maxClipBytes) / 1_000_000
        syncRichText = config.syncRichText
        syncImages = config.syncImages
        launchAtLogin = config.launchAtLogin
        startPaused = config.startPaused
        verboseLogging = config.verboseLogging
        deviceDisplayName = config.deviceDisplayName
        pairingCode = config.pairingCode
        activeCode = config.pairingCode
        allowlistEnabled = config.allowlistEnabled
        networkAllowlistEnabled = config.networkAllowlistEnabled
        allowedSSIDs = config.allowedSSIDs
    }

    /// The code the transport is currently keyed with (to detect edits).
    @Published var activeCode: String

    func applyPairingCode() {
        let code = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty, code != activeCode else { return }
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
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(activeCode, forType: .string)
    }
    func addCurrentSSID() {
        if let s = NetworkGuard.currentSSID(), !s.isEmpty, !allowedSSIDs.contains(s) { allowedSSIDs.append(s) }
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
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @State private var peers: [(id: String, clip: PeerClip)] = []

    var body: some View {
        TabView {
            syncTab.tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
            startupTab.tabItem { Label("Startup", systemImage: "power") }
            identityTab.tabItem { Label("Identity", systemImage: "person.crop.circle") }
            securityTab.tabItem { Label("Security", systemImage: "lock.shield") }
        }
        .frame(width: 460, height: 380)
        .padding()
    }

    private var syncTab: some View {
        Form {
            Picker("Mode", selection: $model.mode) {
                Text("Mirror (auto-sync)").tag(SyncMode.mirror)
                Text("Manual (pull on demand)").tag(SyncMode.manual)
            }
            Picker("This Mac's role", selection: $model.role) {
                Text("Send & Receive").tag(Role.sendReceive)
                Text("Receive only").tag(Role.receiveOnly)
                Text("Send only").tag(Role.sendOnly)
            }
            Picker("Peer preview", selection: $model.previewLevel) {
                Text("Metadata (age + size)").tag(PreviewLevel.metadata)
                Text("Live text preview").tag(PreviewLevel.preview)
                Text("Names only").tag(PreviewLevel.names)
            }
            Picker("Max clipboard size", selection: $model.maxMB) {
                Text("1 MB").tag(1.0)
                Text("2 MB").tag(2.0)
                Text("5 MB").tag(5.0)
                Text("10 MB").tag(10.0)
                Text("25 MB").tag(25.0)
            }
            Divider()
            Toggle("Sync rich text", isOn: $model.syncRichText)
            Toggle("Sync images", isOn: $model.syncImages)
            Text("Plain text always syncs. Copies carry every enabled representation so paste keeps full fidelity. Content over the size limit falls back to text only.")
                .font(.caption).foregroundColor(.secondary)
        }
    }

    private var startupTab: some View {
        Form {
            Toggle("Launch at login", isOn: $model.launchAtLogin)
            Toggle("Start paused", isOn: $model.startPaused)
            Toggle("Verbose logging", isOn: $model.verboseLogging)
            Text("Verbose logs go to /tmp/tandemclip.err.log.")
                .font(.caption).foregroundColor(.secondary)
        }
    }

    private var identityTab: some View {
        Form {
            TextField("Display name", text: $model.deviceDisplayName, prompt: Text(Host.current().localizedName ?? "Mac"))
            Divider()
            HStack {
                TextField("Pairing code", text: $model.pairingCode)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit { model.applyPairingCode() }
                Button("Apply") { model.applyPairingCode() }
                    .disabled(model.pairingCode.trimmingCharacters(in: .whitespaces).isEmpty
                              || model.pairingCode == model.activeCode)
                Button("Regenerate") { model.regeneratePairingCode() }
                Button("Copy") { model.copyPairingCode() }
            }
            Text("Enter the same code on every Mac. Applying re-keys the connection immediately — peers reconnect once they share the new code (no relaunch).")
                .font(.caption).foregroundColor(.secondary)
        }
    }

    private var securityTab: some View {
        Form {
            Toggle("Only sync with trusted devices", isOn: $model.allowlistEnabled)
            if model.allowlistEnabled {
                if peers.isEmpty {
                    Text("No devices seen yet.").font(.caption).foregroundColor(.secondary)
                } else {
                    ForEach(peers, id: \.id) { peer in
                        Toggle(peer.clip.name + (peer.clip.online ? " ●" : ""), isOn: Binding(
                            get: { model.config.trustedDevices[peer.id] != nil },
                            set: { model.config.setTrusted(peer.id, name: peer.clip.name, trusted: $0) }
                        ))
                    }
                }
            }
            Divider()
            Toggle("Sync only on selected Wi-Fi networks", isOn: $model.networkAllowlistEnabled)
            if model.networkAllowlistEnabled {
                ForEach(model.allowedSSIDs, id: \.self) { ssid in Text(ssid) }
                Button("Add current network") { model.addCurrentSSID() }
                Text("Reading the Wi-Fi name needs Location permission; without it, this can't enforce and sync stays on.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .onAppear { peers = model.engine.sortedPeers() }
    }
}

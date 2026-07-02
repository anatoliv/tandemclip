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
    @Published var syncFiles: Bool { didSet { config.syncFiles = syncFiles } }

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

    init(config: Config, engine: SyncEngine) {
        self.config = config
        self.engine = engine
        mode = config.mode
        previewLevel = config.previewLevel
        role = config.role
        maxMB = Double(config.maxClipBytes) / 1_000_000
        syncRichText = config.syncRichText
        syncImages = config.syncImages
        syncFiles = config.syncFiles
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
    func removeSSID(_ ssid: String) {
        allowedSSIDs.removeAll { $0 == ssid }
    }

    var pairingCodeDirty: Bool {
        let c = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
        return !c.isEmpty && c != activeCode
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
            generalTab.tabItem { Label("General", systemImage: "gearshape") }
            syncTab.tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
            contentTab.tabItem { Label("Content", systemImage: "doc.on.clipboard") }
            securityTab.tabItem { Label("Security", systemImage: "lock.shield") }
        }
        .frame(width: 500, height: 460)
    }

    // MARK: General — startup, this Mac, diagnostics

    private var generalTab: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at login", isOn: $model.launchAtLogin)
                Toggle("Start paused", isOn: $model.startPaused)
            }
            Section {
                TextField("Display name", text: $model.deviceDisplayName,
                          prompt: Text(Host.current().localizedName ?? "Mac"))
            } header: {
                Text("This Mac")
            } footer: {
                Text("The name other Macs see for this computer.")
            }
            Section {
                Toggle("Verbose logging", isOn: $model.verboseLogging)
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Detailed logs are written to /tmp/tandemclip.err.log.")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Sync — behavior + limits

    private var syncTab: some View {
        Form {
            Section("Behavior") {
                Picker("Mode", selection: $model.mode) {
                    Text("Mirror — auto-sync").tag(SyncMode.mirror)
                    Text("Manual — pull on demand").tag(SyncMode.manual)
                }
                Picker("This Mac's role", selection: $model.role) {
                    Text("Send & receive").tag(Role.sendReceive)
                    Text("Receive only").tag(Role.receiveOnly)
                    Text("Send only").tag(Role.sendOnly)
                }
                Picker("Peer preview", selection: $model.previewLevel) {
                    Text("Metadata — age + size").tag(PreviewLevel.metadata)
                    Text("Live text preview").tag(PreviewLevel.preview)
                    Text("Names only").tag(PreviewLevel.names)
                }
            }
            Section {
                Picker("Max clipboard size", selection: $model.maxMB) {
                    Text("1 MB").tag(1.0)
                    Text("2 MB").tag(2.0)
                    Text("5 MB").tag(5.0)
                    Text("10 MB").tag(10.0)
                    Text("25 MB").tag(25.0)
                }
            } header: {
                Text("Limits")
            } footer: {
                Text("Content larger than this falls back to plain text, or is skipped if there's no text.")
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
                Text("Plain text always syncs. Each copy carries every enabled representation so paste keeps full fidelity.")
            }
            Section {
                Toggle("Keep clipboard history", isOn: $model.historyEnabled)
                if model.historyEnabled {
                    Stepper("Keep \(model.historyKeep) clips", value: $model.historyKeep, in: 10...200, step: 10)
                    Stepper("Show \(model.pickerShow) in picker", value: $model.pickerShow, in: 5...50, step: 1)
                }
            } header: {
                Text("History")
            } footer: {
                Text("History is in-memory for this session only. Open the picker with ⇧⌘V.")
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
                Text("Enter the same code on every Mac. Applying re-keys the connection immediately — peers reconnect once they share the new code (no relaunch).")
            }

            Section {
                Toggle("Only sync with trusted devices", isOn: $model.allowlistEnabled)
                if model.allowlistEnabled {
                    if peers.isEmpty {
                        Text("No devices seen yet.").foregroundColor(.secondary)
                    } else {
                        ForEach(peers, id: \.id) { peer in
                            Toggle(isOn: Binding(
                                get: { model.config.trustedDevices[peer.id] != nil },
                                set: { model.config.setTrusted(peer.id, name: peer.clip.name, trusted: $0) }
                            )) {
                                HStack(spacing: 7) {
                                    Circle().fill(peer.clip.online ? Color.green : Color.secondary.opacity(0.4))
                                        .frame(width: 7, height: 7)
                                    Text(peer.clip.name)
                                }
                            }
                        }
                    }
                }
            } header: {
                Text("Trusted devices")
            }

            Section {
                Toggle("Sync only on selected Wi-Fi networks", isOn: $model.networkAllowlistEnabled)
                if model.networkAllowlistEnabled {
                    ForEach(model.allowedSSIDs, id: \.self) { ssid in
                        HStack {
                            Image(systemName: "wifi").foregroundColor(.secondary)
                            Text(ssid)
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
                }
            } header: {
                Text("Wi-Fi networks")
            } footer: {
                Text("Reading the Wi-Fi name needs Location permission; without it this can't enforce, and sync stays on.")
            }
        }
        .formStyle(.grouped)
        .onAppear { peers = model.engine.sortedPeers() }
    }
}

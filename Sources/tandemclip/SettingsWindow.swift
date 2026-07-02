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
    @Published var wifiFailOpen: Bool { didSet { config.wifiFailOpen = wifiFailOpen } }

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
    @State private var currentSSID: String = ""
    @State private var tab: Tab = .general

    enum Tab: String, CaseIterable, Identifiable {
        case general = "General", sync = "Sync", content = "Content", security = "Security"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            Group {
                switch tab {
                case .general:  generalTab
                case .sync:     syncTab
                case .content:  contentTab
                case .security: securityTab
                }
            }
        }
        .frame(width: 520, height: 500)
    }

    /// Custom segmented tab bar — avoids the full-width grey strip SwiftUI's
    /// TabView draws behind its tabs.
    private var tabBar: some View {
        HStack(spacing: 3) {
            ForEach(Tab.allCases) { t in
                Button { tab = t } label: {
                    Text(t.rawValue)
                        .font(.system(size: 12.5, weight: tab == t ? .semibold : .regular))
                        .foregroundColor(tab == t ? .white : .primary)
                        .padding(.horizontal, 13).padding(.vertical, 5)
                        .background(tab == t ? Color.accentColor : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
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
                Text("Plain text always syncs. Each copy carries every enabled representation so paste keeps full fidelity. Copied files always appear in your history and can be pulled or drop-shared either way — the Files toggle only controls whether their content is sent to your Macs automatically.")
            }
            Section {
                Toggle("Keep clipboard history", isOn: $model.historyEnabled)
                if model.historyEnabled {
                    Picker("Keep in history", selection: $model.historyKeep) {
                        ForEach([10, 20, 50, 100, 150, 200], id: \.self) { Text("\($0) clips").tag($0) }
                    }
                    Picker("Show in picker", selection: $model.pickerShow) {
                        ForEach([5, 8, 10, 12, 15, 20, 30, 50], id: \.self) { Text("\($0) clips").tag($0) }
                    }
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
                Text(model.allowlistEnabled
                     ? "Only the devices you check can sync. Unchecking a device revokes it immediately, even if it still knows the pairing code — the safe way to cut off a Mac you've stopped using."
                     : "Off: any Mac with the pairing code can sync. Turn this on to pin specific devices and to be able to revoke one without changing the code everywhere.")
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
                Text("Sync runs only on the Wi-Fi networks listed above. On Ethernet/VPN (no Wi-Fi to match), sync pauses by default — turn on the option above to allow it instead.")
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

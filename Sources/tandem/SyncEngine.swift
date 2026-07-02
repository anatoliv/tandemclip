import Foundation
import AppKit

/// What we know about another Mac's clipboard.
struct PeerClip {
    var name: String
    var online: Bool = false
    var timestamp: Double = 0
    var size: Int?
    var hash: String?
    var preview: String?
}

/// Glue between the local clipboard and the network. Honors the current mode
/// (Mirror = auto-sync, Manual = pull-on-demand), the send/receive role, the
/// preview level, the trusted-device allowlist, and the network guard.
///
/// All state here is touched on the main thread: the watcher polls on the main
/// run loop and Transport delivers callbacks via `DispatchQueue.main`.
final class SyncEngine {
    let config: Config
    let watcher = ClipboardWatcher()
    let transport: Transport

    private var lastHash: String?          // dedup / echo-loop key
    private var pendingPull: Set<String> = []  // deviceIDs we've asked to fetch from

    // Our current shareable clipboard (last non-secret local copy).
    private var localText: String?
    private var localHash: String?
    private var localSize: Int = 0
    private var localTimestamp: Double = 0

    private(set) var peers: [String: PeerClip] = [:]   // by deviceID
    private(set) var lastSyncSource: String?

    /// Returns whether sync is currently allowed on this network (SSID guard).
    var networkAllowed: () -> Bool = { true }

    var onStatusChange: (() -> Void)?

    var peerCount: Int { peers.values.filter { $0.online }.count }

    init(config: Config) {
        self.config = config
        transport = Transport(config: config)

        watcher.maxBytes = config.maxClipBytes
        watcher.isPaused = { false }   // we gate in handleLocal; still want to observe copies to serve requests
        watcher.onLocalCopy = { [weak self] text, hash in self?.handleLocal(text, hash) }

        transport.onMessage = { [weak self] msg in self?.handleRemote(msg) }
        transport.helloProvider = { [weak self] in self?.makeAnnounce() }
        transport.onConnectedPeersChanged = { [weak self] dict in self?.updateConnected(dict) }
    }

    func start() {
        watcher.start()
        transport.start()
    }

    /// Re-read settings that affect the watcher (called on config change).
    func applyConfig() {
        watcher.maxBytes = config.maxClipBytes
    }

    // MARK: - Peer list (for the menu)

    /// Peers sorted by name, for display.
    func sortedPeers() -> [(id: String, clip: PeerClip)] {
        peers.map { ($0.key, $0.value) }.sorted { $0.clip.name.localizedCaseInsensitiveCompare($1.clip.name) == .orderedAscending }
    }

    /// Manually pull a specific peer's clipboard into ours (Manual mode).
    func pull(from deviceID: String) {
        guard config.role.canReceive else { return }
        Log.trace("sync", "pull request -> \(peers[deviceID]?.name ?? deviceID)")
        pendingPull.insert(deviceID)
        var req = Message(type: .request, deviceID: config.deviceID, deviceName: config.deviceName)
        req.timestamp = now()
        transport.send(req, to: deviceID)
    }

    // MARK: - Local clipboard changed

    private func handleLocal(_ text: String, _ hash: String) {
        localText = text
        localHash = hash
        localSize = text.utf8.count
        localTimestamp = now()

        guard config.role.canSend, !config.paused, networkAllowed() else {
            onStatusChange?()
            return
        }

        if config.mode == .mirror {
            guard hash != lastHash else { return }
            lastHash = hash
            var msg = Message(type: .clip, deviceID: config.deviceID, deviceName: config.deviceName)
            msg.timestamp = localTimestamp; msg.hash = hash; msg.size = localSize; msg.text = text
            Log.trace("sync", "mirror: broadcast clip \(text.count) chars")
            transport.broadcast(msg)
            lastSyncSource = "\(config.deviceName) (local)"
        } else {
            // Manual: only advertise metadata; content stays until pulled.
            Log.trace("sync", "manual: announce metadata")
            transport.broadcast(makeAnnounce())
        }
        onStatusChange?()
    }

    // MARK: - Remote message

    private func handleRemote(_ msg: Message) {
        guard config.isTrusted(msg.deviceID) else {
            Log.trace("sync", "dropped \(msg.type.rawValue) from untrusted \(msg.deviceName)")
            return
        }

        switch msg.type {
        case .announce:
            updatePeer(from: msg)

        case .clip:
            updatePeer(from: msg)
            applyIncomingClip(msg)

        case .request:
            guard config.role.canSend, !config.paused, networkAllowed() else { return }
            guard let text = localText, let h = localHash else { return }
            var reply = Message(type: .clip, deviceID: config.deviceID, deviceName: config.deviceName)
            reply.timestamp = localTimestamp; reply.hash = h; reply.size = localSize; reply.text = text
            Log.trace("sync", "serving pull -> \(msg.deviceName)")
            transport.send(reply, to: msg.deviceID)
        }
    }

    private func applyIncomingClip(_ msg: Message) {
        guard let text = msg.text else { return }
        let hash = msg.hash ?? ClipboardWatcher.hash(Data(text.utf8))

        if config.mode == .mirror {
            guard config.role.canReceive, !config.paused, networkAllowed() else { return }
            guard hash != lastHash else {
                Log.trace("sync", "mirror: dropped clip (already seen/echo)")
                return
            }
            apply(text, hash: hash, from: msg.deviceName)
        } else {
            // Manual: apply only the clip we explicitly requested.
            guard config.role.canReceive, pendingPull.remove(msg.deviceID) != nil else { return }
            apply(text, hash: hash, from: msg.deviceName)
        }
    }

    private func apply(_ text: String, hash: String, from name: String) {
        Log.trace("sync", "apply clip from \(name)")
        lastHash = hash
        localHash = hash            // our clipboard now equals this; don't re-announce it
        localText = text
        localSize = text.utf8.count
        watcher.write(text)         // echo-suppressed inside write()
        lastSyncSource = name
        onStatusChange?()
    }

    // MARK: - Peer table

    private func updatePeer(from msg: Message) {
        var p = peers[msg.deviceID] ?? PeerClip(name: msg.deviceName)
        p.name = msg.deviceName
        if msg.timestamp > 0 { p.timestamp = msg.timestamp }
        if let s = msg.size { p.size = s }
        if let h = msg.hash { p.hash = h }
        p.preview = msg.preview     // may be nil depending on peer's preview level
        peers[msg.deviceID] = p
        onStatusChange?()
    }

    private func updateConnected(_ dict: [String: String]) {
        let online = Set(dict.keys)
        for (id, name) in dict {
            var p = peers[id] ?? PeerClip(name: name)
            p.name = name
            p.online = true
            peers[id] = p
        }
        for id in peers.keys where !online.contains(id) {
            peers[id]?.online = false
        }
        onStatusChange?()
    }

    // MARK: - Helpers

    /// Identity + (if we're allowed to send) our clipboard metadata, shaped by
    /// the preview level. Sent on connect and on local change in Manual mode.
    private func makeAnnounce() -> Message {
        var m = Message(type: .announce, deviceID: config.deviceID, deviceName: config.deviceName)
        guard config.role.canSend, config.previewLevel != .names, let h = localHash else { return m }
        m.timestamp = localTimestamp
        m.hash = h
        m.size = localSize
        if config.previewLevel == .preview, let t = localText {
            m.preview = String(t.prefix(80)).replacingOccurrences(of: "\n", with: " ")
        }
        return m
    }

    private func now() -> Double { Date().timeIntervalSince1970 }
}

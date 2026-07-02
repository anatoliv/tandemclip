import Foundation
import AppKit

/// A recent clipboard entry (in-memory history).
struct HistoryItem: Identifiable {
    let snapshot: ClipSnapshot
    let hash: String
    let timestamp: Double
    let label: String     // preview text or content kind
    let source: String    // which Mac it came from
    var id: String { hash }
    var kindLabel: String { snapshot.contentLabel }
    /// Thumbnail bytes for image clips (for the picker preview).
    var imageData: Data? { snapshot.parts[.png] ?? snapshot.parts[.tiff] }
}

/// What we know about another Mac's clipboard.
struct PeerClip {
    var name: String
    var online: Bool = false
    var timestamp: Double = 0
    var size: Int?
    var hash: String?
    var preview: String?
    var kindLabel: String?   // "text" / "rich text" / "image"
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
    private var pendingPull: [String: Double] = [:]  // deviceID -> time we requested from it
    private let pullTimeout: Double = 20             // a pull reply is only honored this long
    private var pullOpen: Set<String> = []           // deviceIDs whose pulled file(s) to open

    // Our current shareable clipboard (last non-secret local copy).
    private var localSnapshot: ClipSnapshot?
    private var localHash: String?
    private var localTimestamp: Double = 0

    private(set) var peers: [String: PeerClip] = [:]   // by deviceID
    private(set) var lastSyncSource: String?
    private(set) var history: [HistoryItem] = []       // recent clipboard, newest first (in-memory)

    /// Returns whether sync is currently allowed on this network (SSID guard).
    var networkAllowed: () -> Bool = { true }

    var onStatusChange: (() -> Void)?

    /// A peer counts as "connected" only if it's both linked AND allowed to sync
    /// (trusted when the allowlist is on). Untrusting a device makes it read as
    /// not-synced immediately, even though the TLS link may still be up.
    func isSynced(_ id: String) -> Bool {
        (peers[id]?.online ?? false) && config.isTrusted(id)
    }
    var peerCount: Int { peers.keys.filter { isSynced($0) }.count }

    /// Peers we can actually pull from right now (online + trusted). Empty when
    /// receiving isn't allowed (paused / disallowed network / send-only role),
    /// so the picker shows nothing to grab.
    func syncablePeers() -> [(id: String, clip: PeerClip)] {
        guard receiveAllowed else { return [] }
        return sortedPeers().filter { isSynced($0.id) }
    }

    /// Current local clipboard (kind label + total bytes), for menu-bar
    /// visibility. Nil until something syncable has been copied this session.
    var currentClipInfo: (kind: String, bytes: Int)? {
        guard let s = localSnapshot else { return nil }
        return (s.contentLabel, s.totalBytes)
    }

    init(config: Config) {
        self.config = config
        transport = Transport(config: config)

        watcher.maxBytes = config.maxClipBytes
        watcher.isPaused = { false }   // we gate in handleLocal; still want to observe copies to serve requests
        watcher.enabledKinds = { [weak self] in self?.config.enabledKinds ?? [.text] }
        watcher.syncFiles = { [weak self] in self?.config.syncFiles ?? false }
        watcher.onLocalCopy = { [weak self] snap, hash in self?.handleLocal(snap, hash) }

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

    /// The pairing code changed — re-key the transport so peers reconnect with
    /// the new PSK immediately. Peers drop until they also have the new code.
    func reloadPairing() {
        peers.removeAll()
        transport.restart()
        onStatusChange?()
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
        pendingPull[deviceID] = now()
        pullOpen.insert(deviceID)   // grabbing a Mac's clip is user-initiated → open any files
        var req = Message(type: .request, deviceID: config.deviceID, deviceName: config.deviceName)
        req.timestamp = now()
        transport.send(req, to: deviceID)
    }

    // MARK: - Local clipboard changed

    private func handleLocal(_ snap: ClipSnapshot, _ hash: String) {
        localSnapshot = snap
        localHash = hash
        localTimestamp = now()
        recordHistory(snap, hash, source: config.deviceName)

        guard config.role.canSend, !config.paused, networkAllowed() else {
            onStatusChange?()
            return
        }

        if config.mode == .mirror {
            guard hash != lastHash, let msg = clipMessage(type: .clip) else { return }
            lastHash = hash
            Log.trace("sync", "mirror: broadcast \(snap.contentLabel) \(snap.totalBytes)B")
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

    /// Whether we may currently take in another Mac's clipboard: receiving role,
    /// not paused, and on an allowed network. When false we neither SEE (peer
    /// metadata) nor RECEIVE (clips) — an unallowed state reveals nothing.
    private var receiveAllowed: Bool {
        config.role.canReceive && !config.paused && networkAllowed()
    }

    private func handleRemote(_ msg: Message) {
        guard config.isTrusted(msg.deviceID) else {
            Log.trace("sync", "dropped \(msg.type.rawValue) from untrusted \(msg.deviceName)")
            return
        }

        switch msg.type {
        case .announce:
            guard receiveAllowed else { return }   // don't learn a peer's clipboard when we can't receive
            updatePeer(from: msg)

        case .clip:
            guard receiveAllowed else { return }
            updatePeer(from: msg)
            applyIncomingClip(msg)

        case .request:
            guard config.role.canSend, !config.paused, networkAllowed() else { return }
            guard let reply = clipMessage(type: .clip) else { return }
            Log.trace("sync", "serving pull -> \(msg.deviceName)")
            transport.send(reply, to: msg.deviceID)
        }
    }

    private func applyIncomingClip(_ msg: Message) {
        guard let snap = snapshot(from: msg) else { return }
        let hash = msg.hash ?? snap.hash

        if config.mode == .mirror {
            guard config.role.canReceive, !config.paused, networkAllowed() else { return }
            guard hash != lastHash else {
                Log.trace("sync", "mirror: dropped clip (already seen/echo)")
                return
            }
            let urls = apply(snap, hash: hash, from: msg.deviceName)
            if pullOpen.remove(msg.deviceID) != nil { openFiles(urls) }
            // Relay (gossip) to the rest of the mesh so machines that aren't
            // directly connected to the source still receive it. Hash dedup on
            // every node stops loops; a clip circulates at most once.
            if config.role.canSend {
                Log.trace("sync", "relay clip from \(msg.deviceName)")
                transport.broadcast(msg)
            }
        } else {
            // Manual: apply only a clip we explicitly requested, and only if the
            // reply is recent. A pull whose reply was lost must NOT leave a latent
            // permission that silently swallows the peer's next (e.g. Mirror-mode)
            // broadcast as if it were the requested clip.
            guard config.role.canReceive,
                  let requestedAt = pendingPull[msg.deviceID],
                  now() - requestedAt <= pullTimeout else { return }
            pendingPull[msg.deviceID] = nil
            let urls = apply(snap, hash: hash, from: msg.deviceName)
            if pullOpen.remove(msg.deviceID) != nil { openFiles(urls) }
        }
    }

    @discardableResult
    private func apply(_ snap: ClipSnapshot, hash: String, from name: String) -> [URL] {
        Log.trace("sync", "apply \(snap.contentLabel) from \(name)")
        lastHash = hash
        localHash = hash            // our clipboard now equals this; don't re-announce it
        localSnapshot = snap
        localTimestamp = now()
        recordHistory(snap, hash, source: name)
        let urls = watcher.write(snap)   // echo-suppressed inside write()
        lastSyncSource = name
        onStatusChange?()
        return urls
    }

    /// Open materialized file clips in their default app (user-initiated only).
    private func openFiles(_ urls: [URL]) {
        for url in urls {
            Log.trace("sync", "open \(url.lastPathComponent)")
            if !NSWorkspace.shared.open(url) {
                // No default app / unknown type — at least reveal it in Finder
                // so the pick isn't a silent no-op.
                Log.error("open failed for \(url.lastPathComponent) — revealing in Finder")
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }

    // MARK: - History (in-memory, opt-in)

    private func recordHistory(_ snap: ClipSnapshot, _ hash: String, source: String) {
        guard config.historyEnabled else { return }
        history.removeAll { $0.hash == hash }
        let label: String
        if let t = snap.plainText {
            label = String(t.prefix(64)).replacingOccurrences(of: "\n", with: " ")
        } else if let first = snap.files.first {
            label = snap.files.count == 1 ? first.name : "\(first.name) +\(snap.files.count - 1)"
        } else {
            label = snap.contentLabel
        }
        history.insert(HistoryItem(snapshot: snap, hash: hash, timestamp: now(), label: label, source: source), at: 0)
        if history.count > config.historyLimit { history.removeLast(history.count - config.historyLimit) }
    }

    /// Re-copy a history entry (re-syncs it in Mirror mode). File clips are also
    /// opened in their default app — the clipboard still holds the file URLs, so
    /// they can be pasted elsewhere too.
    func applyHistory(hash: String) {
        guard let item = history.first(where: { $0.hash == hash }) else { return }
        Log.trace("sync", "history re-apply \(item.label)")
        let urls = watcher.repost(item.snapshot)   // not echo-suppressed → watcher re-detects & re-syncs
        openFiles(urls)
    }

    func clearHistory() {
        history.removeAll()
        purgeReceivedFiles()   // don't leave synced files sitting in the clear on disk
        onStatusChange?()
    }

    /// Delete the on-disk cache of received files (materialized under
    /// Application Support). Called on Clear history.
    private func purgeReceivedFiles() {
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let dir = support.appendingPathComponent("TandemClip/Received", isDirectory: true)
        if (try? fm.removeItem(at: dir)) != nil { Log.trace("sync", "purged received files") }
    }

    // MARK: - Peer table

    private func updatePeer(from msg: Message) {
        var p = peers[msg.deviceID] ?? PeerClip(name: msg.deviceName)
        p.name = msg.deviceName
        if msg.timestamp > 0 { p.timestamp = msg.timestamp }
        if let s = msg.size { p.size = s }
        if let h = msg.hash { p.hash = h }
        p.preview = msg.preview     // may be nil depending on peer's preview level
        if msg.type != .announce || msg.size != nil { p.kindLabel = msg.contentType }
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
            pendingPull[id] = nil   // an offline peer won't answer a pending pull
            pullOpen.remove(id)
        }
        onStatusChange?()
    }

    // MARK: - Helpers

    /// Identity + (if we're allowed to send) our clipboard metadata, shaped by
    /// the preview level. Sent on connect and on local change in Manual mode.
    private func makeAnnounce() -> Message {
        var m = Message(type: .announce, deviceID: config.deviceID, deviceName: config.deviceName)
        guard config.role.canSend, config.previewLevel != .names,
              let h = localHash, let snap = localSnapshot else { return m }
        m.timestamp = localTimestamp
        m.hash = h
        m.size = snap.totalBytes
        m.contentType = snap.contentLabel
        if config.previewLevel == .preview, let t = snap.plainText {
            m.preview = String(t.prefix(80)).replacingOccurrences(of: "\n", with: " ")
        }
        return m
    }

    /// Build a full `clip` message from our current snapshot.
    private func clipMessage(type: MessageType) -> Message? {
        guard let snap = localSnapshot, let h = localHash else { return nil }
        var m = Message(type: type, deviceID: config.deviceID, deviceName: config.deviceName)
        m.timestamp = localTimestamp
        m.hash = h
        m.size = snap.totalBytes
        m.contentType = snap.contentLabel
        m.text = snap.plainText
        m.parts = snap.wireParts
        m.files = snap.wireFiles.isEmpty ? nil : snap.wireFiles
        return m
    }

    /// Reconstruct a snapshot from a clip message (falls back to legacy text).
    /// The sender's original filenames are preserved verbatim.
    private func snapshot(from msg: Message) -> ClipSnapshot? {
        if let snap = ClipSnapshot(wire: msg.parts, wireFiles: msg.files) { return snap }
        if let t = msg.text { return ClipSnapshot(parts: [.text: Data(t.utf8)]) }
        return nil
    }

    private func now() -> Double { Date().timeIntervalSince1970 }
}

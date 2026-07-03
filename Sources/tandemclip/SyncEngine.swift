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
    var category: ClipCategory { snapshot.category }
    /// Thumbnail bytes for image clips (picker preview). Image *files* preview
    /// their first file's content — NSImage decodes the common formats.
    var imageData: Data? {
        snapshot.parts[.png] ?? snapshot.parts[.tiff]
            ?? (snapshot.filesAreAllImages ? snapshot.files.first?.data : nil)
    }
}

/// What we know about another Mac's clipboard.
struct PeerClip {
    var name: String
    var online: Bool = false
    var publicKey: String?
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
    private var lastRequestServed: [String: Double] = [:]

    // Replay guard (touched on the main thread). The inbound flood bound is NOT
    // here: it lives in Transport, keyed on the connection (un-spoofable) rather
    // than on a self-asserted, forgeable deviceID. See Transport.allowInboundFrame.
    private var seenSignatures: [String: Double] = [:]  // identitySignature -> first seen (replay guard)
    private let replayWindow: Double = 600              // how long a signature is remembered

    // Our current shareable clipboard (last non-secret local copy).
    private var localSnapshot: ClipSnapshot?
    private var localHash: String?
    private(set) var localTimestamp: Double = 0
    /// Which peer the current clipboard came from — nil when it was copied on
    /// this Mac. Set alongside localSnapshot so it can't go stale.
    private(set) var clipOrigin: String?

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
        guard let peer = peers[id] else { return false }
        return peer.online && config.isTrusted(id, publicKey: peer.publicKey)
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
        watcher.cacheCap = { [weak self] in self?.config.receivedCacheCap ?? 200_000_000 }
        watcher.onLocalCopy = { [weak self] snap, hash in self?.handleLocal(snap, hash) }

        transport.onMessage = { [weak self] msg, verifiedKey in self?.handleRemote(msg, verifiedKey: verifiedKey) }
        transport.helloProvider = { [weak self] in self?.makeAnnounce() }
        transport.onConnectedPeersChanged = { [weak self] dict in self?.updateConnected(dict) }
    }

    func start() {
        watcher.start()
        guard config.hasPairingSecret else {
            // No readable pairing secret → derivePSK would fall back to a fixed,
            // publicly-known key. Do not advertise or accept connections; wait for
            // the user to set a code (setPairingCode → reloadPairing brings it up).
            Log.error("no usable pairing code — not starting networking (would key TLS with a known PSK)")
            return
        }
        transport.start()
    }

    /// Re-read settings that affect the watcher (called on config change).
    /// Also re-applies the storage cap so lowering it evicts immediately
    /// rather than on the next received clip.
    func applyConfig() {
        watcher.maxBytes = config.maxClipBytes
        watcher.enforceCacheCap()
    }

    /// The pairing code changed — re-key the transport so peers reconnect with
    /// the new PSK immediately. Peers drop until they also have the new code.
    func reloadPairing() {
        peers.removeAll()
        if config.hasPairingSecret { transport.restart() }
        onStatusChange?()
    }

    // MARK: - Peer list (for the menu)

    /// Peers sorted by name, for display.
    func sortedPeers() -> [(id: String, clip: PeerClip)] {
        peers.map { ($0.key, $0.value) }.sorted { $0.clip.name.localizedCaseInsensitiveCompare($1.clip.name) == .orderedAscending }
    }

    /// Manually pull a specific peer's clipboard into ours (Manual mode).
    func pull(from deviceID: String) {
        guard receiveAllowed else { return }   // no pulling when paused / disallowed network / send-only
        Log.trace("sync", "pull request -> \(peers[deviceID]?.name ?? deviceID)")
        pendingPull[deviceID] = now()
        pullOpen.insert(deviceID)   // grabbing a Mac's clip is user-initiated → open any files
        var req = Message(type: .request, deviceID: config.deviceID, deviceName: config.deviceName)
        req.timestamp = now()
        config.identity.sign(&req)
        transport.send(req, to: deviceID)
    }

    /// Share dropped files to the mesh right now. This is an explicit user action
    /// (drag-onto-picker), so it sends in both Mirror and Manual mode and
    /// regardless of the file auto-sync toggle — but it still honors
    /// the send role, pause, the network guard, and the size cap, and never sends
    /// folders. It does NOT touch the local clipboard (you dropped these to share,
    /// not to copy). Records a history entry so the share is visible/re-usable.
    /// Returns how many synced Macs it was broadcast to (0 = nothing sent).
    ///
    /// Note: like any Mirror broadcast, only peers in Mirror mode auto-apply it;
    /// a Manual-mode peer would still pull it on demand.
    struct ShareOutcome {
        var sent = 0      // files actually broadcast
        var skipped = 0   // dropped items that couldn't travel (over cap, unreadable)
        var peers = 0     // synced Macs it went to
    }

    @discardableResult
    func shareFiles(_ urls: [URL]) -> ShareOutcome {
        guard config.role.canSend, !config.paused, !config.privacyHold, networkAllowed() else {
            return ShareOutcome(sent: 0, skipped: urls.count, peers: peerCount)
        }
        let (files, skipped) = ClipboardWatcher.collectFiles(urls, maxBytes: config.maxClipBytes)
        guard !files.isEmpty else { return ShareOutcome(sent: 0, skipped: skipped, peers: peerCount) }
        let snap = ClipSnapshot(parts: [:], files: files)
        var m = Message(type: .clip, deviceID: config.deviceID, deviceName: config.deviceName)
        m.timestamp = now()
        m.hash = snap.hash
        m.size = snap.totalBytes
        m.contentType = snap.contentLabel
        m.files = snap.wireFiles
        config.identity.sign(&m)
        recordHistory(snap, snap.hash, source: "\(config.deviceName) (shared)")
        Log.trace("sync", "share \(files.count) file(s) \(snap.totalBytes)B")
        transport.broadcast(m)
        lastSyncSource = "\(config.deviceName) (shared)"
        onStatusChange?()
        return ShareOutcome(sent: files.count, skipped: skipped, peers: peerCount)
    }

    /// Delete a history item on every Mac. Removes it locally right away, then
    /// broadcasts a signed `delete` keyed by content hash so peers (and, via
    /// relay, Macs not directly connected to us) drop it too. Sending honors the
    /// role/pause/network gates like any outbound traffic; the local removal
    /// happens regardless.
    func deleteHistory(hash: String) {
        Log.trace("sync", "delete \(hash.prefix(12)) (local user action)")
        removeClip(hash: hash)
        // Deliberately NOT gated on privacyHold: a delete reveals nothing new
        // (peers already hold the content) and privacy is exactly when you
        // want removals to propagate.
        guard config.role.canSend, !config.paused, networkAllowed() else { return }
        var m = Message(type: .delete, deviceID: config.deviceID, deviceName: config.deviceName)
        m.timestamp = now()
        m.hash = hash
        config.identity.sign(&m)
        transport.broadcast(m)
    }

    /// Local effects of a deletion (user- or peer-initiated): drop the history
    /// entry, remove any files materialized for it, and if it's what our
    /// clipboard currently holds, clear that too — deleting a clip means it
    /// should no longer be pasteable anywhere.
    private func removeClip(hash: String) {
        history.removeAll { $0.hash == hash }
        purgeReceivedFiles(hash: hash)
        if localHash == hash {
            localSnapshot = nil
            localHash = nil
            watcher.write(ClipSnapshot(parts: [:]))   // clears the pasteboard, echo-suppressed
        }
        if lastHash == hash { lastHash = nil }   // re-copying the content later must re-sync
        onStatusChange?()
    }

    // MARK: - Local clipboard changed

    /// A local copy the secret guard held back from syncing (cleared by the
    /// next copy or by releaseHeldSecret). Pull serving skips it too.
    private(set) var heldSecret: (hash: String, reason: String)?

    /// "Send anyway": lift the hold and, in Mirror mode, broadcast the clip
    /// that was held (Manual peers can now pull it).
    func releaseHeldSecret() {
        guard let held = heldSecret, held.hash == localHash else { heldSecret = nil; return }
        heldSecret = nil
        guard config.role.canSend, !config.paused, !config.privacyHold, networkAllowed() else {
            onStatusChange?(); return
        }
        if config.mode == .mirror, let msg = clipMessage(type: .clip) {
            lastHash = held.hash
            Log.trace("sync", "secret hold released — broadcasting")
            transport.broadcast(msg)
            lastSyncSource = "\(config.deviceName) (local)"
        } else {
            transport.broadcast(makeAnnounce())
        }
        onStatusChange?()
    }

    private func handleLocal(_ snap: ClipSnapshot, _ hash: String) {
        localSnapshot = snap
        localHash = hash
        localTimestamp = now()
        clipOrigin = nil   // copied here
        heldSecret = nil   // every new copy is re-assessed
        recordHistory(snap, hash, source: config.deviceName)

        // Secret guard: a text clip that looks like a credential is captured
        // (history, snapshot) but held from ALL sending until released — the
        // backstop for apps that don't set the concealed-type marker.
        if config.secretGuardEnabled, snap.files.isEmpty,
           let text = snap.plainText, let finding = SecretGuard.assess(text) {
            heldSecret = (hash, finding.reason)
            Log.trace("sync", "secret guard held clip (\(finding.reason))")
            onStatusChange?()
            return
        }

        guard config.role.canSend, !config.paused, !config.privacyHold, networkAllowed() else {
            onStatusChange?()
            return
        }

        if config.mode == .mirror {
            guard hash != lastHash else { return }
            // File content auto-broadcasts only when opted in (Settings → Files).
            // The copy is still captured above (history + shareable snapshot), so
            // peers see its metadata and can pull it on demand — the toggle gates
            // pushing bytes unasked, not having them.
            guard snap.files.isEmpty || config.syncFiles else {
                Log.trace("sync", "mirror: file copy captured; auto-sync off — announce only")
                transport.broadcast(makeAnnounce())
                onStatusChange?()
                return
            }
            guard let msg = clipMessage(type: .clip) else { return }
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

    private func handleRemote(_ msg: Message, verifiedKey: String?) {
        // `verifiedKey` was already signature-checked on the transport queue
        // (Transport.receiveBody); don't re-run the EdDSA verify here.
        let hasSignedIdentity = msg.identityPublicKey != nil || msg.identitySignature != nil
        guard !hasSignedIdentity || verifiedKey != nil else {
            Log.trace("sync", "dropped \(msg.type.rawValue) with invalid identity signature from \(msg.deviceName)")
            return
        }
        guard config.isTrusted(msg.deviceID, publicKey: verifiedKey) else {
            Log.trace("sync", "dropped \(msg.type.rawValue) from untrusted \(msg.deviceName)")
            return
        }

        switch msg.type {
        case .announce:
            guard receiveAllowed else { return }   // don't learn a peer's clipboard when we can't receive
            updatePeer(from: msg, publicKey: verifiedKey)

        case .clip:
            guard receiveAllowed else { return }
            guard !isReplayedClip(msg) else {
                Log.trace("sync", "dropped replayed clip from \(msg.deviceName)")
                return
            }
            updatePeer(from: msg, publicKey: verifiedKey)
            applyIncomingClip(msg)

        case .delete:
            // Honored from any trusted peer even when receiving content is
            // disabled: a deletion is data-minimizing, not content delivery.
            // It must be signed and fresh — an unsigned or replayed delete could
            // otherwise silently kill a clip the user re-copied later.
            guard let hash = msg.hash, verifiedKey != nil else { return }
            guard now() - msg.timestamp <= replayWindow else {
                Log.trace("sync", "dropped stale delete (\(Int(now() - msg.timestamp))s old) from \(msg.deviceName)")
                return
            }
            guard !isReplayedClip(msg) else { return }
            Log.trace("sync", "delete \(hash.prefix(12)) from \(msg.deviceName)")
            removeClip(hash: hash)
            // Relay so Macs not directly connected to the origin delete too.
            // The seen-signature cache above stops relay loops.
            if config.role.canSend {
                transport.broadcast(msg)
            }

        case .request:
            // A pull is the peer's explicit ask for our current clipboard, so it
            // is served whatever the snapshot holds — including file content when
            // the auto-sync toggle is off (that toggle gates unasked pushes only).
            guard config.role.canSend, !config.paused, !config.privacyHold, networkAllowed() else { return }
            let t = now()
            // Drop entries older than the 1s throttle so this map can't grow
            // without bound under spoofed deviceIDs.
            lastRequestServed = lastRequestServed.filter { t - $0.value < 60 }
            guard t - (lastRequestServed[msg.deviceID] ?? 0) >= 1 else { return }
            lastRequestServed[msg.deviceID] = t
            // Never serve a clip the secret guard is holding.
            guard heldSecret?.hash != localHash else {
                Log.trace("sync", "pull refused — clip held by secret guard")
                return
            }
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
            // Freshness bound for signed clips. `seenSignatures` only remembers a
            // signature for `replayWindow`; a captured mirror broadcast replayed
            // after that would pass dedup and silently re-apply to the clipboard.
            // The timestamp is inside the signed payload, so a valid signature
            // vouches for it. Mirror broadcasts are always sent at copy time, so a
            // stale timestamp means a replay (manual pulls go through the else
            // branch and are gated by pendingPull instead).
            if msg.identitySignature != nil, now() - msg.timestamp > replayWindow {
                Log.trace("sync", "dropped stale signed clip (\(Int(now() - msg.timestamp))s old) from \(msg.deviceName)")
                return
            }
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
            // Manual: apply a clip we explicitly requested (and only if the
            // reply is recent — a pull whose reply was lost must NOT leave a
            // latent permission that silently swallows the peer's next
            // broadcast as if it were the requested clip)…
            guard config.role.canReceive else { return }
            if let requestedAt = pendingPull[msg.deviceID], now() - requestedAt <= pullTimeout {
                pendingPull[msg.deviceID] = nil
                let urls = apply(snap, hash: hash, from: msg.deviceName)
                if pullOpen.remove(msg.deviceID) != nil { openFiles(urls) }
                return
            }
            // …or, with "apply incoming automatically" on, any broadcast —
            // same freshness/dedup guards as Mirror's receive path, but no
            // relay: a Manual Mac never sends unasked.
            guard config.autoApplyIncoming else { return }
            if msg.identitySignature != nil, now() - msg.timestamp > replayWindow {
                Log.trace("sync", "dropped stale signed clip (\(Int(now() - msg.timestamp))s old) from \(msg.deviceName)")
                return
            }
            guard hash != lastHash else { return }
            apply(snap, hash: hash, from: msg.deviceName)
        }
    }

    @discardableResult
    private func apply(_ snap: ClipSnapshot, hash: String, from name: String) -> [URL] {
        Log.trace("sync", "apply \(snap.contentLabel) from \(name)")
        lastHash = hash
        localHash = hash            // our clipboard now equals this; don't re-announce it
        localSnapshot = snap
        localTimestamp = now()
        clipOrigin = name
        recordHistory(snap, hash, source: name)
        let urls = watcher.write(snap)   // echo-suppressed inside write()
        lastSyncSource = name
        onStatusChange?()
        return urls
    }

    /// Reveal materialized file clips in Finder. We never auto-open peer-supplied
    /// content: the bytes are fully attacker-controlled, so opening them in a
    /// default handler (executables, scripts, .webloc/.url handlers, documents
    /// that exploit their app) would be a remote-code-execution path. The user
    /// opens the file themselves after seeing what it is.
    private func openFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        for url in urls { Log.trace("sync", "reveal \(url.lastPathComponent)") }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    // MARK: - Replay guard

    /// True if we've already processed this exact signed message recently (an
    /// attacker or relay replaying a captured frame). Used for clips and deletes;
    /// it also stops delete-relay loops. Each genuine action carries a fresh
    /// timestamp, hence a distinct signature, so legitimate re-copies are never
    /// blocked. Unsigned clips (allowlist off) skip this check.
    private func isReplayedClip(_ msg: Message) -> Bool {
        guard let sig = msg.identitySignature else { return false }
        let t = now()
        seenSignatures = seenSignatures.filter { t - $0.value <= replayWindow }
        if seenSignatures[sig] != nil { return true }
        seenSignatures[sig] = t
        return false
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

    /// Delete just the materialized files of one clip (keyed the same way
    /// ClipboardWatcher.writeReceivedFiles names its per-clip directory).
    private func purgeReceivedFiles(hash: String) {
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let dir = support.appendingPathComponent("TandemClip/Received/\(hash.prefix(12))", isDirectory: true)
        if (try? fm.removeItem(at: dir)) != nil { Log.trace("sync", "purged received files for \(hash.prefix(12))") }
    }

    // MARK: - Peer table

    private func updatePeer(from msg: Message, publicKey: String?) {
        var p = peers[msg.deviceID] ?? PeerClip(name: msg.deviceName)
        p.name = msg.deviceName
        if let publicKey { p.publicKey = publicKey }
        if msg.timestamp > 0 { p.timestamp = msg.timestamp }
        if let s = msg.size { p.size = s }
        if let h = msg.hash { p.hash = h }
        p.preview = msg.preview     // may be nil depending on peer's preview level
        if msg.type != .announce || msg.size != nil { p.kindLabel = msg.contentType }
        peers[msg.deviceID] = p
        onStatusChange?()
    }

    private func updateConnected(_ dict: [String: PeerConnectionInfo]) {
        let online = Set(dict.keys)
        for (id, info) in dict {
            var p = peers[id] ?? PeerClip(name: info.name)
            p.name = info.name
            if let publicKey = info.publicKey { p.publicKey = publicKey }
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
        guard config.role.canSend, !config.privacyHold, config.previewLevel != .names,
              heldSecret?.hash != localHash,
              let h = localHash, let snap = localSnapshot else {
            config.identity.sign(&m)
            return m
        }
        m.timestamp = localTimestamp
        m.hash = h
        m.size = snap.totalBytes
        m.contentType = snap.contentLabel
        if config.previewLevel == .preview, let t = snap.plainText {
            m.preview = String(t.prefix(80)).replacingOccurrences(of: "\n", with: " ")
        }
        config.identity.sign(&m)
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
        config.identity.sign(&m)
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

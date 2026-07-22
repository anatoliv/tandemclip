import Foundation
import Network
import Security

struct PeerConnectionInfo {
    let id: String
    let name: String
    let publicKey: String?
}

/// LAN peer-to-peer transport: Bonjour discovery + PSK-TLS connections.
///
/// - Advertises `_tandemclip._tcp` via an NWListener and discovers peers with
///   an NWBrowser. LAN-only; no relay, no internet.
/// - Every connection is TLS with a pre-shared key derived from the pairing
///   code. A peer with the wrong code fails the handshake and never delivers a
///   message — so discovery alone grants nothing.
/// - Framing: 4-byte big-endian length prefix + JSON body.
final class Transport {
    private let config: Config
    private let queue = DispatchQueue(label: "tandemclip.transport")

    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var readyIDs: Set<ObjectIdentifier> = []         // connections past TLS handshake
    private var identity: [ObjectIdentifier: PeerConnectionInfo] = [:]  // learned from messages
    private let maxConnections = 16
    private let maxVisibleEndpoints = 32

    // Per-connection inbound frame rate limit (touched only on `queue`). Keyed on
    // the connection itself — un-spoofable, unlike a self-asserted deviceID — and
    // bounded by maxConnections, so total inbound work (TLS reads, signature
    // verifies, clipboard writes) stays capped even if a peer forges a fresh
    // deviceID per frame. This is the real DoS chokepoint; app-layer trust and
    // replay checks sit above it.
    private var inboundFrameTimes: [ObjectIdentifier: [Double]] = [:]
    private let inboundFrameWindow: Double = 10
    private let inboundFrameMax = 200   // ~20 frames/s sustained per connection

    // Reconnection state (all touched only on `queue`):
    private var visibleEndpoints: [String: NWEndpoint] = [:]  // key -> currently-advertised peer
    private var activeOutbound: Set<String> = []              // keys with a live/pending outbound dial
    private var outboundKey: [ObjectIdentifier: String] = [:] // conn -> its outbound endpoint key
    private var dialStartedAt: [ObjectIdentifier: Double] = [:] // outbound conn -> dial time
    private let dialDeadline: Double = 15                     // give up on a dial that never readies
    private var reconnectTimer: DispatchSourceTimer?

    // Self-heal state for the listener/browser (touched only on `queue`). A
    // Network.framework object that reaches `.failed` is terminal — it never
    // recovers on its own — so each is rebuilt with capped exponential backoff.
    // `epoch` is bumped by restart() so a rebuild scheduled before the restart
    // can't fire afterwards and orphan the object restart() just created.
    private var epoch = 0
    private var listenerRebuildDelay: Double = 1
    private var browserRebuildDelay: Double = 1
    private var listenerRebuildScheduled = false
    private var browserRebuildScheduled = false
    private let maxRebuildDelay: Double = 30

    // Network path watching (touched only on `queue`).
    private var pathMonitor: NWPathMonitor?
    private var lastPathKey: String?
    private var pathChangeWork: DispatchWorkItem?

    // Waking the Mac also re-associates Wi-Fi, so the wake trigger and the path
    // trigger routinely fire seconds apart for the same underlying event. The
    // automatic paths coalesce against this so one wake costs one rebuild.
    private var lastRestartAt: Double = 0
    private let restartCoalesceWindow: Double = 8

    /// Delivered messages, with the identity public key already verified on the
    /// transport queue (nil if unsigned/invalid) so the app layer needn't re-verify.
    var onMessage: ((Message, String?) -> Void)?
    /// Currently connected + identified peers: deviceID -> display name.
    var onConnectedPeersChanged: (([String: PeerConnectionInfo]) -> Void)?
    /// Called for each newly-ready connection to obtain the identity/announce
    /// frame to send immediately (so both ends learn each other right away).
    var helloProvider: (() -> Message?)?
    /// Fired on the main thread whenever the network path changes, so the app can
    /// re-evaluate the Wi-Fi allowlist and refresh its status UI.
    var onPathChange: (() -> Void)?

    init(config: Config) {
        self.config = config
    }

    func start() {
        queue.async { [weak self] in
            guard let self = self else { return }
            Log.trace("transport", "starting as \"\(self.config.deviceName)\", service \(self.config.serviceType)")
            self.startListener()
            self.startBrowser()
            self.startReconnectTimer()
            self.startPathMonitor()
        }
    }

    /// Tear everything down and start fresh. Used when the pairing code changes
    /// (so the new PSK takes effect immediately, no relaunch) and by the
    /// automatic recovery paths — wake, network path change, watchdog.
    /// tlsParameters() reads config.psk lazily, so the rebuilt listener/dials
    /// use the current key.
    ///
    /// `coalescing` is for the automatic recovery paths, which can be triggered
    /// twice by one real-world event: it skips the rebuild if another just
    /// happened. The pairing-code change and the user's Reconnect must never be
    /// dropped, so they leave it off.
    func restart(reason: String, coalescing: Bool = false) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let now = Date().timeIntervalSince1970
            if coalescing, now - self.lastRestartAt < self.restartCoalesceWindow {
                Log.trace("transport", "skipping restart (\(reason)) — already rebuilt "
                    + "\(String(format: "%.1f", now - self.lastRestartAt))s ago")
                return
            }
            self.lastRestartAt = now
            Log.trace("transport", "restarting (\(reason))")
            self.epoch &+= 1   // invalidate any rebuild scheduled against the old generation
            self.listenerRebuildScheduled = false; self.listenerRebuildDelay = 1
            self.browserRebuildScheduled = false; self.browserRebuildDelay = 1
            self.pathChangeWork?.cancel(); self.pathChangeWork = nil
            self.listener?.cancel(); self.listener = nil
            self.browser?.cancel(); self.browser = nil
            self.reconnectTimer?.cancel(); self.reconnectTimer = nil
            for conn in self.connections.values { conn.cancel() }
            self.connections.removeAll(); self.readyIDs.removeAll(); self.identity.removeAll()
            self.visibleEndpoints.removeAll(); self.activeOutbound.removeAll(); self.outboundKey.removeAll()
            self.dialStartedAt.removeAll()
            self.notifyPeers()
            self.startListener()
            self.startBrowser()
            self.startReconnectTimer()
            self.startPathMonitor()
        }
    }

    /// Rebuild just the listener or just the browser after a terminal `.failed`,
    /// with capped exponential backoff. Targeted rather than a full restart(),
    /// so healthy peer connections survive the repair.
    private func scheduleRebuild(_ what: Component) {
        let scheduled = what == .listener ? listenerRebuildScheduled : browserRebuildScheduled
        guard !scheduled else { return }
        let delay: Double
        if what == .listener {
            listenerRebuildScheduled = true
            delay = listenerRebuildDelay
            listenerRebuildDelay = min(maxRebuildDelay, listenerRebuildDelay * 2)
        } else {
            browserRebuildScheduled = true
            delay = browserRebuildDelay
            browserRebuildDelay = min(maxRebuildDelay, browserRebuildDelay * 2)
        }
        Log.trace("transport", "\(what.rawValue) failed — rebuilding in \(Int(delay))s")
        let gen = epoch
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, self.epoch == gen else { return }   // superseded by restart()
            switch what {
            case .listener:
                self.listenerRebuildScheduled = false
                self.listener?.cancel(); self.listener = nil
                self.startListener()
            case .browser:
                self.browserRebuildScheduled = false
                self.browser?.cancel(); self.browser = nil
                self.startBrowser()
            }
        }
    }

    private enum Component: String { case listener, browser }

    // MARK: - Network path

    /// Watch for interface-level network changes: a Wi-Fi roam to another AP or
    /// SSID, Ethernet plugged in, a VPN coming up, the network returning after
    /// being down. Bonjour registrations do not reliably survive these — the
    /// listener can keep reporting `.ready` while no longer being advertised on
    /// the new interface, and the browser's results describe the old one — and
    /// nothing in Network.framework reports that, so rebuild the transport.
    ///
    /// Only a real transition triggers a rebuild (reachability status or the set
    /// of interfaces changed), and it's debounced, because one roam emits a burst
    /// of updates. The very first callback is the baseline, not a change.
    private func startPathMonitor() {
        guard pathMonitor == nil else { return }   // survives restart(); one is enough
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            let key = "\(path.status)|"
                + path.availableInterfaces.map(\.name).sorted().joined(separator: ",")
            guard key != self.lastPathKey else { return }
            let previous = self.lastPathKey
            self.lastPathKey = key
            // Let the app re-evaluate the SSID allowlist and refresh its status,
            // including when the path goes away.
            DispatchQueue.main.async { [weak self] in self?.onPathChange?() }
            guard let previous = previous else {
                Log.trace("net", "network path baseline: \(key)")
                return
            }
            guard path.status == .satisfied else {
                Log.trace("net", "network path lost (\(key)) — waiting for a usable route")
                return
            }
            Log.trace("net", "network path changed (\(previous) -> \(key)) — rebuilding transport")
            self.pathChangeWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.restart(reason: "network path change", coalescing: true)
            }
            self.pathChangeWork = work
            self.queue.asyncAfter(deadline: .now() + 2, execute: work)
        }
        monitor.start(queue: queue)
        pathMonitor = monitor
    }

    /// Periodically re-dial any advertised peer we have no live outbound
    /// connection to. Without this, a dropped connection (sleep/wake, Wi-Fi
    /// roam) is never re-established, because the browser only fires when the
    /// *set* of advertised peers changes — a still-advertised peer whose socket
    /// died would otherwise be lost until the process restarts.
    private func startReconnectTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in self?.reconcile() }
        timer.resume()
        reconnectTimer = timer
    }

    private func reconcile() {
        expireStalledDials()
        for (key, endpoint) in visibleEndpoints where !activeOutbound.contains(key) {
            Log.trace("tls", "reconnect: dialing \(endpoint)")
            dial(key: key, endpoint: endpoint)
        }
    }

    /// Cancel outbound dials that never finished handshaking. `.waiting` cancels
    /// itself, but a connection can sit in `.preparing` indefinitely (a stale
    /// Bonjour record resolving to an address nobody answers). Its key stays in
    /// `activeOutbound`, so reconcile() skips that peer forever and it can never
    /// come back. Cancelling runs teardown(), which frees the key to be re-dialed.
    private func expireStalledDials() {
        let now = Date().timeIntervalSince1970
        for (id, started) in dialStartedAt where !readyIDs.contains(id) {
            guard now - started >= dialDeadline else { continue }
            Log.trace("tls", "dial stalled >\(Int(dialDeadline))s — cancelling to re-resolve")
            connections[id]?.cancel()   // .cancelled -> teardown() frees the outbound key
        }
    }

    // MARK: - TLS

    private func tlsParameters() -> NWParameters {
        let tls = NWProtocolTLS.Options()

        let pskData = config.psk.withUnsafeBytes { DispatchData(bytes: $0) }
        let idData = Data("tandemclip".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(
            tls.securityProtocolOptions,
            pskData as __DispatchData,
            idData as __DispatchData
        )
        // TLS_AES_128_GCM_SHA256 (0x1301) — required so both ends agree on a
        // PSK-compatible TLS 1.3 ciphersuite.
        sec_protocol_options_append_tls_ciphersuite(
            tls.securityProtocolOptions,
            tls_ciphersuite_t(rawValue: 0x1301)!
        )

        let params = NWParameters(tls: tls)
        // TCP keepalive so a peer that vanishes without a clean close (sleep,
        // Wi-Fi roam) is detected and the connection fails — otherwise it lingers
        // in `.ready`, teardown never runs, and the peer stays counted forever
        // (the "peers connected" number goes stale). Dead within ~20s.
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 8       // begin probing after 8s idle
            tcp.keepaliveInterval = 4   // probe every 4s
            tcp.keepaliveCount = 3      // give up after 3 missed probes (~20s)
            tcp.connectionDropTime = 5  // fail fast on unacknowledged data
        }
        // Infrastructure LAN only. Peer-to-peer (AWDL) resolutions flap and add
        // noise; both Macs are on the same Wi-Fi, so plain Bonjour is stabler.
        params.includePeerToPeer = false
        return params
    }

    // MARK: - Listener (incoming)

    private func startListener() {
        do {
            let l = try NWListener(using: tlsParameters())
            // Advertise under the unique deviceID, NOT the display name. Two Macs
            // with the same name would otherwise make Bonjour rename one service,
            // which breaks skip-own-by-name (a Mac skips the real peer and can
            // even dial itself). The human name travels in the message payload.
            l.service = NWListener.Service(name: config.deviceID, type: config.serviceType)
            l.newConnectionHandler = { [weak self] conn in
                Log.trace("discovery", "inbound connection from \(conn.endpoint)")
                self?.setup(conn)
            }
            l.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    Log.trace("transport", "listener ready, advertising")
                    self?.listenerRebuildDelay = 1   // healthy again; next failure retries fast
                case let .failed(err):
                    // Terminal: without a rebuild we stop advertising for the rest
                    // of the session and peers can never find us again.
                    Log.error("listener failed: \(err)")
                    self?.scheduleRebuild(.listener)
                default:
                    break
                }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            Log.error("listener error: \(error)")
        }
    }

    // MARK: - Browser (discovery -> outgoing)

    private func startBrowser() {
        let params = NWParameters()
        params.includePeerToPeer = false
        let b = NWBrowser(for: .bonjour(type: config.serviceType, domain: nil), using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self = self else { return }
            var visible: [String: NWEndpoint] = [:]
            for result in results.prefix(self.maxVisibleEndpoints) {
                // Skip our own advertisement (matched by unique deviceID).
                if case let .service(name, _, _, _) = result.endpoint,
                   name == self.config.deviceID {
                    continue
                }
                visible["\(result.endpoint)"] = result.endpoint
            }
            self.visibleEndpoints = visible
            Log.trace("discovery", "peers advertised: \(visible.count)")
            self.reconcile()   // dial anything new immediately; timer handles retries
        }
        b.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                Log.trace("discovery", "browser ready")
                self?.browserRebuildDelay = 1
            case let .failed(err):
                // Terminal, and the worst silent failure in the transport:
                // reconcile() only ever dials endpoints the browser reported, so
                // a dead browser means zero peers forever with nothing visibly
                // wrong. Rebuild it.
                Log.error("browser failed: \(err)")
                self?.scheduleRebuild(.browser)
            default:
                break
            }
        }
        b.start(queue: queue)
        browser = b
    }

    private func dial(key: String, endpoint: NWEndpoint) {
        guard !activeOutbound.contains(key) else { return }
        activeOutbound.insert(key)
        setup(NWConnection(to: endpoint, using: tlsParameters()), outKey: key)
    }

    // MARK: - Connection lifecycle

    private func setup(_ conn: NWConnection, outKey: String? = nil) {
        guard connections.count < maxConnections else {
            Log.trace("tls", "connection limit reached; dropping \(conn.endpoint)")
            // Free the reserved outbound key: this early return happens before the
            // stateUpdateHandler is installed, so teardown() never runs and the key
            // would otherwise leak in activeOutbound, permanently blocking a future
            // re-dial of this peer once a connection slot frees up.
            if let key = outKey { activeOutbound.remove(key) }
            conn.cancel()
            return
        }
        let id = ObjectIdentifier(conn)
        if let key = outKey {
            outboundKey[id] = key
            dialStartedAt[id] = Date().timeIntervalSince1970   // watched by expireStalledDials()
        }
        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                Log.trace("tls", "handshake ok, peer ready: \(conn.endpoint)")
                self.readyIDs.insert(id)
                self.receiveHeader(on: conn)
                if let hello = self.helloProvider?() { self.sendFrame(hello, on: conn) }
                self.notifyPeers()
            case let .waiting(err):
                // Path unsatisfied (e.g. a stale Bonjour resolution). Cancel so
                // teardown frees the key and reconcile() re-dials fresh, instead
                // of sitting occupied forever while counting as a live peer.
                Log.trace("tls", "connection waiting (\(conn.endpoint)): \(err) — cancelling to re-resolve")
                conn.cancel()
            case let .failed(err):
                Log.trace("tls", "connection failed (\(conn.endpoint)): \(err) — likely wrong pairing code")
                self.teardown(id)
            case .cancelled:
                Log.trace("tls", "connection closed: \(conn.endpoint)")
                self.teardown(id)
            default:
                break
            }
        }
        connections[id] = conn
        conn.start(queue: queue)
    }

    /// Drop a connection and free its outbound key so reconcile() can re-dial.
    private func teardown(_ id: ObjectIdentifier) {
        connections[id] = nil
        readyIDs.remove(id)
        identity[id] = nil
        inboundFrameTimes[id] = nil
        dialStartedAt[id] = nil
        if let key = outboundKey[id] {
            activeOutbound.remove(key)
            outboundKey[id] = nil
        }
        notifyPeers()
    }

    /// Publish the current set of connected + identified peers (deviceID -> name).
    private func notifyPeers() {
        var peers: [String: PeerConnectionInfo] = [:]
        for id in readyIDs {
            if let ident = identity[id] { peers[ident.id] = ident }
        }
        DispatchQueue.main.async { [weak self] in self?.onConnectedPeersChanged?(peers) }
    }

    /// Per-connection sliding-window inbound frame limit. Returns false when a
    /// single connection exceeds `inboundFrameMax` frames in `inboundFrameWindow`
    /// seconds; the caller then drops the connection (reconcile re-dials later).
    private func allowInboundFrame(_ id: ObjectIdentifier) -> Bool {
        let t = Date().timeIntervalSince1970
        var times = (inboundFrameTimes[id] ?? []).filter { t - $0 <= inboundFrameWindow }
        guard times.count < inboundFrameMax else { inboundFrameTimes[id] = times; return false }
        times.append(t)
        inboundFrameTimes[id] = times
        return true
    }

    // MARK: - Receive

    private func receiveHeader(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, done, err in
            guard let self = self else { return }
            guard let lenData = data, lenData.count == 4, err == nil else {
                conn.cancel(); return
            }
            // Big-endian assembly (avoids unaligned loads).
            let len = lenData.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let n = Int(len)
            // DoS ceiling, scaled to the local maxClipBytes preference so a peer
            // holding the PSK can't force oversized allocations. The whole frame
            // is buffered before the per-connection rate check runs, so this cap
            // (not the rate limit) bounds transient inbound memory: worst case is
            // maxConnections * maxFrameBytes. Headroom of 2x + base64/JSON overhead
            // over the local clip cap covers a peer configured for slightly larger
            // clips; a hard 48 MB ceiling caps it regardless of preference.
            let maxFrameBytes = min(48_000_000, max(2_000_000, self.config.maxClipBytes * 2))
            if n <= 0 || n > maxFrameBytes { conn.cancel(); return }
            self.receiveBody(on: conn, length: n)
            if done { conn.cancel() }
        }
    }

    private func receiveBody(on conn: NWConnection, length: Int) {
        let id = ObjectIdentifier(conn)
        conn.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, done, err in
            guard let self = self else { return }
            // Un-spoofable flood guard: a connection firing frames faster than any
            // honest peer is dropped before we spend work decoding/verifying them.
            guard self.allowInboundFrame(id) else {
                Log.trace("tls", "inbound frame flood on \(conn.endpoint) — cancelling")
                conn.cancel(); return
            }
            if let body = data, body.count == length,
               let msg = try? JSONDecoder().decode(Message.self, from: body) {
                // A frame carrying our own deviceID is either a loopback/self
                // connection (stale Bonjour resolution of our own service — the
                // first frame arrives before any identity is learned) or a peer
                // relaying our own broadcast back to us (gossip echo). Cancel
                // the former; for the latter just skip the frame — cancelling
                // would churn a healthy peer connection on every relay.
                if msg.deviceID == self.config.deviceID {
                    if self.identity[id] == nil {
                        Log.trace("tls", "self-connection detected — dropping \(conn.endpoint)")
                        conn.cancel(); return
                    }
                    // Identified peer echoing us — skip the frame, keep reading.
                } else {
                    Log.trace("sync", "recv \(msg.type.rawValue) \(length)B from \(msg.deviceName)")
                    // Learn/refresh this connection's identity.
                    let publicKey = DeviceIdentity.verifiedPublicKey(for: msg)
                    let known = self.identity[id]?.id == msg.deviceID
                        && self.identity[id]?.publicKey == publicKey
                    self.identity[id] = PeerConnectionInfo(id: msg.deviceID,
                                                           name: msg.deviceName,
                                                           publicKey: publicKey)
                    if !known { self.notifyPeers() }
                    DispatchQueue.main.async { self.onMessage?(msg, publicKey) }
                }
            }
            if err == nil && !done {
                self.receiveHeader(on: conn)
            } else {
                conn.cancel()
            }
        }
    }

    // MARK: - Send

    private func encode(_ msg: Message) -> Data? {
        guard let body = try? JSONEncoder().encode(msg) else { return nil }
        var len = UInt32(body.count).bigEndian
        var frame = Data(bytes: &len, count: 4)
        frame.append(body)
        return frame
    }

    /// Send on a specific connection (used for hello on ready).
    private func sendFrame(_ msg: Message, on conn: NWConnection) {
        guard let frame = encode(msg) else { return }
        conn.send(content: frame, completion: .contentProcessed { _ in })
    }

    /// Send to every ready connection.
    func broadcast(_ msg: Message) {
        guard let frame = encode(msg) else { return }
        queue.async { [weak self] in
            guard let self = self else { return }
            // One connection per identified peer: an inbound + outbound pair to the
            // same Mac would otherwise each get a copy (doubling traffic and relay
            // amplification). Connections not yet identified still get sent.
            var seen = Set<String>()
            var ready: [NWConnection] = []
            for id in self.readyIDs {
                guard let conn = self.connections[id] else { continue }
                if let did = self.identity[id]?.id {
                    if !seen.insert(did).inserted { continue }
                }
                ready.append(conn)
            }
            Log.trace("sync", "send \(msg.type.rawValue) \(frame.count)B to \(ready.count) peer(s)")
            for conn in ready { conn.send(content: frame, completion: .contentProcessed { _ in }) }
        }
    }

    /// Send to the connection(s) identified as a specific device.
    func send(_ msg: Message, to deviceID: String) {
        guard let frame = encode(msg) else { return }
        queue.async { [weak self] in
            guard let self = self else { return }
            for (id, ident) in self.identity where ident.id == deviceID && self.readyIDs.contains(id) {
                self.connections[id]?.send(content: frame, completion: .contentProcessed { _ in })
            }
        }
    }
}

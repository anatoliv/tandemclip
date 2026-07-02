import Foundation
import Network
import Security

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
    private var identity: [ObjectIdentifier: (id: String, name: String)] = [:]  // learned from messages

    // Reconnection state (all touched only on `queue`):
    private var visibleEndpoints: [String: NWEndpoint] = [:]  // key -> currently-advertised peer
    private var activeOutbound: Set<String> = []              // keys with a live/pending outbound dial
    private var outboundKey: [ObjectIdentifier: String] = [:] // conn -> its outbound endpoint key
    private var reconnectTimer: DispatchSourceTimer?

    /// Delivered messages (identity already recorded).
    var onMessage: ((Message) -> Void)?
    /// Currently connected + identified peers: deviceID -> display name.
    var onConnectedPeersChanged: (([String: String]) -> Void)?
    /// Called for each newly-ready connection to obtain the identity/announce
    /// frame to send immediately (so both ends learn each other right away).
    var helloProvider: (() -> Message?)?

    init(config: Config) {
        self.config = config
    }

    func start() {
        Log.trace("transport", "starting as \"\(config.deviceName)\", service \(config.serviceType)")
        startListener()
        startBrowser()
        startReconnectTimer()
    }

    /// Tear everything down and start fresh — used when the pairing code changes
    /// so the new PSK takes effect immediately (no relaunch). tlsParameters()
    /// reads config.psk lazily, so the rebuilt listener/dials use the new key.
    func restart() {
        queue.async { [weak self] in
            guard let self = self else { return }
            Log.trace("transport", "restarting (pairing code changed)")
            self.listener?.cancel(); self.listener = nil
            self.browser?.cancel(); self.browser = nil
            self.reconnectTimer?.cancel(); self.reconnectTimer = nil
            for conn in self.connections.values { conn.cancel() }
            self.connections.removeAll(); self.readyIDs.removeAll(); self.identity.removeAll()
            self.visibleEndpoints.removeAll(); self.activeOutbound.removeAll(); self.outboundKey.removeAll()
            self.notifyPeers()
            self.startListener()
            self.startBrowser()
            self.startReconnectTimer()
        }
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
        for (key, endpoint) in visibleEndpoints where !activeOutbound.contains(key) {
            Log.trace("tls", "reconnect: dialing \(endpoint)")
            dial(key: key, endpoint: endpoint)
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
            l.stateUpdateHandler = { state in
                switch state {
                case .ready:            Log.trace("transport", "listener ready, advertising")
                case let .failed(err):  Log.error("listener failed: \(err)")
                default:                break
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
            for result in results {
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
        let id = ObjectIdentifier(conn)
        if let key = outKey { outboundKey[id] = key }
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
        if let key = outboundKey[id] {
            activeOutbound.remove(key)
            outboundKey[id] = nil
        }
        notifyPeers()
    }

    /// Publish the current set of connected + identified peers (deviceID -> name).
    private func notifyPeers() {
        var peers: [String: String] = [:]
        for id in readyIDs {
            if let ident = identity[id] { peers[ident.id] = ident.name }
        }
        DispatchQueue.main.async { [weak self] in self?.onConnectedPeersChanged?(peers) }
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
            // Cap generously: a base64+JSON image frame is ~1.4× the raw bytes.
            if n <= 0 || n > 48_000_000 { conn.cancel(); return }
            self.receiveBody(on: conn, length: n)
            if done { conn.cancel() }
        }
    }

    private func receiveBody(on conn: NWConnection, length: Int) {
        let id = ObjectIdentifier(conn)
        conn.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, done, err in
            guard let self = self else { return }
            if let body = data, body.count == length,
               let msg = try? JSONDecoder().decode(Message.self, from: body) {
                // Guard against a loopback/self connection (e.g. a stale Bonjour
                // resolution of our own service): never treat ourselves as a peer.
                if msg.deviceID == self.config.deviceID {
                    Log.trace("tls", "self-connection detected — dropping \(conn.endpoint)")
                    conn.cancel(); return
                }
                Log.trace("sync", "recv \(msg.type.rawValue) \(length)B from \(msg.deviceName)")
                // Learn/refresh this connection's identity.
                let known = self.identity[id]?.id == msg.deviceID
                self.identity[id] = (msg.deviceID, msg.deviceName)
                if !known { self.notifyPeers() }
                DispatchQueue.main.async { self.onMessage?(msg) }
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

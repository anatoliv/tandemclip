import Foundation
import Network
import Security

/// LAN peer-to-peer transport: Bonjour discovery + PSK-TLS connections.
///
/// - Advertises `_clipboardd._tcp` via an NWListener and discovers peers with
///   an NWBrowser. LAN-only; no relay, no internet.
/// - Every connection is TLS with a pre-shared key derived from the pairing
///   code. A peer with the wrong code fails the handshake and never delivers a
///   message — so discovery alone grants nothing.
/// - Framing: 4-byte big-endian length prefix + JSON body.
final class Transport {
    private let config: Config
    private let queue = DispatchQueue(label: "tandem.transport")

    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var readyIDs: Set<ObjectIdentifier> = []         // connections past TLS handshake

    // Reconnection state (all touched only on `queue`):
    private var visibleEndpoints: [String: NWEndpoint] = [:]  // key -> currently-advertised peer
    private var activeOutbound: Set<String> = []              // keys with a live/pending outbound dial
    private var outboundKey: [ObjectIdentifier: String] = [:] // conn -> its outbound endpoint key
    private var reconnectTimer: DispatchSourceTimer?

    var onMessage: ((ClipMessage) -> Void)?
    var onPeersChanged: ((Int) -> Void)?

    init(config: Config) {
        self.config = config
    }

    func start() {
        Log.trace("transport", "starting as \"\(config.deviceName)\", service \(config.serviceType)")
        startListener()
        startBrowser()
        startReconnectTimer()
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
        let idData = Data("tandem".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
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
        // Infrastructure LAN only. Peer-to-peer (AWDL) resolutions flap and add
        // noise; both Macs are on the same Wi-Fi, so plain Bonjour is stabler.
        params.includePeerToPeer = false
        return params
    }

    // MARK: - Listener (incoming)

    private func startListener() {
        do {
            let l = try NWListener(using: tlsParameters())
            l.service = NWListener.Service(name: config.deviceName, type: config.serviceType)
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
                // Skip our own advertisement.
                if case let .service(name, _, _, _) = result.endpoint,
                   name == self.config.deviceName {
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
        if let key = outboundKey[id] {
            activeOutbound.remove(key)
            outboundKey[id] = nil
        }
        notifyPeers()
    }

    private func notifyPeers() {
        let n = readyIDs.count
        DispatchQueue.main.async { [weak self] in self?.onPeersChanged?(n) }
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
            if n <= 0 || n > 10_000_000 { conn.cancel(); return }
            self.receiveBody(on: conn, length: n)
            if done { conn.cancel() }
        }
    }

    private func receiveBody(on conn: NWConnection, length: Int) {
        conn.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, done, err in
            guard let self = self else { return }
            if let body = data, body.count == length,
               let msg = try? JSONDecoder().decode(ClipMessage.self, from: body) {
                Log.trace("sync", "recv \(length)B from \(msg.source) hash=\(msg.hash.prefix(8))")
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

    func broadcast(_ msg: ClipMessage) {
        guard let body = try? JSONEncoder().encode(msg) else { return }
        var len = UInt32(body.count).bigEndian
        var frame = Data(bytes: &len, count: 4)
        frame.append(body)
        queue.async { [weak self] in
            guard let self = self else { return }
            // Only send over connections that finished the TLS handshake; a
            // still-connecting dial would silently swallow the frame.
            let ready = self.readyIDs.compactMap { self.connections[$0] }
            Log.trace("sync", "send \(frame.count)B to \(ready.count) peer(s) hash=\(msg.hash.prefix(8))")
            for conn in ready {
                conn.send(content: frame, completion: .contentProcessed { _ in })
            }
        }
    }
}

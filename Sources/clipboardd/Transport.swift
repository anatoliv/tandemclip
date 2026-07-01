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
    private let queue = DispatchQueue(label: "clipboardd.transport")

    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var dialedEndpoints: Set<String> = []

    var onMessage: ((ClipMessage) -> Void)?
    var onPeersChanged: ((Int) -> Void)?

    init(config: Config) {
        self.config = config
    }

    func start() {
        startListener()
        startBrowser()
    }

    // MARK: - TLS

    private func tlsParameters() -> NWParameters {
        let tls = NWProtocolTLS.Options()

        let pskData = config.psk.withUnsafeBytes { DispatchData(bytes: $0) }
        let idData = Data("clipboardd".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
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
        params.includePeerToPeer = true
        return params
    }

    // MARK: - Listener (incoming)

    private func startListener() {
        do {
            let l = try NWListener(using: tlsParameters())
            l.service = NWListener.Service(name: config.deviceName, type: config.serviceType)
            l.newConnectionHandler = { [weak self] conn in self?.setup(conn) }
            l.stateUpdateHandler = { state in
                if case let .failed(err) = state { NSLog("clipboardd listener failed: \(err)") }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            NSLog("clipboardd listener error: \(error)")
        }
    }

    // MARK: - Browser (discovery -> outgoing)

    private func startBrowser() {
        let params = NWParameters()
        params.includePeerToPeer = true
        let b = NWBrowser(for: .bonjour(type: config.serviceType, domain: nil), using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self = self else { return }
            for result in results {
                // Skip our own advertisement.
                if case let .service(name, _, _, _) = result.endpoint,
                   name == self.config.deviceName {
                    continue
                }
                self.dial(result.endpoint)
            }
        }
        b.start(queue: queue)
        browser = b
    }

    private func dial(_ endpoint: NWEndpoint) {
        let key = "\(endpoint)"
        if dialedEndpoints.contains(key) { return }
        dialedEndpoints.insert(key)
        setup(NWConnection(to: endpoint, using: tlsParameters()))
    }

    // MARK: - Connection lifecycle

    private func setup(_ conn: NWConnection) {
        let id = ObjectIdentifier(conn)
        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.receiveHeader(on: conn)
                self.notifyPeers()
            case .failed, .cancelled:
                self.connections[id] = nil
                self.notifyPeers()
            default:
                break
            }
        }
        connections[id] = conn
        conn.start(queue: queue)
    }

    private func notifyPeers() {
        let n = connections.count
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
            for conn in self.connections.values {
                conn.send(content: frame, completion: .contentProcessed { _ in })
            }
        }
    }
}

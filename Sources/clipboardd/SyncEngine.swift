import Foundation

/// Glue between the local clipboard and the network: dedup, loop prevention,
/// and last-writer-wins.
///
/// `lastHash` is shared between the local and remote paths and is the core of
/// loop prevention: once a piece of content is seen (whether copied here or
/// received from a peer) it will not be re-broadcast or re-applied.
final class SyncEngine {
    let config: Config
    let watcher = ClipboardWatcher()
    let transport: Transport

    private var lastHash: String?

    private(set) var lastSyncSource: String?
    private(set) var peerCount: Int = 0
    var onStatusChange: (() -> Void)?

    init(config: Config) {
        self.config = config
        transport = Transport(config: config)

        watcher.maxBytes = config.maxClipBytes
        watcher.isPaused = { [weak self] in self?.config.paused ?? false }
        watcher.onLocalCopy = { [weak self] text, hash in self?.handleLocal(text, hash) }

        transport.onMessage = { [weak self] msg in self?.handleRemote(msg) }
        transport.onPeersChanged = { [weak self] n in
            self?.peerCount = n
            self?.onStatusChange?()
        }
    }

    func start() {
        watcher.start()
        transport.start()
    }

    private func handleLocal(_ text: String, _ hash: String) {
        guard hash != lastHash else { return }
        lastHash = hash
        let msg = ClipMessage(
            version: 1, type: "clip", contentType: "text",
            timestamp: Date().timeIntervalSince1970, hash: hash,
            source: config.deviceName, text: text
        )
        transport.broadcast(msg)
        lastSyncSource = "\(config.deviceName) (local)"
        onStatusChange?()
    }

    private func handleRemote(_ msg: ClipMessage) {
        guard !config.paused else { return }
        guard msg.type == "clip", msg.contentType == "text" else { return }
        guard msg.hash != lastHash else { return }   // already seen -> drop (echo/dup)
        lastHash = msg.hash
        watcher.write(msg.text)                       // echo-suppressed inside write()
        lastSyncSource = msg.source
        onStatusChange?()
    }
}

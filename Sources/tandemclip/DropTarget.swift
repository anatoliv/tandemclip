import AppKit
import SwiftUI

/// Drop target for the picker that accepts real file URLs AND file promises
/// (Outlook/Mail messages, Photos exports, browser images — apps that offer
/// "I'll write the file if you give me a folder" instead of an on-disk URL).
/// SwiftUI's `.onDrop(of: [.fileURL])` rejects promise-only drags outright,
/// which is why dragging an email did nothing.
///
/// Promised files are received into a temp dir; after `onURLs` returns (the
/// share reads bytes into memory synchronously) the temp dir is removed.
struct PromiseDropTarget: NSViewRepresentable {
    @Binding var targeted: Bool
    let onURLs: ([URL]) -> Void

    func makeNSView(context: Context) -> DropView {
        let v = DropView()
        v.onTargeted = { inside in DispatchQueue.main.async { targeted = inside } }
        v.onURLs = onURLs
        return v
    }

    func updateNSView(_ nsView: DropView, context: Context) {
        nsView.onURLs = onURLs
    }

    final class DropView: NSView {
        var onURLs: (([URL]) -> Void)?
        var onTargeted: ((Bool) -> Void)?
        private let promiseQueue: OperationQueue = {
            let q = OperationQueue()
            q.qualityOfService = .userInitiated
            return q
        }()

        override init(frame: NSRect) {
            super.init(frame: frame)
            var types: [NSPasteboard.PasteboardType] = [.fileURL]
            types += NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
            registerForDraggedTypes(types)
        }

        required init?(coder: NSCoder) { fatalError("unused") }

        /// Clicks pass through to the SwiftUI content beneath; drag-destination
        /// routing doesn't use hitTest, so drops still arrive here.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private func hasAcceptableContent(_ sender: NSDraggingInfo) -> Bool {
            let pb = sender.draggingPasteboard
            if pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) { return true }
            return pb.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil)
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard hasAcceptableContent(sender) else { return [] }
            onTargeted?(true)
            return .copy
        }

        override func draggingExited(_ sender: NSDraggingInfo?) { onTargeted?(false) }
        override func draggingEnded(_ sender: NSDraggingInfo) { onTargeted?(false) }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            onTargeted?(false)
            let pb = sender.draggingPasteboard
            let direct = ((pb.readObjects(forClasses: [NSURL.self],
                           options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? [])
                           .filter { $0.isFileURL }
            let receivers = (pb.readObjects(forClasses: [NSFilePromiseReceiver.self],
                                            options: nil) as? [NSFilePromiseReceiver]) ?? []
            guard !direct.isEmpty || !receivers.isEmpty else { return false }

            if receivers.isEmpty {
                onURLs?(direct)
                return true
            }

            // Receive every promised file into a fresh temp dir, then hand the
            // whole batch (direct + promised) over at once.
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("tandemclip-drops-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            var promised: [URL] = []
            let lock = NSLock()
            let group = DispatchGroup()
            for receiver in receivers {
                group.enter()
                receiver.receivePromisedFiles(atDestination: dest, options: [:],
                                              operationQueue: promiseQueue) { url, error in
                    if error == nil { lock.lock(); promised.append(url); lock.unlock() }
                    group.leave()
                }
            }
            group.notify(queue: .main) { [weak self] in
                self?.onURLs?(direct + promised)
                // Bytes were read into memory by the share; the staging dir
                // (promised files only — never the user's originals) can go.
                try? FileManager.default.removeItem(at: dest)
            }
            return true
        }
    }
}

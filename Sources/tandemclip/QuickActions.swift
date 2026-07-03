import AppKit

/// Type-aware quick actions for the hover preview: detected from clip text
/// (including OCR'd text of screenshots) with NSDataDetector — fully local.
struct QuickAction: Identifiable, Equatable {
    enum Kind: Equatable {
        case openLink(URL)
        case composeEmail(String)
        case copyPhone(String)
        case saveToDownloads
    }
    let kind: Kind
    let title: String
    let symbol: String
    var id: String { title }

    /// Up to `limit` actions for a clip. Links/emails/phones come from the
    /// clip's own text or its OCR text; file clips always offer Save.
    static func detect(for item: HistoryItem, ocrText: String?, limit: Int = 3) -> [QuickAction] {
        var actions: [QuickAction] = []
        if !item.snapshot.files.isEmpty {
            actions.append(QuickAction(kind: .saveToDownloads, title: "Save to Downloads",
                                       symbol: "arrow.down.circle"))
        }
        let text = [item.snapshot.plainText, ocrText].compactMap { $0 }.joined(separator: "\n")
        if !text.isEmpty {
            actions += detect(in: String(text.prefix(4000)))
        }
        // De-dup by title, keep order.
        var seen = Set<String>()
        return actions.filter { seen.insert($0.title).inserted }.prefix(limit).map { $0 }
    }

    static func detect(in text: String) -> [QuickAction] {
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
                | NSTextCheckingResult.CheckingType.phoneNumber.rawValue) else { return [] }
        var actions: [QuickAction] = []
        let range = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, range: range).prefix(6) {
            switch match.resultType {
            case .link:
                guard let url = match.url else { continue }
                if url.scheme == "mailto" {
                    let addr = url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
                    actions.append(QuickAction(kind: .composeEmail(addr),
                                               title: "Email \(addr.prefix(24))", symbol: "envelope"))
                } else {
                    let host = url.host ?? url.absoluteString
                    actions.append(QuickAction(kind: .openLink(url),
                                               title: "Open \(host.prefix(28))", symbol: "safari"))
                }
            case .phoneNumber:
                guard let phone = match.phoneNumber else { continue }
                actions.append(QuickAction(kind: .copyPhone(phone),
                                           title: "Copy \(phone)", symbol: "phone"))
            default: break
            }
        }
        return actions
    }

    /// Perform the action. Returns a toast line (nil = no feedback needed).
    func perform(on item: HistoryItem) -> String? {
        switch kind {
        case let .openLink(url):
            NSWorkspace.shared.open(url)
            return nil
        case let .composeEmail(addr):
            if let url = URL(string: "mailto:\(addr)") { NSWorkspace.shared.open(url) }
            return nil
        case let .copyPhone(phone):
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(phone, forType: .string)
            return "Phone number copied"
        case .saveToDownloads:
            let fm = FileManager.default
            guard let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first
            else { return "Couldn't find Downloads" }
            var saved = 0
            for f in item.snapshot.files {
                let base = (f.name as NSString).lastPathComponent
                let safe = (base.isEmpty || base == "." || base == "..") ? "file" : base
                var dest = downloads.appendingPathComponent(safe)
                var n = 1
                while fm.fileExists(atPath: dest.path) {
                    let stem = (safe as NSString).deletingPathExtension
                    let ext = (safe as NSString).pathExtension
                    dest = downloads.appendingPathComponent(
                        ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
                    n += 1
                }
                if (try? f.data.write(to: dest, options: [.atomic])) != nil { saved += 1 }
            }
            return saved > 0 ? "Saved \(saved) file\(saved == 1 ? "" : "s") to Downloads" : "Save failed"
        }
    }
}

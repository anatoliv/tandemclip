import AppKit
import NaturalLanguage
import Vision

/// On-device intelligence index over clipboard history: sentence embeddings
/// (semantic search + Ask retrieval) and OCR text for image clips. Everything
/// runs locally — NaturalLanguage embeddings and the Vision text recognizer;
/// no clip content leaves the Mac through this class.
///
/// Keyed by content hash, so re-copies and cross-Mac duplicates share entries.
/// Indexing runs on a background queue; `onUpdate` fires on the main thread
/// when new results land so the picker can refresh live.
final class ClipIndex {
    static let shared = ClipIndex()

    /// Fired on main when embeddings/OCR for some clip finished.
    var onUpdate: (() -> Void)?

    private let queue = DispatchQueue(label: "tandemclip.clipindex", qos: .utility)
    private let lock = NSLock()
    private var vectors: [String: [[Double]]] = [:]
    private var ocrTexts: [String: String] = [:]
    private var indexed: Set<String> = []        // hashes fully processed
    private var inFlight: Set<String> = []
    private lazy var embedding: NLEmbedding? = NLEmbedding.sentenceEmbedding(for: .english)

    // MARK: - Indexing

    /// Ensure every given item is (being) indexed; drop entries for hashes
    /// that no longer exist so the index tracks history size.
    func index(_ items: [HistoryItem]) {
        let liveHashes = Set(items.map(\.hash))
        lock.lock()
        let stale = indexed.subtracting(liveHashes)
        for h in stale {
            vectors[h] = nil
            ocrTexts[h] = nil
            indexed.remove(h)
        }
        let todo = items.filter { !indexed.contains($0.hash) && !inFlight.contains($0.hash) }
        for item in todo { inFlight.insert(item.hash) }
        lock.unlock()

        guard !todo.isEmpty else { return }
        queue.async { [weak self] in
            for item in todo { self?.process(item) }
        }
    }

    private func process(_ item: HistoryItem) {
        var texts: [String] = []
        if !item.label.isEmpty { texts.append(item.label) }
        if let body = item.snapshot.plainText {
            texts += body.prefix(2000).split(separator: ".")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.count > 12 }
        }
        var ocr: String?
        if item.category == .image, let data = item.imageData {
            ocr = Self.recognizeText(in: data)
            if let ocr, !ocr.isEmpty {
                texts.append(contentsOf: ocr.prefix(1000).split(separator: "\n")
                    .map(String.init).filter { $0.count > 8 })
            }
        }
        let vecs = texts.prefix(12).compactMap { embedding?.vector(for: String($0)) }

        lock.lock()
        vectors[item.hash] = vecs
        if let ocr, !ocr.isEmpty { ocrTexts[item.hash] = ocr }
        indexed.insert(item.hash)
        inFlight.remove(item.hash)
        lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.onUpdate?() }
    }

    /// Synchronous Vision OCR (runs on the index queue). Accurate-level,
    /// language-corrected — screenshots become searchable text.
    static func recognizeText(in imageData: Data) -> String? {
        guard let image = NSImage(data: imageData),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cg)
        guard (try? handler.perform([request])) != nil else { return nil }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        let text = lines.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    // MARK: - Queries

    /// Hashes whose content is semantically close to the query (per-sentence
    /// max cosine, same calibration as help search).
    func semanticHashes(for query: String) -> Set<String> {
        Set(scored(query).filter { $0.score >= 0.30 }.map(\.hash))
    }

    /// Ranked matches for retrieval (Ask). Higher = closer.
    func topMatches(for query: String, limit: Int) -> [(hash: String, score: Double)] {
        Array(scored(query).sorted { $0.score > $1.score }.prefix(limit))
    }

    private func scored(_ query: String) -> [(hash: String, score: Double)] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 3, let qv = embedding?.vector(for: q.lowercased()) else { return [] }
        lock.lock(); let snapshot = vectors; lock.unlock()
        return snapshot.compactMap { hash, vecs in
            guard let best = vecs.map({ HelpSearchModel.cosine(qv, $0) }).max() else { return nil }
            let score = best >= 0.46 ? 0.3 + (best - 0.46) * 2 : 0
            return score > 0 ? (hash, score) : nil
        }
    }

    /// Recognized text for an image clip (nil when none / not an image).
    func ocrText(for hash: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return ocrTexts[hash]
    }

    /// Block until everything queued so far is processed — tests only.
    func waitForIndexing() {
        queue.sync {}
    }
}

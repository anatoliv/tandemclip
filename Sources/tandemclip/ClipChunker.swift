import Foundation

/// Splits an encoded clip message into transport-sized slices and reassembles
/// them. Chunking is what lets clips bigger than the per-frame ceiling travel:
/// each slice rides its own signed `.chunk` message, small enough for any
/// receiver's frame cap (1 MB raw ≈ 1.4 MB framed < the 2 MB floor).
enum ClipChunker {
    /// Slice size chosen against the receiver frame-cap floor (2 MB).
    static let sliceBytes = 1_000_000
    /// Encoded clip messages up to this size go as one normal frame.
    static let directLimit = 6_000_000

    struct Slice: Equatable {
        let index: Int
        let total: Int
        let data: Data
    }

    static func slices(of payload: Data, sliceBytes: Int = ClipChunker.sliceBytes) -> [Slice] {
        guard !payload.isEmpty else { return [] }
        let total = (payload.count + sliceBytes - 1) / sliceBytes
        return (0..<total).map { i in
            let start = i * sliceBytes
            let end = min(start + sliceBytes, payload.count)
            return Slice(index: i, total: total, data: payload.subdata(in: start..<end))
        }
    }

    /// nil until every slice 0..<total is present.
    static func assemble(_ parts: [Int: Data], total: Int) -> Data? {
        guard total > 0, parts.count == total else { return nil }
        var out = Data()
        for i in 0..<total {
            guard let part = parts[i] else { return nil }
            out.append(part)
        }
        return out
    }
}

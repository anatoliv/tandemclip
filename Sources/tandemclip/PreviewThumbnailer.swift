import AppKit
import AVFoundation
import QuickLookThumbnailing

/// Renders hover-preview content for file clips: a QuickLook thumbnail (PDF
/// pages, Office documents, video frames, images — anything the system can
/// preview) and, for audio/video, the duration.
///
/// QuickLook needs a real file on disk, so the clip's first file is staged
/// into a temp dir just long enough to generate, then removed. Generation is
/// out-of-process (QLThumbnailGenerator uses sandboxed extensions), which is
/// what makes it acceptable to run on peer-supplied bytes. Results are cached
/// by content hash so hovering the same clip twice is free.
final class PreviewThumbnailer {
    static let shared = PreviewThumbnailer()

    private let thumbs = NSCache<NSString, NSImage>()
    private let durations = NSCache<NSString, NSNumber>()
    /// Hashes that produced nothing — cached too, so unsupported types don't
    /// re-stage a file on every hover.
    private var misses = Set<String>()
    private let stageDir: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tandemclip-previews", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    struct Result {
        var image: NSImage?
        var duration: Double?
    }

    /// Thumbnail + duration for the clip's first file. Returns cached results
    /// instantly; otherwise stages the file, generates, cleans up.
    @MainActor
    func preview(for item: HistoryItem) async -> Result {
        let key = item.hash as NSString
        if let img = thumbs.object(forKey: key) {
            return Result(image: img, duration: durations.object(forKey: key)?.doubleValue)
        }
        if misses.contains(item.hash) {
            return Result(image: nil, duration: durations.object(forKey: key)?.doubleValue)
        }
        guard let file = item.snapshot.files.first else { return Result() }

        // Stage under the file's real name (QuickLook picks its parser by
        // extension); prefix with the hash so concurrent clips can't collide.
        let staged = stageDir.appendingPathComponent("\(item.hash.prefix(12))-\(file.name)")
        guard (try? file.data.write(to: staged, options: [.atomic])) != nil else { return Result() }
        defer { try? FileManager.default.removeItem(at: staged) }

        var result = Result()
        result.image = await Self.quickLookThumbnail(for: staged)
        if item.category == .audio || item.category == .video {
            result.duration = await Self.mediaDuration(of: staged)
        }

        if let img = result.image { thumbs.setObject(img, forKey: key) } else { misses.insert(item.hash) }
        if let d = result.duration { durations.setObject(NSNumber(value: d), forKey: key) }
        return result
    }

    private static func quickLookThumbnail(for url: URL) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: 440, height: 300),
            scale: 2, representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        else { return nil }
        return rep.nsImage
    }

    private static func mediaDuration(of url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    /// "3:42" / "1:02:07" style.
    static func durationLabel(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

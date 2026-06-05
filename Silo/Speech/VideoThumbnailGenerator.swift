import AVFoundation
import UIKit

enum VideoThumbnailGenerator {
    private static let filename = "thumbnail.jpg"

    static func jobThumbnailURL(jobId: UUID) -> URL {
        TranscriptionCheckpointStore.jobDirectory(jobId).appendingPathComponent(filename)
    }

    static func conversationThumbnailURL(conversationId: UUID) -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("thumbnails", isDirectory: true)
        return dir.appendingPathComponent("\(conversationId.uuidString).jpg")
    }

    /// Generates a poster frame and writes JPEG into the transcription job directory.
    static func generateAndSaveForJob(jobId: UUID, mediaURL: URL) async {
        guard let image = await generate(from: mediaURL) else { return }
        let url = jobThumbnailURL(jobId: jobId)
        await Task.detached {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            guard let data = image.jpegData(compressionQuality: 0.75) else { return }
            try? data.write(to: url, options: .atomic)
        }.value
    }

    static func copyJobThumbnailToConversation(jobId: UUID, conversationId: UUID) {
        let source = jobThumbnailURL(jobId: jobId)
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        let dest = conversationThumbnailURL(conversationId: conversationId)
        try? FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: source, to: dest)
    }

    static func loadJobThumbnail(jobId: UUID) -> UIImage? {
        load(from: jobThumbnailURL(jobId: jobId))
    }

    static func loadConversationThumbnail(conversationId: UUID) -> UIImage? {
        load(from: conversationThumbnailURL(conversationId: conversationId))
    }

    static func generate(from url: URL, maxPixelSize: CGFloat = 160) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize * 2, height: maxPixelSize * 2)
        let time = CMTime(seconds: 0.5, preferredTimescale: 600)

        return await withCheckedContinuation { continuation in
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, cgImage, _, _, _ in
                if let cgImage {
                    continuation.resume(returning: UIImage(cgImage: cgImage))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private static func load(from url: URL) -> UIImage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }
}
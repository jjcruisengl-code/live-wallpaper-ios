import Foundation

struct WallpaperSettings: Codable, Equatable {
    static let minimumClipDuration = 0.5
    static let maximumClipDuration = 3.0

    var startSeconds: Double = 0
    var durationSeconds: Double = 3
    var previewSoundEnabled = false
    var includeAudio = false

    mutating func normalize(for videoDuration: Double) {
        guard videoDuration.isFinite, videoDuration > 0 else {
            startSeconds = 0
            durationSeconds = 0
            return
        }
        let upper = min(Self.maximumClipDuration, videoDuration)
        let lower = min(Self.minimumClipDuration, videoDuration)
        let requested = durationSeconds.isFinite ? durationSeconds : upper
        durationSeconds = min(max(requested, lower), upper)
        startSeconds = startSeconds.isFinite
            ? min(max(startSeconds, 0), max(0, videoDuration - durationSeconds))
            : 0
    }
}

import AVFoundation
import CoreTransferable
import Foundation
import UniformTypeIdentifiers

struct ImportedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            ImportedMovie(url: try VideoImport.copyToStaging(received.file))
        }
    }
}

struct VideoSource: Codable, Equatable {
    let filename: String
    let title: String
    let duration: Double
    let hasAudio: Bool

    var url: URL { VideoImport.libraryDirectory.appendingPathComponent(filename) }
}

enum VideoImportError: LocalizedError {
    case invalidVideo
    case tooShort
    case unavailable

    var errorDescription: String? {
        switch self {
        case .invalidVideo: return "无法读取这个视频，请选择普通的 MP4 或 MOV 视频。"
        case .tooShort: return "视频长度不足 0.5 秒，请选择更长的视频。"
        case .unavailable: return "未能读取视频。如果视频在 iCloud 中，请检查网络并重试。"
        }
    }
}

enum VideoImport {
    static var libraryDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WallpaperStudio", isDirectory: true)
    }

    static var stagingDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("WallpaperImports", isDirectory: true)
    }

    static func copyToStaging(_ source: URL) throws -> URL {
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        let ext = source.pathExtension.isEmpty ? "mov" : source.pathExtension
        let destination = stagingDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    static func stageFile(_ source: URL) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            return try copyToStaging(source)
        }.value
    }

    /// The caller owns stagedURL until this method moves it into the app library.
    static func prepare(stagedURL: URL, title: String) async throws -> VideoSource {
        let asset = AVURLAsset(url: stagedURL)
        let duration = try await asset.load(.duration).seconds
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let playable = try await asset.load(.isPlayable)
        guard playable, !tracks.isEmpty, duration.isFinite else { throw VideoImportError.invalidVideo }
        guard duration >= WallpaperSettings.minimumClipDuration else { throw VideoImportError.tooShort }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let hasAudio = !audioTracks.isEmpty
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)
        let filename = UUID().uuidString + "." + stagedURL.pathExtension
        let destination = libraryDirectory.appendingPathComponent(filename)
        try FileManager.default.moveItem(at: stagedURL, to: destination)
        return VideoSource(filename: filename, title: title, duration: duration, hasAudio: hasAudio)
    }
}

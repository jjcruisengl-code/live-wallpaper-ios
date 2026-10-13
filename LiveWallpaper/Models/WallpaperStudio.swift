import AVFoundation
import Combine
import PhotosUI
import SwiftUI

@MainActor
final class WallpaperStudio: ObservableObject {
    @Published private(set) var source: VideoSource?
    @Published var settings = WallpaperSettings()
    @Published private(set) var isImporting = false
    @Published private(set) var isExporting = false
    @Published var errorMessage: String?
    @Published var showExportSuccess = false

    let playback = LoopingPlayer()
    private let exporter = LivePhotoExporter()
    private let preferencesKey = "wallpaper-studio.v1"
    private var isActive = true

    var isBusy: Bool { isImporting || isExporting }

    private struct SavedProject: Codable {
        let source: VideoSource
        let settings: WallpaperSettings
    }

    init() {
        playback.onForcedMute = { [weak self] in
            guard let self else { return }
            self.settings.previewSoundEnabled = false
            self.saveProject()
        }
        if let data = UserDefaults.standard.data(forKey: preferencesKey),
           let saved = try? JSONDecoder().decode(SavedProject.self, from: data),
           saved.source.filename == URL(fileURLWithPath: saved.source.filename).lastPathComponent,
           saved.source.duration.isFinite, saved.source.duration >= WallpaperSettings.minimumClipDuration,
           FileManager.default.fileExists(atPath: saved.source.url.path) {
            source = saved.source
            settings = saved.settings
            settings.normalize(for: saved.source.duration)
            playback.configure(source: saved.source, settings: settings)
        }
    }

    func importPhoto(_ item: PhotosPickerItem) async {
        guard !isBusy else { return }
        isImporting = true
        defer { isImporting = false }
        do {
            guard let movie = try await item.loadTransferable(type: ImportedMovie.self) else {
                throw VideoImportError.unavailable
            }
            defer { try? FileManager.default.removeItem(at: movie.url) }
            let video = try await VideoImport.prepare(stagedURL: movie.url, title: "相册视频")
            replaceSource(video)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func importFile(_ url: URL) async {
        guard !isBusy else { return }
        isImporting = true
        defer { isImporting = false }
        do {
            let staged = try await VideoImport.stageFile(url)
            defer { try? FileManager.default.removeItem(at: staged) }
            let video = try await VideoImport.prepare(stagedURL: staged, title: url.deletingPathExtension().lastPathComponent)
            replaceSource(video)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateClip() {
        guard let source else { return }
        settings.normalize(for: source.duration)
        playback.configure(source: source, settings: settings)
        saveProject()
    }

    func updateSound() {
        playback.setSound(settings.previewSoundEnabled && source?.hasAudio == true)
        saveProject()
    }

    func saveProject() {
        guard let source,
              let data = try? JSONEncoder().encode(SavedProject(source: source, settings: settings)) else { return }
        UserDefaults.standard.set(data, forKey: preferencesKey)
    }

    func setActive(_ active: Bool) {
        isActive = active
        playback.setActive(active && !isExporting)
        if !active { saveProject() }
    }

    func export() async {
        guard let source, !isBusy else { return }
        settings.normalize(for: source.duration)
        let request = LivePhotoExportRequest(
            videoURL: source.url,
            startSeconds: settings.startSeconds,
            durationSeconds: settings.durationSeconds,
            includeAudio: settings.includeAudio && source.hasAudio
        )
        isExporting = true
        playback.setActive(false)
        defer {
            isExporting = false
            playback.setActive(isActive)
        }
        do {
            try await exporter.export(request)
            showExportSuccess = true
        } catch is CancellationError {
            errorMessage = "导出已取消，请保持 App 在前台后重试。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func replaceSource(_ video: VideoSource) {
        let previous = source
        source = video
        settings.startSeconds = 0
        settings.durationSeconds = WallpaperSettings.maximumClipDuration
        settings.normalize(for: video.duration)
        playback.configure(source: video, settings: settings)
        saveProject()
        if let previous, previous.url != video.url {
            try? FileManager.default.removeItem(at: previous.url)
        }
    }
}

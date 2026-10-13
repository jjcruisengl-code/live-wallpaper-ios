import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers

struct LivePhotoExportRequest: Sendable {
    let videoURL: URL
    let startSeconds: Double
    let durationSeconds: Double
    let includeAudio: Bool
}

enum LivePhotoExportError: LocalizedError {
    case invalidSelection
    case unavailableVideo
    case unsupportedVideo
    case photoPermissionDenied
    case preparationFailed(String)
    case encodingFailed(String)
    case imageFailed
    case invalidLivePhoto(String)
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidSelection:
            return "请选择至少 0.5 秒的有效视频片段。每次最多导出 3 秒。"
        case .unavailableVideo:
            return "视频文件不可用，请重新导入视频。"
        case .unsupportedVideo:
            return "无法读取这个视频，或视频含有受保护内容。请尝试普通的 MP4 或 MOV 视频。"
        case .photoPermissionDenied:
            return "需要添加照片的权限才能保存。请前往系统设置，为本应用允许添加照片。"
        case .preparationFailed(let detail):
            return "准备视频失败：\(detail)"
        case .encodingFailed(let detail):
            return "视频转换失败：\(detail)"
        case .imageFailed:
            return "无法生成实况照片的封面，请尝试其他片段。"
        case .invalidLivePhoto(let detail):
            return "系统未能验证这组实况照片：\(detail)"
        case .saveFailed(let detail):
            return "保存到照片失败：\(detail)"
        }
    }
}

/// Saves a validated Live Photo resource pair. A successful save does not imply
/// that iOS will accept that Live Photo as an animated lock-screen wallpaper.
actor LivePhotoExporter {
    func export(_ request: LivePhotoExportRequest) async throws {
        guard request.startSeconds.isFinite, request.startSeconds >= 0,
              request.durationSeconds.isFinite, request.durationSeconds >= 0.5 else {
            throw LivePhotoExportError.invalidSelection
        }
        guard request.videoURL.isFileURL,
              FileManager.default.fileExists(atPath: request.videoURL.path) else {
            throw LivePhotoExportError.unavailableVideo
        }
        try Task.checkCancellation()
        try await requestPhotoPermission()
        try Task.checkCancellation()

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveWallpaper-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw LivePhotoExportError.preparationFailed(error.localizedDescription)
        }
        // All asynchronous users of these resources finish before this scope exits.
        defer { try? FileManager.default.removeItem(at: directory) }

        let movieURL = directory.appendingPathComponent("paired.mov")
        let imageURL = directory.appendingPathComponent("paired.jpg")
        let identifier = UUID().uuidString
        let prepared: PreparedClip
        do {
            prepared = try await prepare(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as LivePhotoExportError {
            throw error
        } catch {
            throw LivePhotoExportError.preparationFailed(error.localizedDescription)
        }
        try Task.checkCancellation()

        let writer: LivePhotoMovieWriter
        do {
            writer = try LivePhotoMovieWriter(
                clip: prepared, outputURL: movieURL, identifier: identifier
            )
        } catch let error as LivePhotoExportError {
            throw error
        } catch {
            throw LivePhotoExportError.encodingFailed(error.localizedDescription)
        }
        try await writer.run()
        try Task.checkCancellation()

        try await writeStill(
            movieURL: movieURL, imageURL: imageURL,
            identifier: identifier, time: prepared.stillTime
        )
        try Task.checkCancellation()
        try await LivePhotoPairValidator.validate(imageURL: imageURL, movieURL: movieURL)
        try Task.checkCancellation()

        // PhotoKit commits cannot be cancelled. Once started, await their actual
        // result so we neither delete files too early nor report a saved asset as cancelled.
        try await save(imageURL: imageURL, movieURL: movieURL)
    }

    private func requestPhotoPermission() async throws {
        var status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined {
            status = await withCheckedContinuation { continuation in
                PHPhotoLibrary.requestAuthorization(for: .addOnly) {
                    continuation.resume(returning: $0)
                }
            }
        }
        guard status == .authorized || status == .limited else {
            throw LivePhotoExportError.photoPermissionDenied
        }
    }

    private func prepare(_ request: LivePhotoExportRequest) async throws -> PreparedClip {
        let source = AVURLAsset(url: request.videoURL)
        let isPlayable = try await source.load(.isPlayable)
        let isProtected = try await source.load(.hasProtectedContent)
        let duration = try await source.load(.duration)
        let sourceVideos = try await source.loadTracks(withMediaType: .video)
        guard isPlayable, !isProtected, let video = sourceVideos.first,
              duration.seconds.isFinite, duration.seconds > request.startSeconds else {
            throw LivePhotoExportError.unsupportedVideo
        }
        let sourceSize = try await video.load(.naturalSize)
        let sourceTransform = try await video.load(.preferredTransform)
        let sourceTimeRange = try await video.load(.timeRange)
        let selectedDuration = min(
            3, min(request.durationSeconds, duration.seconds - request.startSeconds)
        )
        let requestedRange = CMTimeRange(
            start: CMTime(seconds: request.startSeconds, preferredTimescale: 600),
            duration: CMTime(seconds: selectedDuration, preferredTimescale: 600)
        )
        let range = CMTimeRangeGetIntersection(requestedRange, sourceTimeRange)
        guard range.isValid, !range.isEmpty, range.duration.seconds.isFinite,
              range.duration.seconds >= 0.5 else {
            throw LivePhotoExportError.invalidSelection
        }
        try Task.checkCancellation()

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw LivePhotoExportError.unsupportedVideo
        }
        try videoTrack.insertTimeRange(range, of: video, at: .zero)

        var audioTrack: AVMutableCompositionTrack?
        if request.includeAudio,
           let audio = try await source.loadTracks(withMediaType: .audio).first {
            let audioRange = CMTimeRangeGetIntersection(
                range, try await audio.load(.timeRange)
            )
            if audioRange.isValid, !audioRange.isEmpty {
                guard let destination = composition.addMutableTrack(
                    withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
                ) else {
                    throw LivePhotoExportError.preparationFailed("无法创建音轨。")
                }
                try destination.insertTimeRange(
                    audioRange, of: audio,
                    at: CMTimeSubtract(audioRange.start, range.start)
                )
                audioTrack = destination
            }
        }

        let bounds = CGRect(origin: .zero, size: sourceSize)
            .applying(sourceTransform).standardized
        guard bounds.width.isFinite, bounds.height.isFinite,
              bounds.width >= 2, bounds.height >= 2 else {
            throw LivePhotoExportError.unsupportedVideo
        }
        // Portrait and landscape both fit within a rotated 1920 × 1080 envelope.
        let scale = min(
            1, min(1080 / min(bounds.width, bounds.height),
                   1920 / max(bounds.width, bounds.height))
        )
        let renderSize = CGSize(
            width: max(2, floor(bounds.width * scale / 2) * 2),
            height: max(2, floor(bounds.height * scale / 2) * 2)
        )
        let transform = sourceTransform
            .concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
            .concatenating(CGAffineTransform(
                scaleX: renderSize.width / bounds.width,
                y: renderSize.height / bounds.height
            ))
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        layer.setTransform(transform, at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: range.duration)
        instruction.layerInstructions = [layer]

        let videoComposition = AVMutableVideoComposition()
        videoComposition.instructions = [instruction]
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        // Explicit color conversion before 8-bit encoding also handles iPhone HDR input.
        videoComposition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        videoComposition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        videoComposition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2

        // Align the poster to a real output frame near the middle of the clip.
        let stillFrame = Int64(floor(range.duration.seconds * 30 / 2))
        return PreparedClip(
            composition: composition, videoTrack: videoTrack, audioTrack: audioTrack,
            videoComposition: videoComposition, renderSize: renderSize,
            duration: range.duration, stillTime: CMTime(value: stillFrame, timescale: 30)
        )
    }

    private func writeStill(
        movieURL: URL, imageURL: URL, identifier: String, time: CMTime
    ) async throws {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: movieURL))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        do {
            let result = try await generator.image(at: time)
            try Task.checkCancellation()
            guard let destination = CGImageDestinationCreateWithURL(
                imageURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil
            ) else {
                throw LivePhotoExportError.imageFailed
            }
            let properties: [String: Any] = [
                kCGImageDestinationLossyCompressionQuality as String: 0.95,
                kCGImagePropertyOrientation as String: 1,
                kCGImagePropertyMakerAppleDictionary as String: ["17": identifier]
            ]
            CGImageDestinationAddImage(destination, result.image, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                throw LivePhotoExportError.imageFailed
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw LivePhotoExportError.imageFailed
        }
    }

    private func save(imageURL: URL, movieURL: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                let creation = PHAssetCreationRequest.forAsset()
                let photoOptions = PHAssetResourceCreationOptions()
                photoOptions.uniformTypeIdentifier = UTType.jpeg.identifier
                let movieOptions = PHAssetResourceCreationOptions()
                movieOptions.uniformTypeIdentifier = UTType.quickTimeMovie.identifier
                // Copy resources; the enclosing export scope retains ownership of temp files.
                creation.addResource(with: .photo, fileURL: imageURL, options: photoOptions)
                creation.addResource(with: .pairedVideo, fileURL: movieURL, options: movieOptions)
            } completionHandler: { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: LivePhotoExportError.saveFailed(
                        error?.localizedDescription ?? "照片图库未能完成保存。"
                    ))
                }
            }
        }
    }
}

private struct PreparedClip {
    let composition: AVMutableComposition
    let videoTrack: AVMutableCompositionTrack
    let audioTrack: AVMutableCompositionTrack?
    let videoComposition: AVMutableVideoComposition
    let renderSize: CGSize
    let duration: CMTime
    let stillTime: CMTime
}

/// Mutable state and all reader/writer calls are confined to one serial queue.
/// No semaphore waits: audio, video and metadata can make progress independently.
private final class LivePhotoMovieWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.livewallpaper.movie-writer", qos: .userInitiated)
    private let reader: AVAssetReader
    private let writer: AVAssetWriter
    private let videoOutput: AVAssetReaderVideoCompositionOutput
    private let videoInput: AVAssetWriterInput
    private let audioOutput: AVAssetReaderAudioMixOutput?
    private let audioInput: AVAssetWriterInput?
    private let metadataInput: AVAssetWriterInput
    private let metadataAdaptor: AVAssetWriterInputMetadataAdaptor
    private let metadataGroup: AVTimedMetadataGroup
    private let duration: CMTime

    // The following properties are accessed only on queue.
    private var continuation: CheckedContinuation<Void, Error>?
    private var cancelled = false
    private var completed = false
    private var finishing = false
    private var videoFinished = false
    private var audioFinished = false
    private var metadataFinished = false
    private var videoFrameCount = 0
    private var watchdog: DispatchSourceTimer?

    init(clip: PreparedClip, outputURL: URL, identifier: String) throws {
        let reader = try AVAssetReader(asset: clip.composition)
        reader.timeRange = CMTimeRange(start: .zero, duration: clip.duration)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        writer.directoryForTemporaryFiles = outputURL.deletingLastPathComponent()

        let contentIdentifier = AVMutableMetadataItem()
        contentIdentifier.keySpace = .quickTimeMetadata
        contentIdentifier.key = "com.apple.quicktime.content.identifier" as NSString
        contentIdentifier.value = identifier as NSString
        contentIdentifier.dataType = kCMMetadataBaseDataType_UTF8 as String
        writer.metadata = [contentIdentifier]

        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: [clip.videoTrack],
            videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ]
        )
        videoOutput.videoComposition = clip.videoComposition
        videoOutput.alwaysCopiesSampleData = false
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(clip.renderSize.width),
            AVVideoHeightKey: Int(clip.renderSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 8_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalKey: 30
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        ])
        videoInput.expectsMediaDataInRealTime = false

        let audioOutput: AVAssetReaderAudioMixOutput?
        let audioInput: AVAssetWriterInput?
        if let track = clip.audioTrack {
            // Decode and downmix to a predictable stereo PCM stream before AAC encoding.
            audioOutput = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ])
            audioOutput?.alwaysCopiesSampleData = false
            audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000
            ])
            audioInput?.expectsMediaDataInRealTime = false
        } else {
            audioOutput = nil
            audioInput = nil
        }

        var metadataDescription: CMFormatDescription?
        let specifications: [[String: Any]] = [[
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String:
                "mdta/com.apple.quicktime.still-image-time",
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String:
                "com.apple.metadata.datatype.int8"
        ]]
        let status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: kCFAllocatorDefault,
            metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: specifications as CFArray,
            formatDescriptionOut: &metadataDescription
        )
        guard status == noErr, let metadataDescription else {
            throw LivePhotoExportError.encodingFailed("无法创建实况照片的时间标记。")
        }
        let metadataInput = AVAssetWriterInput(
            mediaType: .metadata, outputSettings: nil, sourceFormatHint: metadataDescription
        )
        let metadataAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadataInput)
        let stillImageTime = AVMutableMetadataItem()
        stillImageTime.keySpace = .quickTimeMetadata
        stillImageTime.key = "com.apple.quicktime.still-image-time" as NSString
        stillImageTime.value = NSNumber(value: Int8(0))
        stillImageTime.dataType = "com.apple.metadata.datatype.int8"
        let metadataGroup = AVTimedMetadataGroup(
            items: [stillImageTime],
            timeRange: CMTimeRange(
                start: clip.stillTime, duration: CMTime(value: 1, timescale: 30)
            )
        )

        guard reader.canAdd(videoOutput), writer.canAdd(videoInput),
              writer.canAdd(metadataInput) else {
            throw LivePhotoExportError.encodingFailed("设备不支持所选视频的转换。")
        }
        reader.add(videoOutput)
        writer.add(videoInput)
        writer.add(metadataInput)
        if let audioOutput, let audioInput {
            guard reader.canAdd(audioOutput), writer.canAdd(audioInput) else {
                throw LivePhotoExportError.encodingFailed("无法转换视频中的音轨。")
            }
            reader.add(audioOutput)
            writer.add(audioInput)
        }

        self.reader = reader
        self.writer = writer
        self.videoOutput = videoOutput
        self.videoInput = videoInput
        self.audioOutput = audioOutput
        self.audioInput = audioInput
        self.metadataInput = metadataInput
        self.metadataAdaptor = metadataAdaptor
        self.metadataGroup = metadataGroup
        self.duration = clip.duration
        self.audioFinished = audioInput == nil
    }

    func run() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    self.continuation = continuation
                    self.start()
                }
            }
        } onCancel: {
            self.queue.async {
                self.cancelled = true
                // cancelWriting() blocks until the writing session has stopped.
                self.fail(CancellationError())
            }
        }
    }

    private func start() {
        guard !completed else {
            // Cancellation can be enqueued before continuation installation.
            continuation?.resume(throwing: CancellationError())
            continuation = nil
            return
        }
        guard !cancelled else {
            fail(CancellationError())
            return
        }
        guard writer.startWriting() else {
            fail(encodingError())
            return
        }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else {
            fail(encodingError())
            return
        }

        // Surface codec failures even when no input becomes ready again.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        let deadline = Date().addingTimeInterval(120)
        timer.setEventHandler { [weak self] in
            guard let self, !self.completed else { return }
            if self.reader.status == .failed || self.writer.status == .failed {
                self.fail(self.encodingError())
            } else if Date() > deadline {
                self.fail(LivePhotoExportError.encodingFailed("转换超时，请尝试其他视频。"))
            }
        }
        watchdog = timer
        timer.resume()

        metadataInput.requestMediaDataWhenReady(on: queue) { [weak self] in
            guard let self, !self.completed, !self.metadataFinished,
                  self.metadataInput.isReadyForMoreMediaData else { return }
            guard self.metadataAdaptor.append(self.metadataGroup) else {
                self.fail(self.encodingError())
                return
            }
            self.metadataInput.markAsFinished()
            self.metadataFinished = true
            self.finishIfReady()
        }
        videoInput.requestMediaDataWhenReady(on: queue) { [weak self] in
            guard let self else { return }
            self.drainVideo()
        }
        if let audioInput {
            audioInput.requestMediaDataWhenReady(on: queue) { [weak self] in
                guard let self else { return }
                self.drainAudio()
            }
        }
    }

    private func drainVideo() {
        guard !completed, !videoFinished else { return }
        while videoInput.isReadyForMoreMediaData, !completed {
            // Release decoded frame buffers on every iteration, not at queue drain.
            let hasSample: Bool = autoreleasepool {
                guard let sample = videoOutput.copyNextSampleBuffer() else { return false }
                if videoInput.append(sample) {
                    videoFrameCount += 1
                } else {
                    fail(encodingError())
                }
                return true
            }
            if completed { return }
            if !hasSample {
                guard reader.status != .failed, reader.status != .cancelled,
                      videoFrameCount > 0 else {
                    fail(encodingError())
                    return
                }
                videoInput.markAsFinished()
                videoFinished = true
                finishIfReady()
                return
            }
        }
    }

    private func drainAudio() {
        guard !completed, !audioFinished, let audioInput, let audioOutput else { return }
        while audioInput.isReadyForMoreMediaData, !completed {
            let hasSample: Bool = autoreleasepool {
                guard let sample = audioOutput.copyNextSampleBuffer() else { return false }
                if !audioInput.append(sample) { fail(encodingError()) }
                return true
            }
            if completed { return }
            if !hasSample {
                guard reader.status != .failed, reader.status != .cancelled else {
                    fail(encodingError())
                    return
                }
                audioInput.markAsFinished()
                audioFinished = true
                finishIfReady()
                return
            }
        }
    }

    private func finishIfReady() {
        guard !completed, !finishing, videoFinished, audioFinished, metadataFinished else { return }
        finishing = true
        writer.endSession(atSourceTime: duration)
        writer.finishWriting { [weak self] in
            guard let self else { return }
            self.queue.async {
                if self.cancelled {
                    self.complete(.failure(CancellationError()))
                } else if self.writer.status == .completed {
                    self.complete(.success(()))
                } else {
                    self.complete(.failure(self.encodingError()))
                }
            }
        }
    }

    private func encodingError() -> Error {
        LivePhotoExportError.encodingFailed(
            writer.error?.localizedDescription ?? reader.error?.localizedDescription
                ?? "无法编码视频或实况照片元数据。"
        )
    }

    private func fail(_ error: Error) {
        guard !completed else { return }
        if reader.status == .reading { reader.cancelReading() }
        if writer.status == .writing { writer.cancelWriting() }
        complete(.failure(error))
    }

    private func complete(_ result: Result<Void, Error>) {
        guard !completed else { return }
        completed = true
        watchdog?.cancel()
        watchdog = nil
        let pending = continuation
        continuation = nil
        pending?.resume(with: result)
    }
}

/// Photos may deliver a degraded image first and the final result later.
/// Queue confinement ensures exactly one continuation resume across callbacks.
private final class LivePhotoPairValidator: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.livewallpaper.pair-validation")
    private var continuation: CheckedContinuation<Void, Error>?
    private var requestID: PHLivePhotoRequestID?
    private var finished = false
    private var cancelled = false
    private var timeout: DispatchWorkItem?

    static func validate(imageURL: URL, movieURL: URL) async throws {
        let validator = LivePhotoPairValidator()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                validator.queue.async {
                    validator.continuation = continuation
                    if validator.cancelled {
                        validator.finish(.failure(CancellationError()))
                        return
                    }
                    validator.requestID = PHLivePhoto.request(
                        withResourceFileURLs: [imageURL, movieURL],
                        placeholderImage: nil, targetSize: CGSize(width: 360, height: 640),
                        contentMode: .aspectFit
                    ) { [weak validator] livePhoto, info in
                        guard let validator else { return }
                        // Inspect only scalar results before hopping to our queue.
                        let isDegraded = (info[PHLivePhotoInfoIsDegradedKey] as? Bool) ?? false
                        let wasCancelled = (info[PHLivePhotoInfoCancelledKey] as? Bool) ?? false
                        let errorMessage = (info[PHLivePhotoInfoErrorKey] as? Error)?.localizedDescription
                        let isValid = livePhoto != nil
                        validator.queue.async {
                            if wasCancelled {
                                validator.finish(.failure(CancellationError()))
                            } else if let errorMessage {
                                validator.finish(.failure(
                                    LivePhotoExportError.invalidLivePhoto(errorMessage)
                                ))
                            } else if !isDegraded {
                                validator.finish(isValid ? .success(()) : .failure(
                                    LivePhotoExportError.invalidLivePhoto("文件配对或动态内容不受支持。")
                                ))
                            }
                        }
                    }
                    let timeout = DispatchWorkItem { [weak validator] in
                        guard let validator, !validator.finished else { return }
                        if let requestID = validator.requestID {
                            PHLivePhoto.cancelRequest(withRequestID: requestID)
                        }
                        validator.finish(.failure(
                            LivePhotoExportError.invalidLivePhoto("验证超时，请重试。")
                        ))
                    }
                    validator.timeout = timeout
                    validator.queue.asyncAfter(deadline: .now() + 30, execute: timeout)
                }
            }
        } onCancel: {
            validator.queue.async {
                guard !validator.finished else { return }
                validator.cancelled = true
                if let requestID = validator.requestID {
                    PHLivePhoto.cancelRequest(withRequestID: requestID)
                    // PhotoKit does not promise a terminal callback after cancellation.
                    // The request only reads files; late callbacks are safely ignored.
                    validator.finish(.failure(CancellationError()))
                }
            }
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard !finished else { return }
        finished = true
        timeout?.cancel()
        timeout = nil
        requestID = nil
        let pending = continuation
        continuation = nil
        if cancelled {
            pending?.resume(throwing: CancellationError())
        } else {
            pending?.resume(with: result)
        }
    }
}

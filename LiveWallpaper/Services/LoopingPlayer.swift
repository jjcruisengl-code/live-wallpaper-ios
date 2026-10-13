import AVFoundation
import Combine
import UIKit

@MainActor
final class LoopingPlayer: ObservableObject {
    let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private var active = true
    private var interrupted = false
    var onForcedMute: (@MainActor () -> Void)?
    private var wantsSound = false
    private var observers: [NSObjectProtocol] = []
    @Published private(set) var audioError: String?

    init() {
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = true
        observers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor [weak self] in
                guard let self else { return }
                if raw == AVAudioSession.InterruptionType.began.rawValue {
                    self.interrupted = true
                    self.player.pause()
                } else if raw == AVAudioSession.InterruptionType.ended.rawValue {
                    self.interrupted = false
                    if self.active && AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) {
                        self.applyPlayback()
                    }
                }
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                Task { @MainActor [weak self] in
                    // Disconnecting headphones must not unexpectedly play through the speaker.
                    self?.wantsSound = false
                    self?.player.isMuted = true
                    self?.onForcedMute?()
                    self?.audioError = "音频设备已断开，预览已静音。可重新打开预览声音。"
                    self?.deactivateAudio()
                }
            }
        })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func configure(source: VideoSource, settings: WallpaperSettings) {
        player.pause()
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
        let item = AVPlayerItem(url: source.url)
        let range = CMTimeRange(
            start: CMTime(seconds: settings.startSeconds, preferredTimescale: 600),
            duration: CMTime(seconds: settings.durationSeconds, preferredTimescale: 600)
        )
        looper = AVPlayerLooper(player: player, templateItem: item, timeRange: range)
        setSound(settings.previewSoundEnabled && source.hasAudio)
    }

    func setSound(_ enabled: Bool) {
        wantsSound = enabled
        audioError = nil
        applyPlayback()
    }

    func setActive(_ enabled: Bool) {
        active = enabled
        applyPlayback()
    }

    func clear() {
        player.pause()
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
        deactivateAudio()
    }

    private func applyPlayback() {
        guard active, !interrupted, looper != nil else {
            player.pause()
            deactivateAudio()
            return
        }
        player.isMuted = !wantsSound
        if wantsSound {
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
                try session.setActive(true)
            } catch {
                player.isMuted = true
                audioError = "无法开启预览声音：\(error.localizedDescription)"
            }
        } else {
            deactivateAudio()
        }
        player.play()
    }

    private func deactivateAudio() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

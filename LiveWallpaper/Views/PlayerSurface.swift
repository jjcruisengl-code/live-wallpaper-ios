import AVFoundation
import SwiftUI
import UIKit

struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    var fill = false

    func makeUIView(context: Context) -> VideoLayerView {
        let view = VideoLayerView()
        view.backgroundColor = .black
        view.playerLayer.player = player
        view.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        return view
    }

    func updateUIView(_ uiView: VideoLayerView, context: Context) {
        uiView.playerLayer.player = player
        uiView.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
    }

    static func dismantleUIView(_ uiView: VideoLayerView, coordinator: ()) {
        uiView.playerLayer.player = nil
    }
}

final class VideoLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

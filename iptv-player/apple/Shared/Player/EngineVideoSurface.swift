import AVFoundation
import IPTVKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The one `AVPlayerLayer` of the app (Build 17). It outlives the player screen – like VLCKit's drawable it is
/// re-parented into each presented `EngineVideoSurface` – so Picture in Picture, which is bound to this layer
/// (`PictureInPictureCoordinator`), keeps running while the player screen is dismissed and restores into the same
/// layer when it is presented again.
@MainActor
final class PlayerVideoHost {
    static let shared = PlayerVideoHost()

    final class AVPlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        // swiftlint:disable:next force_cast
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .black
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    }

    let avView = AVPlayerView()
    var playerLayer: AVPlayerLayer { avView.playerLayer }
}

/// Video output of the active `PlaybackEngine` (iOS + tvOS): the shared `AVPlayerLayer` for AVPlayer (and the remux
/// engine's private AVPlayer), the libVLC drawable for VLCKit. Both views are re-parented into a fresh container each
/// time the player screen is presented.
struct EngineVideoSurface: UIViewRepresentable {
    let engine: (any PlaybackEngine)?
    let aspect: AspectMode

    final class Container: UIView {
        weak var hosted: UIView?

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .black
            // Taps/drags belong to the SwiftUI overlay gestures, not to libVLC's GL views.
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func layoutSubviews() {
            super.layoutSubviews()
            // A newer container may have taken the shared view meanwhile: only size what is still ours.
            guard let hosted, hosted.superview === self else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hosted.frame = bounds
            CATransaction.commit()
        }

        func host(_ view: UIView?) {
            guard hosted !== view || view?.superview !== self else { return }
            if let hosted, hosted.superview === self { hosted.removeFromSuperview() }
            hosted = view
            if let view {
                view.removeFromSuperview()
                view.frame = bounds
                view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                addSubview(view)
            }
        }
    }

    func makeUIView(context: Context) -> Container {
        let view = Container()
        update(view)
        return view
    }

    func updateUIView(_ view: Container, context: Context) {
        update(view)
    }

    /// AVPlayer itself, or the private AVPlayer of the remux engine ("Apple + Remux (Beta)").
    static func avPlayerEngine(_ engine: (any PlaybackEngine)?) -> AVPlayerEngine? {
        #if canImport(CNovaRemux)
        AVPlayerEngine.backing(engine)
        #else
        engine as? AVPlayerEngine
        #endif
    }

    private func update(_ view: Container) {
        let host = PlayerVideoHost.shared
        if let av = Self.avPlayerEngine(engine) {
            if host.playerLayer.player !== av.player {
                host.playerLayer.player = av.player
                #if os(iOS)
                PictureInPictureCoordinator.shared.layerPlayerChanged()   // Build 17: PiP follows the layer's player
                #endif
            }
            if host.playerLayer.videoGravity != aspect.videoGravity { host.playerLayer.videoGravity = aspect.videoGravity }
            view.host(host.avView)
        } else {
            // No AVPlayer on screen: PiP impossible (the coordinator stops a running one on the engine switch).
            if host.playerLayer.player != nil { host.playerLayer.player = nil }
            #if canImport(MobileVLCKit) || canImport(TVVLCKit)
            view.host((engine as? VLCPlaybackEngine)?.videoView)
            #else
            view.host(nil)
            #endif
        }
    }
}

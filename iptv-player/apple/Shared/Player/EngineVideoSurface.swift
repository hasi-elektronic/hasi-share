import AVFoundation
import IPTVKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Video output of the active `PlaybackEngine` (iOS + tvOS): an `AVPlayerLayer` for AVPlayer,
/// the libVLC drawable for VLCKit. The engine's own view is re-parented into a fresh container
/// each time the player screen is presented.
struct EngineVideoSurface: UIViewRepresentable {
    let engine: (any PlaybackEngine)?
    let aspect: AspectMode

    final class Container: UIView {
        let playerLayer = AVPlayerLayer()
        weak var hosted: UIView?

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .black
            // Taps/drags belong to the SwiftUI overlay gestures, not to libVLC's GL views.
            isUserInteractionEnabled = false
            layer.addSublayer(playerLayer)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
            hosted?.frame = bounds
        }

        func host(_ view: UIView?) {
            guard hosted !== view else { return }
            hosted?.removeFromSuperview()
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
    private static func avPlayerEngine(_ engine: (any PlaybackEngine)?) -> AVPlayerEngine? {
        #if canImport(CNovaRemux)
        AVPlayerEngine.backing(engine)
        #else
        engine as? AVPlayerEngine
        #endif
    }

    private func update(_ view: Container) {
        if let av = Self.avPlayerEngine(engine) {
            if view.playerLayer.player !== av.player { view.playerLayer.player = av.player }
            view.playerLayer.videoGravity = aspect.videoGravity
            view.playerLayer.isHidden = false
            view.host(nil)
        } else {
            view.playerLayer.player = nil
            view.playerLayer.isHidden = true
            #if canImport(MobileVLCKit) || canImport(TVVLCKit)
            view.host((engine as? VLCPlaybackEngine)?.videoView)
            #else
            view.host(nil)
            #endif
        }
    }
}

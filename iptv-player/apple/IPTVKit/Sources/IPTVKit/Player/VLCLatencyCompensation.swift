import Foundation

/// Automatic output-latency term of the VLCKit engine (docs/ARCHITECTURE.md §3.2).
///
/// libVLC 3's iOS/tvOS audio output (`modules/audio_output/audiounit_ios.m`) already reads
/// `AVAudioSession.outputLatency` when the output starts and on every route change and adds it to
/// the delay it reports for A/V sync (`coreaudio_common.c`, `ca_GetLatencyLocked`) – capped at 1 s
/// ("VLC can't handle this device latency"). Adding the full latency again would double it, so only
/// the part above the cap (AirPlay ≈ 2 s) is compensated here: that audio would be heard late, so
/// it is played earlier (negative delay; VLC sign: + = audio later, `currentAudioPlaybackDelay`).
public enum VLCLatencyCompensation {
    /// Device latency libVLC compensates itself (1 s cap in `ca_SetDeviceLatency` / `ca_Initialize`).
    public static let handledByLibVLCMs = 1000

    /// Extra delay in ms for the given `AVAudioSession.outputLatency` (seconds).
    public static func autoDelayMs(outputLatency: TimeInterval) -> Int {
        guard outputLatency.isFinite, outputLatency > 0 else { return 0 }
        let ms = Int((outputLatency * 1000).rounded())
        return -max(0, ms - handledByLibVLCMs)
    }

    /// User delay (content + device) + automatic term, in ms.
    public static func totalDelayMs(userMs: Int, outputLatency: TimeInterval) -> Int {
        userMs + autoDelayMs(outputLatency: outputLatency)
    }
}

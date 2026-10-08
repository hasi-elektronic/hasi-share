import AVFoundation
import IPTVCore
import IPTVKit
import SwiftUI

/// Settings → Diagnostics → "Performance overlay": engine (first row, bold – A/V sync A/B tests), last zap
/// time (+ p50/p90), buffer state, the engine's bitrate / dropped frames, the audio output latency and the
/// audio delay the engine applies with its device / channel parts (A/V sync diagnosis, docs/ARCHITECTURE.md
/// §3.2), polled once a second. Durations only.
struct PerfOverlayView: View {
    let player: PlayerController

    #if os(tvOS)
    private static let fontSize: CGFloat = 22
    #else
    private static let fontSize: CGFloat = 12
    #endif

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let trace = PerfTrace.shared
            let diag = player.engine?.diagnostics ?? EngineDiagnostics()
            VStack(alignment: .leading, spacing: 2) {
                row("perf_engine", engineName)
                    .font(.system(size: Self.fontSize * 1.3, weight: .bold, design: .monospaced))
                row("perf_zap", zapText(trace))
                row("perf_buffer", Self.bufferText(player.phase))
                row("perf_seeks", String(player.seekCount))
                row("perf_bitrate", diag.bitrate.map { String(format: "%.2f Mbit/s", $0 / 1_000_000) } ?? "—")
                row("perf_dropped", diag.droppedFrames.map(String.init) ?? "—")
                row("perf_output_latency", "\(Int((AVAudioSession.sharedInstance().outputLatency * 1000).rounded())) ms")
                row("perf_audio_delay", L10n.t("perf_audio_delay_detail", Self.signedMs(appliedDelay(diag)),
                                               Self.signedMs(player.vlcCalibrationMs), Self.signedMs(player.contentAudioDelay)))
                // Per-device VLC calibration (Build 16, Settings → Advanced → "Calibrate audio sync").
                row("perf_vlc_calibration", Self.signedMs(player.vlcCalibrationMs))
                if let resolution = diag.resolution { Text(resolution) }
                // Launch breakdown up to the first frame (IOS-06 / QuickStart), ms since the app's init.
                if let launch = trace.launchSummary { row("perf_launch", launch) }
            }
            .font(.system(size: Self.fontSize, design: .monospaced))
            .foregroundStyle(.white)
            .padding(8)
            .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("perf_overlay")
    }

    private func row(_ key: String, _ value: String) -> some View {
        Text("\(L10n.t(key)): \(value)")
    }

    private var engineName: String {
        let name = switch player.engineKind {
        case .avPlayer: "AVPlayer"
        case .vlcKit: "VLCKit"
        case .media3: "Media3"
        case nil: "—"
        }
        return player.engineOverride == .automatic ? name : L10n.t("perf_engine_forced", name)
    }

    /// Delay the engine really applies: libVLC's read-back, else the effective value on VLCKit; AVPlayer has none.
    private func appliedDelay(_ diag: EngineDiagnostics) -> Int {
        if let applied = diag.audioDelayMs { return applied }
        return player.engineKind == .vlcKit ? player.engineAudioDelay : 0
    }

    private func zapText(_ trace: PerfTrace) -> String {
        guard let last = trace.lastZapMs else { return "—" }
        var text = "\(Int(last.rounded())) ms"
        if let p50 = trace.percentile(0.5), let p90 = trace.percentile(0.9) {
            text += " · p50 \(Int(p50.rounded())) · p90 \(Int(p90.rounded()))"
        }
        return text
    }

    /// "+150 ms" / "-50 ms" / "0 ms".
    static func signedMs(_ ms: Int) -> String { ms > 0 ? "+\(ms) ms" : "\(ms) ms" }

    private static func bufferText(_ phase: PlayerPhase) -> String {
        switch phase {
        case .idle: "idle"
        case .loading: "loading"
        case .playing: "ok"
        case .paused: "paused"
        case .buffering: "buffering"
        case .reconnecting(let attempt, let max): "reconnecting \(attempt)/\(max)"
        case .failed: "failed"
        case .locked: "locked"
        case .ended: "ended"
        }
    }
}

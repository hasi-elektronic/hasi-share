import Foundation

/// Per-load start/buffer tuning for the engines (docs/ARCHITECTURE.md §3.2, §7): live starts with
/// a small forward buffer and a capped first variant for a fast first frame, then relaxes.
public struct LiveStartTuning: Sendable, Equatable {
    /// AVPlayer `preferredForwardBufferDuration` (0 = system default).
    public var forwardBufferSeconds: Double
    /// Seconds after the first frame to re-enable `automaticallyWaitsToMinimizeStalling`
    /// (0 = keep it enabled from the start).
    public var waitToMinimizeStallingAfter: Double
    /// bps cap for the first variant (nil = no cap).
    public var initialPeakBitRate: Double?
    /// Seconds after the first frame to remove the cap.
    public var peakBitRateReleaseAfter: Double
    /// libVLC `:network-caching` in milliseconds.
    public var vlcNetworkCachingMs: Int

    public init(forwardBufferSeconds: Double, waitToMinimizeStallingAfter: Double, initialPeakBitRate: Double?,
                peakBitRateReleaseAfter: Double, vlcNetworkCachingMs: Int) {
        self.forwardBufferSeconds = forwardBufferSeconds
        self.waitToMinimizeStallingAfter = waitToMinimizeStallingAfter
        self.initialPeakBitRate = initialPeakBitRate
        self.peakBitRateReleaseAfter = peakBitRateReleaseAfter
        self.vlcNetworkCachingMs = vlcNetworkCachingMs
    }

    public static func make(isLive: Bool, largeBuffer: Bool) -> LiveStartTuning {
        if !isLive {
            return .init(forwardBufferSeconds: 0, waitToMinimizeStallingAfter: 0, initialPeakBitRate: nil,
                         peakBitRateReleaseAfter: 0, vlcNetworkCachingMs: largeBuffer ? 4000 : 2000)
        }
        if largeBuffer {
            return .init(forwardBufferSeconds: 6, waitToMinimizeStallingAfter: 0, initialPeakBitRate: nil,
                         peakBitRateReleaseAfter: 0, vlcNetworkCachingMs: 3000)
        }
        return .init(forwardBufferSeconds: 1, waitToMinimizeStallingAfter: 3, initialPeakBitRate: 2_500_000,
                     peakBitRateReleaseAfter: 4, vlcNetworkCachingMs: 1000)
    }
}

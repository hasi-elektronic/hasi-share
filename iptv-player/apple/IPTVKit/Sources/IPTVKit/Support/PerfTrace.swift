import Foundation

public enum PerfMark: String, Sendable { case appLaunch, playRequested, firstFrame }

/// Lightweight timing marks for the performance budgets (spec §1). Durations only – no URLs.
@MainActor
public final class PerfTrace {
    public static let shared = PerfTrace()
    private let clock: @Sendable () -> UInt64
    private var marks: [PerfMark: UInt64] = [:]
    private var coldStartDone = false
    public private(set) var lastZapMs: Double?
    public private(set) var lastColdStartMs: Double?
    public private(set) var zapSamples: [Double] = []

    public init(clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) { self.clock = clock }

    public func mark(_ m: PerfMark) {
        let now = clock()
        switch m {
        case .appLaunch, .playRequested:
            marks[m] = now
            if m == .playRequested { marks[.firstFrame] = nil }
        case .firstFrame:
            guard let req = marks[.playRequested], marks[.firstFrame] == nil else { return }
            marks[.firstFrame] = now
            let zap = Double(now - req) / 1_000_000
            lastZapMs = zap
            zapSamples.append(zap); if zapSamples.count > 50 { zapSamples.removeFirst() }
            if !coldStartDone, let launch = marks[.appLaunch] {
                let cold = Double(now - launch) / 1_000_000
                lastColdStartMs = cold
                coldStartDone = true
                SafeLog.info("perf coldStartMs=\(Int(cold))")
            }
            SafeLog.info("perf zapMs=\(Int(zap))")
        }
    }

    /// ms between two marks of the current play attempt (nil if missing).
    public func interval(from a: PerfMark, to b: PerfMark) -> Double? {
        guard let x = marks[a], let y = marks[b], y >= x else { return nil }
        return Double(y - x) / 1_000_000
    }

    /// Nearest-rank percentile over the last 50 zap samples (`p` in 0…1).
    public func percentile(_ p: Double) -> Double? {
        guard !zapSamples.isEmpty else { return nil }
        let s = zapSamples.sorted()
        let idx = min(s.count - 1, max(0, Int((Double(s.count) * p).rounded(.up)) - 1))
        return s[idx]
    }
}

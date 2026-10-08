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
            if m == .appLaunch, let pre = Self.preMainMs() {
                launchPhases = [("pre", Int(pre))]
                SafeLog.info("perf launch preMain=\(Int(pre))")
            }
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
                launchPhases.append(("frame", Int(cold)))
                launchSummary = launchPhases.map { "\($0.0) \($0.1)" }.joined(separator: " · ")
                SafeLog.info("perf coldStartMs=\(Int(cold))")
            }
            SafeLog.info("perf zapMs=\(Int(zap))")
        }
    }

    /// Launch profiling (IOS-06, QuickStart): logs "perf launch <phase>=<ms since appLaunch>" – durations only.
    public func launchPhase(_ phase: String) {
        guard let launch = marks[.appLaunch], !coldStartDone else { return }
        let ms = Int(Double(clock() - launch) / 1_000_000)
        launchPhases.append((phase, ms))
        SafeLog.info("perf launch \(phase)=\(ms)")
    }

    /// Launch phases of this run (ms since `appLaunch`; "pre" = before it) until the first frame.
    private var launchPhases: [(String, Int)] = []
    /// "pre 812 · env 95 · task 240 · … · frame 1480" once the first frame of the launch played (perf overlay).
    public private(set) var launchSummary: String?

    /// Time from process start to `appLaunch` (dyld, frameworks incl. VLCKit, static init), ms; nil if unknown.
    public static func preMainMs() -> Double? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_starttime
        let started = Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
        let ms = (Date().timeIntervalSince1970 - started) * 1000
        return ms > 0 && ms < 60_000 ? ms : nil
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

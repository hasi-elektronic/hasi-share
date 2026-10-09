import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Persisted anchor of the trusted clock (CONTRACT §7.3). All values in milliseconds.
public struct TrustedClockState: Codable, Sendable, Hashable {
    public var serverMs: Int64
    public var monoMs: Int64
    public var bootId: String

    public init(serverMs: Int64, monoMs: Int64, bootId: String) {
        self.serverMs = serverMs
        self.monoMs = monoMs
        self.bootId = bootId
    }
}

/// One reading of the device clocks.
public struct ClockReading: Sendable, Hashable {
    public var wallMs: Int64
    public var monoMs: Int64
    public var bootId: String

    public init(wallMs: Int64, monoMs: Int64, bootId: String) {
        self.wallMs = wallMs
        self.monoMs = monoMs
        self.bootId = bootId
    }
}

/// Trusted time (CONTRACT §7.3) – never relies on the device clock alone. Pure functions;
/// persistence of `TrustedClockState` is the platform layer's job.
public enum TrustedClock {
    /// Trusted "now" in ms.
    public static func now(state: TrustedClockState?, wallMs: Int64, monoMs: Int64, bootId: String) -> Int64 {
        guard let state else { return wallMs }
        if !bootId.isEmpty, bootId == state.bootId, monoMs >= state.monoMs {
            return state.serverMs + (monoMs - state.monoMs)
        }
        return max(wallMs, state.serverMs)
    }

    /// Trusted "now" for a clock reading.
    public static func now(state: TrustedClockState?, reading: ClockReading) -> Int64 {
        now(state: state, wallMs: reading.wallMs, monoMs: reading.monoMs, bootId: reading.bootId)
    }

    /// New state after observing a server time (token `iat`, config `serverTime`): replaced only
    /// if the new server time is later than the stored one.
    public static func update(state: TrustedClockState?, with candidate: TrustedClockState) -> TrustedClockState {
        guard let state else { return candidate }
        return candidate.serverMs > state.serverMs ? candidate : state
    }

    /// Convenience: anchor `serverMs` to a fresh reading.
    public static func update(state: TrustedClockState?, serverMs: Int64, reading: ClockReading) -> TrustedClockState {
        update(state: state, with: TrustedClockState(serverMs: serverMs, monoMs: reading.monoMs, bootId: reading.bootId))
    }
}

/// Reads the system clocks.
/// * Apple: wall = `Date()`, mono = `clock_gettime_nsec_np(CLOCK_MONOTONIC)` (includes sleep
///   on Darwin), bootId = sysctl `kern.bootsessionuuid`.
/// * Linux (tests/tools): `CLOCK_BOOTTIME` and `/proc/sys/kernel/random/boot_id`.
public enum SystemClock {
    public static func read() -> ClockReading {
        ClockReading(wallMs: Int64((Date().timeIntervalSince1970 * 1000).rounded(.down)),
                     monoMs: monotonicMs(), bootId: bootId())
    }

    public static func monotonicMs() -> Int64 {
        #if canImport(Darwin)
        return Int64(clock_gettime_nsec_np(CLOCK_MONOTONIC) / 1_000_000)
        #elseif canImport(Glibc)
        var ts = timespec()
        clock_gettime(CLOCK_BOOTTIME, &ts)
        return Int64(ts.tv_sec) * 1000 + Int64(ts.tv_nsec) / 1_000_000
        #else
        return Int64(ProcessInfo.processInfo.systemUptime * 1000)
        #endif
    }

    public static func bootId() -> String {
        #if canImport(Darwin)
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return "" }
        return String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        #else
        let text = (try? String(contentsOfFile: "/proc/sys/kernel/random/boot_id", encoding: .utf8)) ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
        #endif
    }
}

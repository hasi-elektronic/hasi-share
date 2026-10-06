import Foundation

/// User audio delay (docs/SCREENS.md §3.7, docs/ARCHITECTURE.md §3.2): one value per content
/// (channel / movie / episode content key) plus one device value (Settings → Playback, e.g. a
/// soundbar). Milliseconds, −2000…+2000 in 50 ms steps; positive = audio later. Device-local.
/// An effective delay ≠ 0 plays through VLCKit (CONTRACT §6.1) – AVPlayer cannot delay audio.
public struct AudioDelayStore: Sendable {
    private let kv: any KeyValueStore
    public static let range: ClosedRange<Int> = -2000...2000
    public static let step = 50

    public init(kv: any KeyValueStore) { self.kv = kv }

    /// Remote stepper acceleration (tvOS): ◀▶ repeated/held quickly – 50 ms for the first 4 steps,
    /// then 100 ms, from the 11th step 250 ms. `repeatCount` = steps already made in this run.
    public static func stepSize(repeatCount: Int) -> Int {
        switch repeatCount {
        case ..<4: return step
        case ..<10: return 100
        default: return 250
        }
    }

    /// Clamped to `range` and rounded to `step`.
    static func normalize(_ ms: Int) -> Int {
        let c = min(max(ms, range.lowerBound), range.upperBound)
        return Int((Double(c) / Double(step)).rounded()) * step
    }

    private func key(_ k: String) -> String { "audioDelay.\(k)" }

    /// Delay of one content (default 0).
    public func contentDelay(_ contentKey: String) -> Int { kv.value(Int.self, forKey: key(contentKey)) ?? 0 }

    /// Clamped + rounded to the step; 0 removes the key.
    public func setContentDelay(_ ms: Int, for contentKey: String) {
        let v = Self.normalize(ms)
        if v == 0 { kv.set(nil, forKey: key(contentKey)) } else { kv.setValue(v, forKey: key(contentKey)) }
    }

    /// Delay of this device's audio output (soundbar, TV), added to every content.
    public var deviceDelay: Int { kv.value(Int.self, forKey: "audioDelay.device") ?? 0 }

    public func setDeviceDelay(_ ms: Int) { kv.setValue(Self.normalize(ms), forKey: "audioDelay.device") }

    /// clamp(content + device).
    public func effectiveDelay(_ contentKey: String) -> Int { Self.normalize(contentDelay(contentKey) + deviceDelay) }
}

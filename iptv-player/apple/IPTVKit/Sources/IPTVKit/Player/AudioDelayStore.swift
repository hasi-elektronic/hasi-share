import Foundation

/// User audio delay (docs/SCREENS.md §3.7, docs/ARCHITECTURE.md §3.2): one value per content
/// (channel / movie / episode content key), −2000…+2000 ms in 50 ms steps, positive = audio later –
/// a content delay ≠ 0 plays through VLCKit (CONTRACT §6.1 rule 0, AVPlayer cannot delay audio) – plus
/// the per-device **VLC calibration** (Build 16, Settings → Advanced → "Calibrate audio sync"),
/// −500…+500 ms in 10 ms steps: added to every VLCKit item only, it never changes the engine
/// (AVPlayer compensates the output latency itself). Device-local.
///
/// The former device ("TV/soundbar") delay, which was added to every content and so forced every stream
/// into VLCKit, is migrated once into the calibration (`migrateDeviceDelayIfNeeded`).
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

    // MARK: VLC calibration (per device)

    public static let calibrationRange: ClosedRange<Int> = -500...500
    public static let calibrationStep = 10
    static let calibrationKey = "vlcCalibration.ms"
    /// Build ≤ 15 device ("TV/soundbar") delay – only read by the migration.
    static let legacyDeviceKey = "audioDelay.device"

    /// Clamped to `calibrationRange` and rounded to `calibrationStep`.
    public static func normalizeCalibration(_ ms: Int) -> Int {
        let c = min(max(ms, calibrationRange.lowerBound), calibrationRange.upperBound)
        return Int((Double(c) / Double(calibrationStep)).rounded()) * calibrationStep
    }

    /// Per-device VLCKit A/V offset (ms, + = audio later), added to every VLCKit item; never routes.
    public var vlcCalibration: Int { kv.value(Int.self, forKey: Self.calibrationKey) ?? 0 }

    public func setVLCCalibration(_ ms: Int) { kv.setValue(Self.normalizeCalibration(ms), forKey: Self.calibrationKey) }

    /// Moves the old device delay into the calibration once (an existing calibration wins) and removes it, so
    /// it no longer forces AVPlayer content into VLCKit. True when a value was migrated.
    @discardableResult
    public func migrateDeviceDelayIfNeeded() -> Bool {
        guard let legacy = kv.value(Int.self, forKey: Self.legacyDeviceKey) else { return false }
        kv.set(nil, forKey: Self.legacyDeviceKey)
        guard kv.data(forKey: Self.calibrationKey) == nil, legacy != 0 else { return false }
        setVLCCalibration(legacy)
        return true
    }

    /// "Reset sync": every per-content delay back to 0 (keys removed). The VLC calibration is a measurement of
    /// this device and stays (it is changed on the calibration screen / its row).
    public func resetAll() {
        for key in kv.keys(withPrefix: "audioDelay.") { kv.set(nil, forKey: key) }
    }

    /// Delay that decides the engine (CONTRACT §6.1 rule 0): the content's own delay only.
    public func effectiveDelay(_ contentKey: String) -> Int { contentDelay(contentKey) }
}

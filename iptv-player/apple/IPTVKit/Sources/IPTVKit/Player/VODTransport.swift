import Foundation
import IPTVCore

/// Resume rule for VOD (docs/SCREENS.md §3.7): continue automatically from a saved position of
/// at least 10 s that is not yet "watched" (≥ 95 %). A position saved without a known duration
/// (`durationMs` 0/nil – engine could not tell the length) still resumes.
public enum ResumePolicy {
    public static let minimumMs: Int64 = 10_000

    public static func startPositionMs(positionMs: Int64?, durationMs: Int64?) -> Int64? {
        guard let positionMs, positionMs >= minimumMs else { return nil }
        if WatchHistory.isCompleted(positionMs: positionMs, durationMs: durationMs ?? 0) { return nil }
        return positionMs
    }
}

/// tvOS press-and-hold seeking (docs/SCREENS.md §3.7): a ◀▶ press moves the seek target 10 s; while
/// the button is held the step repeats (every 0.3 s) and grows 10 s → 30 s (held ≥ 1 s) → 60 s
/// (≥ 3 s) → 120 s (≥ 5 s).
public enum SeekAccelerator {
    public static let baseStep: Double = 10
    /// (hold time from the press in ms, step in seconds), ascending.
    public static let stages: [(afterMs: Int64, step: Double)] = [(1_000, 30), (3_000, 60), (5_000, 120)]
    /// Hold time (from the press) before the first faster step.
    public static var accelerateAfterMs: Int64 { stages[0].afterMs }

    /// Signed step (seconds) for ◀ (-1) / ▶ (+1), `heldMs` after the button went down (0 = click).
    public static func step(direction: Int, heldMs: Int64) -> Double {
        let magnitude = stages.last(where: { heldMs >= $0.afterMs })?.step ?? baseStep
        return Double(direction < 0 ? -1 : 1) * magnitude
    }
}

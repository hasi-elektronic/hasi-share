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

/// tvOS press-and-hold seeking (docs/SCREENS.md §3.7): a ◀▶ press steps 10 s; while the button
/// is held the step repeats and grows to 30 s once it has been held for 1 s.
public enum SeekAccelerator {
    public static let baseStep: Double = 10
    public static let fastStep: Double = 30
    /// Hold time (from the press) before the fast step.
    public static let accelerateAfterMs: Int64 = 1_000

    /// Signed step (seconds) for ◀ (-1) / ▶ (+1), `heldMs` after the button went down (0 = click).
    public static func step(direction: Int, heldMs: Int64) -> Double {
        Double(direction < 0 ? -1 : 1) * (heldMs >= accelerateAfterMs ? fastStep : baseStep)
    }
}

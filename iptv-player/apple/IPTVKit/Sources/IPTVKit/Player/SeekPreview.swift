import Foundation
import IPTVCore

/// Preview-then-commit seeking (docs/SCREENS.md §3.7, tvOS): ◀▶ presses, a held ◀▶ and swipes on the
/// Siri Remote touch surface move a *target* on the timeline while playback continues; the player
/// seeks once – on OK, Play/Pause, or `commitIdleMs` after the last input (Menu cancels). Pure value
/// type: the view owns the timer and the actual seek.
public struct SeekPreview: Equatable, Sendable {
    /// No input for this long → the target is committed.
    public static let commitIdleMs: Int64 = 800
    /// A full swipe across the touch surface moves at least this far (seconds)…
    public static let minimumSwipeSpanSeconds: Double = 300
    /// …or this share of the duration, whichever is larger.
    public static let swipeSpanShare: Double = 0.1

    /// Playback position when the preview started (the delta is measured from here).
    public let origin: Double
    /// Item duration; 0 = unknown (no upper bound, no position on the bar).
    public let duration: Double
    public private(set) var target: Double
    /// Monotonic time of the last input (press, hold step, swipe movement).
    public private(set) var lastInputMs: Int64
    /// Target when the current swipe began; nil = no finger on the touch surface.
    public private(set) var panBase: Double?

    public init(origin: Double, duration: Double, nowMs: Int64) {
        let d = duration.isFinite && duration > 0 ? duration : 0
        self.duration = d
        let o = origin.isFinite ? origin : 0
        self.origin = d > 0 ? min(max(0, o), d) : max(0, o)
        self.target = self.origin
        self.lastInputMs = nowMs
    }

    /// Target − origin (seconds, signed).
    public var delta: Double { target - origin }

    /// Target as 0…1 of the duration; nil while the duration is unknown.
    public var fraction: Double? { duration > 0 ? target / duration : nil }

    public var isPanning: Bool { panBase != nil }

    /// ◀ (-1) / ▶ (+1) press or hold repeat: moves the target by the accelerated step (`SeekAccelerator`).
    public mutating func step(direction: Int, heldMs: Int64, nowMs: Int64) {
        move(to: target + SeekAccelerator.step(direction: direction, heldMs: heldMs))
        lastInputMs = nowMs
    }

    /// Finger down / swipe recognised on the touch surface.
    public mutating func beginPan(nowMs: Int64) {
        panBase = target
        lastInputMs = nowMs
    }

    /// Swipe moved: `translation` is the horizontal distance as a share of a full swipe (−1…1, may exceed).
    /// Momentum is not applied – the target follows the finger only.
    public mutating func pan(translation: Double, nowMs: Int64) {
        let base = panBase ?? target
        if panBase == nil { panBase = base }
        guard translation.isFinite else { return }
        move(to: base + translation * Self.swipeSpanSeconds(duration: duration))
        lastInputMs = nowMs
    }

    /// Finger lifted: the idle commit timer starts now.
    public mutating func endPan(nowMs: Int64) {
        panBase = nil
        lastInputMs = nowMs
    }

    /// True once nothing moved the target for `idleMs` and no finger rests on the surface.
    public func isCommitDue(nowMs: Int64, idleMs: Int64 = SeekPreview.commitIdleMs) -> Bool {
        !isPanning && nowMs - lastInputMs >= idleMs
    }

    /// Seconds covered by a full swipe: max(5 min, 10 % of the duration).
    public static func swipeSpanSeconds(duration: Double) -> Double {
        max(minimumSwipeSpanSeconds, (duration.isFinite ? max(0, duration) : 0) * swipeSpanShare)
    }

    /// Clamped to [0, duration] (unknown duration: [0, ∞)).
    private mutating func move(to seconds: Double) {
        let upper = duration > 0 ? duration : Double.greatestFiniteMagnitude
        target = min(upper, max(0, seconds))
    }

    /// "+2:30", "−0:10", "+1:02:03" (minus sign U+2212; zero → "+0:00").
    public static func deltaText(_ seconds: Double) -> String {
        let rounded = seconds.isFinite ? seconds.rounded() : 0
        return (rounded < 0 ? "\u{2212}" : "+") + shortClock(abs(rounded))
    }

    /// "0:30", "12:05", "1:02:03".
    public static func shortClock(_ seconds: Double) -> String {
        let s = seconds.isFinite ? Int(max(0, seconds)) : 0
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Preview thumbnail in the seek bubble (docs/SCREENS.md §3.7). A thumbnail needs a second connection
/// to the provider, so it is generated only where that is safe: AVPlayer (not VLCKit) on a progressive
/// VOD file (AVAssetImageGenerator cannot read HLS), and not for an Xtream source unless its account
/// allows `max_connections > 1` (unknown → no); an M3U/raw URL that looks like an Xtream panel URL
/// (`ZapPrefetcher.isXtreamShaped`) counts as an Xtream account with unknown limit.
public enum SeekThumbnailPolicy {
    /// Thumbnails are cached per 10 s of the timeline.
    public static let bucketSeconds: Double = 10
    /// At most one generator request per this interval.
    public static let minIntervalMs: Int64 = 300
    /// Longest edge of a generated thumbnail (points/pixels).
    public static let maxWidth: Double = 320

    public static func allows(engine: PlayerEngine?, request: PlaybackRequest?, stream: ResolvedStream?) -> Bool {
        guard engine == .avPlayer, let request, !request.isLive, let stream, stream.container == .mp4 else { return false }
        if let source = request.source, source.type == .xtream {
            return (source.xtreamAccount?.maxConnections ?? 0) > 1
        }
        return !ZapPrefetcher.isXtreamShaped(stream.url.absoluteString)
    }

    /// Cache bucket of a timeline position.
    public static func bucket(_ seconds: Double) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int(seconds / bucketSeconds)
    }

    /// Time the thumbnail of a bucket shows (its middle).
    public static func time(ofBucket bucket: Int) -> Double {
        Double(bucket) * bucketSeconds + bucketSeconds / 2
    }
}

/// Request scheduling of the seek thumbnails: only the newest wanted bucket is generated (a request
/// for an older one is stale and cancelled), at most one start per `SeekThumbnailPolicy.minIntervalMs`,
/// each bucket once (cached or failed).
public struct SeekThumbnailSchedule: Equatable, Sendable {
    public private(set) var wanted: Int?
    public private(set) var inFlight: Int?
    public private(set) var lastStartMs: Int64?
    /// Buckets generated (or failed) already: never requested again.
    public private(set) var settled: Set<Int> = []

    public init() {}

    /// The bubble now shows `seconds`. Returns true when the request in flight is for another bucket
    /// (the caller cancels it).
    public mutating func want(_ seconds: Double) -> Bool {
        let bucket = SeekThumbnailPolicy.bucket(seconds)
        wanted = settled.contains(bucket) ? nil : bucket
        return inFlight != nil && inFlight != bucket
    }

    /// Milliseconds to wait before the next start; nil when nothing is to be generated (or one is in flight).
    public func delayBeforeNext(nowMs: Int64) -> Int64? {
        guard inFlight == nil, wanted != nil else { return nil }
        guard let lastStartMs else { return 0 }
        return max(0, SeekThumbnailPolicy.minIntervalMs - (nowMs - lastStartMs))
    }

    /// Starts the wanted bucket if the throttle allows; returns it.
    public mutating func start(nowMs: Int64) -> Int? {
        guard delayBeforeNext(nowMs: nowMs) == 0, let bucket = wanted else { return nil }
        inFlight = bucket
        lastStartMs = nowMs
        return bucket
    }

    /// The request for `bucket` finished: `settle` = generated or failed for good (false = cancelled,
    /// may be requested again).
    public mutating func finish(_ bucket: Int, settle: Bool) {
        if inFlight == bucket { inFlight = nil }
        if settle {
            settled.insert(bucket)
            if wanted == bucket { wanted = nil }
        }
    }

    /// Nothing wanted any more (scrub ended); the settled set survives.
    public mutating func clearWanted() { wanted = nil }
}

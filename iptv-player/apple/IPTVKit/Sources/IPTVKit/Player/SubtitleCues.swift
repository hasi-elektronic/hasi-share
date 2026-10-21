import Foundation

/// One text subtitle cue (playlist time, seconds). `text` may hold `<i>…</i>` spans and "\n" line breaks.
public struct SubtitleCue: Sendable, Hashable {
    public var start: Double
    public var end: Double
    public var text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// A text subtitle track of a remuxed source (Build 21, "Apple + Remux").
public struct SourceSubtitleTrack: Sendable, Equatable {
    public var streamIndex: Int
    public var language: String?
    public var title: String?
    public var isDefault: Bool
    public var isForced: Bool

    public init(streamIndex: Int, language: String?, title: String?, isDefault: Bool, isForced: Bool) {
        self.streamIndex = streamIndex
        self.language = language
        self.title = title
        self.isDefault = isDefault
        self.isForced = isForced
    }
}

/// Cues of every text subtitle track, collected while the remuxer generates segments (any thread) and read by
/// the subtitle overlay (main thread). Segments generated twice report their cues twice → deduplicated.
public final class SubtitleCueStore: @unchecked Sendable {
    private let lock = NSLock()
    private var cues: [Int: [SubtitleCue]] = [:]      // stream index → cues sorted by start
    private var seen: Set<Key> = []

    private struct Key: Hashable {
        var stream: Int
        var startMs: Int64
        var text: String
    }

    public init() {}

    public func add(stream: Int, cue: SubtitleCue) {
        let key = Key(stream: stream, startMs: Int64((cue.start * 1000).rounded()), text: cue.text)
        lock.lock()
        defer { lock.unlock() }
        guard seen.insert(key).inserted else { return }
        var list = cues[stream, default: []]
        let index = list.firstIndex { $0.start > cue.start } ?? list.endIndex   // segments arrive mostly in order
        list.insert(cue, at: index)
        cues[stream] = list
    }

    /// Texts on screen at `time` (start ≤ time < end), oldest first.
    public func texts(stream: Int, at time: Double) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard let list = cues[stream], !list.isEmpty else { return [] }
        // Cues are sorted by start: binary search the last cue starting at or before `time`, then look back for
        // overlapping ones (a cue rarely lasts longer than 10 s).
        var lo = 0, hi = list.count - 1, last = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if list[mid].start <= time { last = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        guard last >= 0 else { return [] }
        var out: [String] = []
        var i = last
        while i >= 0, time - list[i].start < 60 {
            if time < list[i].end { out.append(list[i].text) }
            i -= 1
        }
        return out.reversed()
    }

    public func removeAll() {
        lock.lock()
        cues.removeAll()
        seen.removeAll()
        lock.unlock()
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return cues.values.reduce(0) { $0 + $1.count }
    }
}

public enum SourceSubtitleTracks {
    /// Menu options (id = position): language name, else title, else nil ("Track n"); a forced track says so via its
    /// title when it has one. Equal names get the title appended.
    public static func options(_ tracks: [SourceSubtitleTrack], locale: Locale = .current) -> [MediaOption] {
        let base = tracks.map { TrackNaming.displayName(forLanguage: $0.language, locale: locale) ?? nonEmpty($0.title) }
        return tracks.enumerated().map { index, track in
            var name = base[index]
            if let current = name, base.filter({ $0 == current }).count > 1, let title = nonEmpty(track.title), title != current {
                name = "\(current) · \(title)"
            }
            return MediaOption(id: index, name: name, languageCode: nonEmpty(track.language))
        }
    }

    /// Track to show at start: the preferred language (non-forced first), else nil (off).
    public static func initialSelection(_ tracks: [SourceSubtitleTrack], preferred: String?) -> Int? {
        guard preferred != nil else { return nil }
        let matching = tracks.indices.filter { TrackNaming.matches(tracks[$0].language, preferred: preferred) }
        return matching.first { !tracks[$0].isForced } ?? matching.first
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }
}

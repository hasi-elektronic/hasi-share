import Foundation

/// Audio tracks of a remuxed source (Build 20, "Apple + Remux"): the remuxer muxes ONE track into the local
/// HLS, so the player's audio menu lists the source's tracks itself and a choice reopens the remux session
/// with that track at the current position (CONTRACT §6.1 rule 1a).
public struct SourceAudioTrack: Sendable, Equatable {
    /// Source stream index (what the remuxer opens).
    public var streamIndex: Int
    public var language: String?
    public var codec: String
    public var channels: Int
    public var title: String?

    public init(streamIndex: Int, language: String?, codec: String, channels: Int, title: String?) {
        self.streamIndex = streamIndex
        self.language = language
        self.codec = codec
        self.channels = channels
        self.title = title
    }
}

public enum SourceAudioTracks {
    /// Menu options (id = position in `tracks`): the language name ("Türkçe"), else the container title, else
    /// nil ("Track n"). Tracks that would share a name get the format ("Deutsch · AC3 5.1") or their title.
    public static func options(_ tracks: [SourceAudioTrack], locale: Locale = .current) -> [MediaOption] {
        let base = tracks.map { track -> String? in
            TrackNaming.displayName(forLanguage: track.language, locale: locale) ?? nonEmpty(track.title)
        }
        return tracks.enumerated().map { index, track in
            var name = base[index]
            if let current = name, base.filter({ $0 == current }).count > 1 {
                if let title = nonEmpty(track.title), title != current {
                    name = "\(current) · \(title)"
                } else {
                    name = "\(current) · \(format(track))"
                }
            }
            return MediaOption(id: index, name: name, languageCode: nonEmpty(track.language))
        }
    }

    /// Menu position of the source stream `streamIndex` (nil = not in the list).
    public static func index(of streamIndex: Int, in tracks: [SourceAudioTrack]) -> Int? {
        tracks.firstIndex { $0.streamIndex == streamIndex }
    }

    /// "AC3 5.1", "AAC 2.0", "DTS".
    static func format(_ track: SourceAudioTrack) -> String {
        let codec = track.codec.uppercased()
        switch track.channels {
        case 1: return "\(codec) 1.0"
        case 2: return "\(codec) 2.0"
        case 6: return "\(codec) 5.1"
        case 8: return "\(codec) 7.1"
        default: return codec
        }
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }
}

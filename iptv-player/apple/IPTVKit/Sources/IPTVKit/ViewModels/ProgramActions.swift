import Foundation
import IPTVCore

/// What the programme detail sheet of the guide offers (SCREENS §3.4): live, catch-up from the start / the
/// recording, reminder.
public struct ProgramActions: Sendable, Hashable {
    public enum Timing: Sendable, Hashable { case past, onAir, future }
    public var timing: Timing
    /// "Jetzt ansehen": the channel live (always).
    public var canWatchLive = true
    /// "Von Anfang an" (on air) / "Aufnahme ansehen" (past): the archive URL can be built and the programme is within
    /// the channel's catch-up days.
    public var canReplay: Bool
    /// "Erinnern": the programme has not started.
    public var canRemind: Bool

    /// Decides the actions; `replayURL` = the archive URL (nil: no catch-up for this channel / source).
    public static func decide(program: EpgProgram, catchup: CatchupInfo, replayURL: String?, now: Date) -> ProgramActions {
        let timing: Timing = program.end <= now ? .past : (program.start <= now ? .onAir : .future)
        var replay = false
        if replayURL != nil, catchup.isAvailable, timing != .future {
            let days = max(catchup.days, 1)
            replay = program.start >= now.addingTimeInterval(-TimeInterval(days) * 86_400)
        }
        return ProgramActions(timing: timing, canReplay: replay, canRemind: timing == .future)
    }
}

extension AppEnvironment {
    /// Archive URL of `program` on `channel` (CONTRACT §4.5 Xtream timeshift, §3.9 M3U catch-up); nil without
    /// catch-up. A programme on air gets its start-over URL (the server serves up to now).
    public func catchupURL(channel: Channel, program: EpgProgram, now: Date = Date()) -> String? {
        switch secrets(for: channel.sourceId) {
        case .xtream(let secrets)?:
            guard let builder = XtreamURLBuilder(secrets: secrets) else { return nil }
            let account = sources.first { $0.id == channel.sourceId }?.xtreamAccount
            let ext = (account?.allowedOutputFormats.isEmpty ?? true) || account?.allowedOutputFormats.contains("m3u8") == true ? "m3u8" : "ts"
            return builder.timeshiftURL(streamId: channel.id, start: program.start, end: program.end,
                                        serverTimezone: account?.serverTimezone, ext: ext).absoluteString
        case .m3u?:
            guard let url = channel.url else { return nil }
            return CatchupURLBuilder.url(channelURL: url, catchup: channel.catchup, start: program.start, end: program.end, now: now)
        case nil:
            return nil
        }
    }

    /// The detail sheet's actions for `program`.
    public func programActions(channel: Channel, program: EpgProgram, now: Date = Date()) -> ProgramActions {
        let url = channel.catchup.isAvailable ? catchupURL(channel: channel, program: program, now: now) : nil
        return ProgramActions.decide(program: program, catchup: channel.catchup, replayURL: url, now: now)
    }

    /// True when the catch-up archive of `channel` can be played at all (Xtream with archive, M3U with a buildable URL).
    public func canReplayArchive(of channel: Channel) -> Bool {
        guard channel.catchup.isAvailable else { return false }
        let probe = EpgProgram(sourceId: channel.sourceId, channelEpgId: channel.epgId ?? "", start: Date(timeIntervalSince1970: 0),
                               end: Date(timeIntervalSince1970: 3600), title: "")
        return catchupURL(channel: channel, program: probe, now: Date(timeIntervalSince1970: 7200)) != nil
    }
}

extension AppEnvironment {
    /// A progress / favorite entry of locked content (parental lock active): movies and live channels by their
    /// categories (channels also individually), episodes through their series.
    public func isLocked(progress item: SyncItem, sourceId: String) -> Bool {
        guard catalog.contentLock.filter != nil, let key = ContentKey.parse(item.contentKey) else { return false }
        switch key.kind {
        case .movie: return catalog.isLocked(sourceId: sourceId, kind: .movie, itemId: key.itemId)
        case .live: return catalog.isLocked(sourceId: sourceId, kind: .live, itemId: key.itemId)
        case .series: return catalog.isLocked(sourceId: sourceId, kind: .series, itemId: key.itemId)
        case .episode:
            if let seriesId = item.data.seriesKey.flatMap(ContentKey.parse)?.itemId {
                return catalog.isLocked(sourceId: sourceId, kind: .series, itemId: seriesId)
            }
            if let episode = (try? catalog.episodeIgnoringLock(sourceId: sourceId, id: key.itemId)) ?? nil {
                return catalog.isLocked(sourceId: sourceId, kind: .series, itemId: episode.seriesId)
            }
            return false
        }
    }
}

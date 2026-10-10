import Foundation
import IPTVCore

/// One way to play an opened item: an engine and the URL it gets.
public struct PlaybackAttempt: Hashable, Sendable {
    public var engine: PlayerEngine
    public var url: URL
    public var container: StreamContainer

    public init(engine: PlayerEngine, url: URL, container: StreamContainer) {
        self.engine = engine
        self.url = url
        self.container = container
    }
}

/// Build 24 (CONTRACT §6.2 "never give up early"): an item that has not shown a frame yet tries every other way to
/// play before an error card – the other engines for the same URL, then (live Xtream) the other stream format with
/// its engines. A user engine override limits the engines, never the URL variant. Only when every attempt failed the
/// reconnect policy / error card take over.
public enum PlaybackRescue {
    /// All attempts in order; the first is the normal choice (`first`).
    public static func plan(first: PlaybackAttempt, isLive: Bool, override: PlayerEngineOverride, vlcAvailable: Bool,
                            remuxAvailable: Bool, remuxPreferred: Bool) -> [PlaybackAttempt] {
        var out = [first]
        func add(_ attempt: PlaybackAttempt) { if !out.contains(attempt) { out.append(attempt) } }
        for engine in engines(for: first.container, override: override, vlcAvailable: vlcAvailable,
                              remuxAvailable: remuxAvailable, remuxPreferred: remuxPreferred) {
            add(PlaybackAttempt(engine: engine, url: first.url, container: first.container))
        }
        if isLive, let alternate = liveAlternate(first.url) {
            let container = StreamFormatDetector.detect(url: alternate.absoluteString)
            for engine in engines(for: container, override: override, vlcAvailable: vlcAvailable,
                                  remuxAvailable: remuxAvailable, remuxPreferred: remuxPreferred) {
                add(PlaybackAttempt(engine: engine, url: alternate, container: container))
            }
        }
        return out
    }

    /// Engines that can play `container`, in the order they are tried (the override limits them).
    static func engines(for container: StreamContainer, override: PlayerEngineOverride, vlcAvailable: Bool,
                        remuxAvailable: Bool, remuxPreferred: Bool) -> [PlayerEngine] {
        let av = container.isSupported(by: .avPlayer)
        let vlc = vlcAvailable && container.isSupported(by: .vlcKit)
        let remux = remuxAvailable && container.isSupported(by: .avRemux)
        switch override {
        case .avPlayer:
            return av ? [.avPlayer] : []
        case .vlcKit:
            return vlc ? [.vlcKit] : (av ? [.avPlayer] : [])
        case .automatic, .remux:
            var list: [PlayerEngine] = []
            let preferRemux = remux && (remuxPreferred || override == .remux)
            if preferRemux { list.append(.avRemux) }
            if av { list.append(.avPlayer) }
            if vlc { list.append(.vlcKit) }
            if remux, !preferRemux { list.append(.avRemux) }
            return list
        }
    }

    /// The other format of an Xtream live URL (`/live/U/P/ID.m3u8` ⇄ `.ts`), nil for anything else.
    public static func liveAlternate(_ url: URL) -> URL? {
        let components = url.path.split(separator: "/")
        guard components.count >= 4, components[components.count - 4] == "live" else { return nil }
        let string = url.absoluteString
        if string.hasSuffix(".m3u8") { return URL(string: String(string.dropLast(5)) + ".ts") }
        if string.hasSuffix(".ts") { return URL(string: String(string.dropLast(3)) + ".m3u8") }
        return nil
    }

    /// Everything except DRM is worth another way (a 403/404 on one format often plays in the other).
    public static func isRescuable(_ error: PlaybackError) -> Bool {
        if case .drm = error { return false }
        return true
    }

    /// A definite HTTP answer (403 / 404 / 410 / 5xx) for this URL: another engine on the same URL gets the same answer,
    /// so only another URL (the live format variant) is worth trying.
    public static func needsOtherURL(_ error: PlaybackError) -> Bool {
        switch error {
        case .accessDenied, .streamOffline, .serverError: return true
        default: return false
        }
    }
}

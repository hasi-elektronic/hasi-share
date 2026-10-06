import Foundation
import IPTVCore
import IPTVKit
#if canImport(UIKit)
import UIKit
#endif
#if canImport(MobileVLCKit)
import MobileVLCKit
#elseif canImport(TVVLCKit)
import TVVLCKit
#endif

#if canImport(MobileVLCKit) || canImport(TVVLCKit)
/// VLCKit 3 engine (libVLC, LGPL-2.1, dynamic framework) for everything AVPlayer cannot open:
/// MKV, WebM, AVI, FLV, progressive MPEG-TS, DASH, RTSP, RTMP (CONTRACT §6.1).
///
/// libVLC reports no failure reason, so errors are classified with an HTTP probe
/// (`VLCFailureClassifier`) to get the same error cards as AVPlayer (SCREENS §4). Tracks come
/// from `audioTrackIndexes` / `videoSubTitlesIndexes` + `media.tracksInformation` languages.
@MainActor
final class VLCPlaybackEngine: NSObject, PlaybackEngine {
    let kind: PlayerEngine = .vlcKit
    var onEvent: (@MainActor (EngineEvent) -> Void)?
    /// Drawable shared with `EngineVideoSurface` (re-parented into each presented surface).
    let videoView = VLCDrawableView()

    private let player: VLCMediaPlayer
    private var stream: ResolvedStream?
    private var isLive = false
    private var hadPlayed = false
    private var reportedReady = false
    private var failureTask: Task<Void, Never>?
    private var lastReportedTime: Double = -1
    private var aspect: AspectMode = .fit
    private var preferredAudio: String?
    private var preferredSubtitle: String?
    private var appliedPreferences = false
    /// libVLC track ids behind our option ids (index = `MediaOption.id`).
    private var audioIds: [Int32] = []
    private var subtitleIds: [Int32] = []
    private var lastTracksSignature = ""

    override init() {
        player = VLCMediaPlayer()
        super.init()
        player.delegate = self
        player.drawable = videoView
        videoView.onLayout = { [weak self] _ in self?.applyAspect() }
    }

    var isPlaying: Bool { player.isPlaying }
    var canPause: Bool { player.canPause }

    /// `VLCMedia.statistics`: `demuxBitrate` is bytes per microsecond (libVLC) → ×1 000 000 B/s
    /// × 8 = bit/s; `lostPictures` is the session total. 0 bitrate = empty buffer → unknown.
    var diagnostics: EngineDiagnostics {
        guard let media = player.media, player.isPlaying else { return EngineDiagnostics() }
        let stats = media.statistics
        let size = player.videoSize
        return EngineDiagnostics(
            bitrate: stats.demuxBitrate > 0 ? Double(stats.demuxBitrate) * 8_000_000 : nil,
            droppedFrames: Int(stats.lostPictures),
            resolution: size.width > 0 && size.height > 0 ? "\(Int(size.width))x\(Int(size.height))" : nil)
    }

    func load(_ stream: ResolvedStream, isLive: Bool, startMs: Int64?, preferredAudioLanguage: String?, preferredSubtitleLanguage: String?, tuning: LiveStartTuning) {
        failureTask?.cancel()
        self.stream = stream
        self.isLive = isLive
        hadPlayed = false
        reportedReady = false
        lastReportedTime = -1
        appliedPreferences = false
        audioIds = []
        subtitleIds = []
        lastTracksSignature = ""
        preferredAudio = preferredAudioLanguage
        preferredSubtitle = preferredSubtitleLanguage

        let media = VLCMedia(url: stream.url)
        // Live: small but safe cache for IPTV; VOD: a little more for HTTP seeks (LiveStartTuning).
        media.addOption(":network-caching=\(tuning.vlcNetworkCachingMs)")
        if let ua = stream.headers["User-Agent"] { media.addOption(":http-user-agent=\(ua)") }
        if let referer = stream.headers["Referer"] { media.addOption(":http-referrer=\(referer)") }
        if let startMs, startMs > 0 { media.addOption(":start-time=\(Double(startMs) / 1000)") }
        if stream.container == .rtsp { media.addOption(":rtsp-tcp") }
        player.media = media
        applyAspect()
        player.play()
    }

    func play() { player.play() }

    func pause() {
        if player.canPause { player.pause() }
    }

    func seek(to seconds: Double) {
        guard !isLive else { return }
        player.time = VLCTime(int: Int32(clamping: Int(max(0, seconds) * 1000)))
        lastReportedTime = seconds
        onEvent?(.time(seconds))
    }

    func selectAudio(_ id: Int) {
        guard audioIds.indices.contains(id) else { return }
        player.currentAudioTrackIndex = audioIds[id]
        reportTracks(force: true)
    }

    func selectSubtitle(_ id: Int?) {
        if let id, subtitleIds.indices.contains(id) {
            player.currentVideoSubTitleIndex = subtitleIds[id]
        } else {
            player.currentVideoSubTitleIndex = -1
        }
        reportTracks(force: true)
    }

    func setAspect(_ mode: AspectMode) {
        aspect = mode
        applyAspect()
    }

    func stop() {
        failureTask?.cancel()
        stream = nil
        if player.media != nil {
            player.stop()
            player.media = nil
        }
    }

    // MARK: Aspect

    /// fit → libVLC default; fill → crop to the view ratio; stretch / 16:9 / 4:3 → force the
    /// video aspect to the view's own ratio (SwiftUI sizes the view to 16:9 / 4:3 for those).
    private func applyAspect() {
        let size = videoView.bounds.size
        let viewRatio = size.width > 0 && size.height > 0 ? "\(Int(size.width.rounded())):\(Int(size.height.rounded()))" : nil
        switch aspect {
        case .fit:
            setRatio(nil)
            setCrop(nil)
        case .fill:
            setRatio(nil)
            setCrop(viewRatio)
        case .stretch, .ratio16x9, .ratio4x3:
            setCrop(nil)
            setRatio(viewRatio)
        }
    }

    private var currentRatio: String?
    private var currentCrop: String?

    private func setRatio(_ value: String?) {
        guard value != currentRatio else { return }
        currentRatio = value
        Self.withCString(value) { player.videoAspectRatio = $0 }
    }

    private func setCrop(_ value: String?) {
        guard value != currentCrop else { return }
        currentCrop = value
        Self.withCString(value) { player.videoCropGeometry = $0 }
    }

    private static func withCString(_ value: String?, _ body: (UnsafeMutablePointer<CChar>?) -> Void) {
        guard let value else { return body(nil) }
        var bytes = Array(value.utf8CString)
        bytes.withUnsafeMutableBufferPointer { body($0.baseAddress) }
    }

    // MARK: State

    fileprivate func stateChanged() {
        guard stream != nil else { return }
        switch player.state {
        case .playing:
            hadPlayed = true
            failureTask?.cancel()
            reportReadyIfNeeded()
            onEvent?(.playing)
            reportTracks(force: false)
        case .paused:
            onEvent?(.paused)
        case .buffering:
            // libVLC sends buffering while playing too; only meaningful before first frames.
            if !player.isPlaying { onEvent?(.buffering) }
        case .esAdded:
            reportTracks(force: false)
        case .error:
            classifyFailure(ended: false)
        case .ended:
            classifyFailure(ended: true)
        case .stopped, .opening:
            break
        @unknown default:
            break
        }
    }

    fileprivate func timeChanged() {
        guard stream != nil else { return }
        if !hadPlayed, player.isPlaying { hadPlayed = true }
        reportReadyIfNeeded()
        let ms = player.time.value?.doubleValue ?? 0
        let seconds = ms / 1000
        if abs(seconds - lastReportedTime) >= 0.5 {
            lastReportedTime = seconds
            onEvent?(.time(seconds))
        }
        if !appliedPreferences || audioIds.isEmpty { reportTracks(force: false) }
    }

    private func reportReadyIfNeeded() {
        let lengthMs = player.media?.length.value?.doubleValue ?? 0
        guard !reportedReady || (lengthMs > 0 && !isLive && lastReportedLength != lengthMs) else { return }
        reportedReady = true
        lastReportedLength = lengthMs
        onEvent?(.ready(duration: isLive ? 0 : lengthMs / 1000))
    }

    private var lastReportedLength: Double = -1

    private func classifyFailure(ended: Bool) {
        guard let stream else { return }
        let hadPlayed = hadPlayed
        let isLive = isLive
        let lengthMs = player.media?.length.value?.doubleValue ?? 0
        let timeMs = player.time.value?.doubleValue ?? 0
        let remaining: Double? = lengthMs > 0 ? max(0, lengthMs - timeMs) / 1000 : nil
        if ended, !isLive, hadPlayed, (remaining ?? 0) < 30 {
            onEvent?(.ended)
            return
        }
        failureTask?.cancel()
        failureTask = Task { [weak self] in
            let probe = await VLCFailureClassifier.probe(stream.url, headers: stream.headers)
            guard !Task.isCancelled, let self, self.stream == stream else { return }
            if let error = VLCFailureClassifier.classify(probe: probe, hadPlayed: hadPlayed, ended: ended, isLive: isLive, remainingSeconds: remaining) {
                SafeLog.warning("vlc \(ended ? "ended" : "error") → \(error)")
                self.onEvent?(.failed(error))
            } else {
                self.onEvent?(.ended)
            }
        }
    }

    // MARK: Tracks

    private func reportTracks(force: Bool) {
        let languages = trackLanguages()
        let audio = Self.tracks(ids: player.audioTrackIndexes, names: player.audioTrackNames, languages: languages)
        let subtitles = Self.tracks(ids: player.videoSubTitlesIndexes, names: player.videoSubTitlesNames, languages: languages)
        audioIds = audio.map(\.0)
        subtitleIds = subtitles.map(\.0)

        if !appliedPreferences, !audio.isEmpty {
            appliedPreferences = true
            if let index = audio.firstIndex(where: { TrackNaming.matches($0.1.languageCode, preferred: preferredAudio) }),
               player.currentAudioTrackIndex != audio[index].0 {
                player.currentAudioTrackIndex = audio[index].0
            }
            if let index = subtitles.firstIndex(where: { TrackNaming.matches($0.1.languageCode, preferred: preferredSubtitle) }) {
                player.currentVideoSubTitleIndex = subtitles[index].0
            }
        }
        let selectedAudio = audio.firstIndex { $0.0 == player.currentAudioTrackIndex }
        let selectedSubtitle = subtitles.firstIndex { $0.0 == player.currentVideoSubTitleIndex }
        let signature = "\(audioIds)|\(subtitleIds)|\(selectedAudio ?? -1)|\(selectedSubtitle ?? -1)"
        guard force || signature != lastTracksSignature else { return }
        lastTracksSignature = signature
        onEvent?(.tracks(audio: audio.map(\.1), subtitles: subtitles.map(\.1),
                         selectedAudio: selectedAudio, selectedSubtitle: selectedSubtitle))
    }

    /// libVLC track id → ISO language code from `media.tracksInformation`.
    private func trackLanguages() -> [Int32: String] {
        var result: [Int32: String] = [:]
        for case let info as [String: Any] in player.media?.tracksInformation ?? [] {
            guard let id = (info[VLCMediaTracksInformationId] as? NSNumber)?.int32Value,
                  let language = info[VLCMediaTracksInformationLanguage] as? String, !language.isEmpty else { continue }
            result[id] = language
        }
        return result
    }

    /// Pairs libVLC ids with names, skipping the "Disable" entry (id -1). Option ids are the
    /// positions in the returned list.
    private static func tracks(ids: [Any], names: [Any], languages: [Int32: String]) -> [(Int32, MediaOption)] {
        var result: [(Int32, MediaOption)] = []
        for (i, raw) in ids.enumerated() {
            guard let id = (raw as? NSNumber)?.int32Value, id >= 0 else { continue }
            let language = languages[id] ?? languageInName(names.indices.contains(i) ? names[i] as? String : nil)
            let option = MediaOption(id: result.count, name: TrackNaming.displayName(forLanguage: language), languageCode: language)
            result.append((id, option))
        }
        return result
    }

    /// "Track 1 - [English]" → "English" (libVLC puts the language in brackets).
    private static func languageInName(_ name: String?) -> String? {
        guard let name, let open = name.lastIndex(of: "["), let close = name.lastIndex(of: "]"), open < close else { return nil }
        let inner = name[name.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
        return inner.isEmpty ? nil : inner
    }
}

extension VLCPlaybackEngine: VLCMediaPlayerDelegate {
    nonisolated func mediaPlayerStateChanged(_ aNotification: Notification) {
        Self.onMain(self) { $0.stateChanged() }
    }

    nonisolated func mediaPlayerTimeChanged(_ aNotification: Notification) {
        Self.onMain(self) { $0.timeChanged() }
    }

    /// libVLC posts delegate callbacks on the main thread; hop if it ever does not.
    nonisolated private static func onMain(_ engine: VLCPlaybackEngine, _ body: @escaping @MainActor (VLCPlaybackEngine) -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { body(engine) }
        } else {
            let box = UncheckedBox(engine)
            DispatchQueue.main.async { MainActor.assumeIsolated { body(box.value) } }
        }
    }
}

private struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// UIView handed to libVLC as `drawable`; reports size changes for the aspect modes.
final class VLCDrawableView: UIView {
    var onLayout: ((CGSize) -> Void)?
    private var lastSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != lastSize else { return }
        lastSize = bounds.size
        onLayout?(bounds.size)
    }
}

extension PlaybackEngines {
    /// AVPlayer + VLCKit (the iOS/tvOS apps).
    @MainActor static var app: PlaybackEngines {
        PlaybackEngines(avPlayer: { AVPlayerEngine() }, vlc: { VLCPlaybackEngine() })
    }
}
#else
extension PlaybackEngines {
    /// Build without VLCKit: AVPlayer only.
    @MainActor static var app: PlaybackEngines { .avPlayerOnly }
}
#endif

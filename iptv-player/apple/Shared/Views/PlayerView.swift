import AVFoundation
import IPTVCore
import IPTVKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Full-screen player with overlay (SCREENS §3.7).
///
/// The overlay is inserted/removed (not faded with `.opacity`/`.allowsHitTesting`): on iOS 26 a
/// subtree whose hit testing was switched off and on again kept its Buttons dead – taps fell
/// through to the views behind (TestFlight build 5: no working controls after the 3 s auto-hide).
struct PlayerView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    @State private var overlayVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var channelListVisible = false
    /// "Play from start" chip after an automatic resume (5 s, independent of the overlay).
    @State private var resumeChipVisible = false
    @State private var resumeChipTask: Task<Void, Never>?
    #if os(iOS)
    /// Scrubber position while the finger is down (nil = follow playback).
    @State private var scrubFraction: Double?
    /// An audio/subtitle/aspect menu is open: removing its source view would close it.
    @State private var menuOpen = false
    @State private var ripple: SeekRipple?
    @State private var rippleTask: Task<Void, Never>?
    #endif
    #if os(tvOS)
    @FocusState private var surfaceFocused: Bool
    @FocusState private var playPauseFocused: Bool
    @FocusState private var closeFocused: Bool
    /// VOD: the top row (close + tools) takes focus only after ▲ from play/pause, so ◀▶ on the
    /// transport row seeks instead of moving the focus sideways into the tools.
    @State private var toolsActive = false
    #endif

    private var player: PlayerController { env.player }
    private var isVOD: Bool { player.request.map { !$0.isLive } ?? false }
    /// The play/pause control shows "play" (paused by the user or finished).
    private var showsPlayIcon: Bool { player.phase == .paused || player.phase == .ended || player.phase == .idle }
    private static let autoHideSeconds = 3

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            video
            if case .failed(let error) = player.phase {
                errorCard(error)
            } else if case .locked = player.phase {
                ErrorCardView(presentation: ErrorPresentation(titleKey: "trial_expired", bodyKey: "player_locked", actions: [.back])) { _ in
                    router.closePlayer()
                    router.paywallPresented = true
                }
            } else {
                // The overlay's play button carries the spinner while it is shown.
                if !overlayVisible { statusLayer }
                #if os(iOS)
                if let ripple { rippleLabel(ripple) }
                #endif
                if overlayVisible { overlay.transition(.opacity) }
                if resumeChipVisible, isVOD { resumeChip }
            }
            if env.settings.showPerfOverlay {
                PerfOverlayView(player: player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(Theme.isTV ? 48 : 16)
            }
            if let target = player.zapTarget { zapCard(target) }
            if channelListVisible { channelList }
        }
        .animation(.easeInOut(duration: 0.18), value: overlayVisible)
        .animation(.easeInOut(duration: 0.2), value: resumeChipVisible)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            showOverlay()
            if player.resumedFromMs != nil { showResumeChip() }
        }
        .onDisappear {
            hideTask?.cancel()
            resumeChipTask?.cancel()
        }
        .onChange(of: player.phase) { _, phase in
            // Never hide while paused/buffering; once playing (again) the 3 s count starts.
            if overlayVisible, phase == .playing { scheduleHide() }
        }
        .onChange(of: player.resumedFromMs) { _, ms in
            if ms != nil { showResumeChip() } else { resumeChipVisible = false }
        }
        #if os(iOS)
        .statusBarHidden()
        .gesture(DragGesture(minimumDistance: 40).onEnded { value in
            guard player.request?.isLive == true, abs(value.translation.height) > abs(value.translation.width) else { return }
            player.zap(by: value.translation.height < 0 ? 1 : -1)
        })
        #endif
        #if os(tvOS)
        .background(TVHoldSeek { direction, heldMs in
            if isVOD, !channelListVisible, !(overlayVisible && toolsActive) { tvSeek(direction, heldMs: heldMs) }
        })
        .focusable(!overlayVisible && !channelListVisible)
        .focused($surfaceFocused)
        .onMoveCommand { direction in
            if isVOD, overlayVisible, !channelListVisible {
                vodOverlayMove(direction)
                return
            }
            switch direction {
            case .up: player.request?.isLive == true ? player.zap(by: -1) : showOverlay()
            case .down: player.request?.isLive == true ? player.zap(by: 1) : showOverlay()
            case .left: tvSeek(-1)
            case .right: tvSeek(1)
            @unknown default: break
            }
        }
        .onPlayPauseCommand { togglePlayPause() }
        // Select on the picture (overlay hidden): VOD pauses/resumes like the TV app; live shows the info.
        .onTapGesture {
            if isVOD { togglePlayPause() } else { showOverlay() }
        }
        .onExitCommand {
            // Back rules (SCREENS §2): close panel/menu first, then leave the player.
            if channelListVisible { channelListVisible = false }
            else if overlayVisible { hideOverlay() }
            else { router.closePlayer() }
        }
        #endif
    }

    private var video: some View {
        GeometryReader { geo in
            let ratio = player.aspect.fixedRatio
            let size: CGSize = {
                guard let ratio else { return geo.size }
                let w = min(geo.size.width, geo.size.height * ratio)
                return CGSize(width: w, height: w / ratio)
            }()
            ZStack {
                // AVPlayer layer or VLCKit drawable, whichever engine plays this stream.
                EngineVideoSurface(engine: player.engine, aspect: player.aspect)
                    .frame(width: size.width, height: size.height)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                #if os(iOS)
                // The one owner of taps on the picture (the overlay's empty areas pass through):
                // single tap toggles the overlay, double tap on the left/right third seeks ∓/±10 s.
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        SpatialTapGesture(count: 2)
                            .onEnded { value in doubleTap(at: value.location.x, width: geo.size.width) }
                            .exclusively(before: TapGesture(count: 1).onEnded { overlayVisible ? hideOverlay() : showOverlay() })
                    )
                #endif
            }
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("video_surface")
    }

    @ViewBuilder
    private var statusLayer: some View {
        switch player.phase {
        case .loading, .buffering:
            ProgressView().controlSize(.large).tint(.white)
        case .reconnecting(let attempt, let max):
            reconnectingCard(attempt, max)
        default:
            EmptyView()
        }
    }

    private func reconnectingCard(_ attempt: Int, _ max: Int) -> some View {
        VStack(spacing: 10) {
            ProgressView().tint(.white)
            LText("player_reconnecting", String(attempt), String(max)).font(Theme.body).foregroundStyle(.white)
        }
        .padding(20).background(RoundedRectangle(cornerRadius: 12).fill(.black.opacity(0.6)))
    }

    private func errorCard(_ error: PlaybackError) -> some View {
        ErrorCardView(presentation: error.presentation) { action in
            switch action {
            case .retry: player.retry()
            case .channelList: channelListVisible = true
            default: router.closePlayer()
            }
        }
        .padding(Theme.safeH)
    }

    // MARK: Overlay visibility

    private func showOverlay() {
        overlayVisible = true
        scheduleHide()
    }

    private func hideOverlay() {
        hideTask?.cancel()
        overlayVisible = false
        #if os(iOS)
        menuOpen = false   // a menu dismissed without a choice
        #else
        toolsActive = false
        surfaceFocused = true
        #endif
    }

    /// (Re)starts the 3 s auto-hide; it only hides while playing and nothing is being used.
    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(Self.autoHideSeconds))
            guard !Task.isCancelled, canAutoHide else { return }
            hideOverlay()
        }
    }

    private var canAutoHide: Bool {
        guard player.phase == .playing, !channelListVisible else { return false }
        #if os(iOS)
        if scrubFraction != nil || menuOpen { return false }
        #endif
        return true
    }

    private func showResumeChip() {
        resumeChipVisible = true
        resumeChipTask?.cancel()
        resumeChipTask = Task {
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { resumeChipVisible = false }
        }
    }

    // MARK: Transport

    private func togglePlayPause() {
        player.togglePlayPause()
        showOverlay()
    }

    private func seek(by seconds: Double) {
        player.seek(by: seconds)
        if overlayVisible { scheduleHide() }
    }

    #if os(tvOS)
    /// VOD overlay shown: transport row (play/pause) ◀▶ seeks, ▲ moves to the top row; in the
    /// top row ◀▶ navigate the tools and ▼ returns to play/pause.
    private func vodOverlayMove(_ direction: MoveCommandDirection) {
        switch direction {
        case .up where !toolsActive:
            toolsActive = true
            Task { @MainActor in closeFocused = true }   // after the row became focusable
            scheduleHide()
        case .down where toolsActive:
            toolsActive = false
            playPauseFocused = true
            scheduleHide()
        case .left where !toolsActive: tvSeek(-1)
        case .right where !toolsActive: tvSeek(1)
        default: scheduleHide()
        }
    }

    /// ◀▶: 10 s; held (`TVHoldSeek` repeats every 0.3 s) 30 s steps once held for 1 s.
    private func tvSeek(_ direction: Int, heldMs: Int64 = 0) {
        guard isVOD else { showOverlay(); return }
        player.seek(by: SeekAccelerator.step(direction: direction, heldMs: heldMs))
        showOverlay()
    }
    #endif

    #if os(iOS)
    private func doubleTap(at x: CGFloat, width: CGFloat) {
        guard isVOD, width > 0 else {
            overlayVisible ? hideOverlay() : showOverlay()
            return
        }
        let third = width / 3
        guard x < third || x > width - third else {
            overlayVisible ? hideOverlay() : showOverlay()
            return
        }
        let forward = x > width - third
        seek(by: forward ? 10 : -10)
        // Consecutive double taps on the same side add up ("+20 s").
        let previous = ripple.flatMap { $0.forward == forward ? $0.seconds : nil } ?? 0
        ripple = SeekRipple(forward: forward, seconds: previous + 10, id: UUID())
        rippleTask?.cancel()
        rippleTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            if !Task.isCancelled { ripple = nil }
        }
    }

    private func rippleLabel(_ ripple: SeekRipple) -> some View {
        let text = L10n.t("player_seek_delta", (ripple.forward ? "+" : "−") + String(ripple.seconds))
        return HStack {
            if ripple.forward { Spacer() }
            VStack(spacing: 6) {
                Image(systemName: ripple.forward ? "goforward" : "gobackward").font(.system(size: 28, weight: .semibold))
                Text(verbatim: text).font(.headline.monospacedDigit())
            }
            .foregroundStyle(.white)
            .frame(width: 120, height: 120)
            .background(Circle().fill(.black.opacity(0.5)))
            .overlay(Circle().stroke(.white.opacity(0.2), lineWidth: 1))
            .padding(.horizontal, 36)
            // Above the transport row while the overlay is shown, centred on the side otherwise.
            .offset(y: overlayVisible ? -130 : 0)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("player_seek_ripple")
            if !ripple.forward { Spacer() }
        }
        .id(ripple.id)
        .transition(.opacity)
        .allowsHitTesting(false)
    }
    #endif

    // MARK: Overlay

    private var overlay: some View {
        ZStack {
            // Purely visual: taps on empty areas reach the picture's gestures underneath.
            LinearGradient(colors: [.black.opacity(0.7), .clear, .clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            VStack {
                topBar
                Spacer()
                bottomBar
            }
            .padding(.horizontal, Theme.safeH)
            .padding(.vertical, Theme.safeV)
            transportRow
        }
        #if os(tvOS)
        .focusSection()
        .defaultFocus($playPauseFocused, true)
        #endif
    }

    private var topBar: some View {
        HStack(alignment: .top, spacing: 16) {
            Button { router.closePlayer() } label: {
                Image(systemName: "xmark")
                    #if os(iOS)
                    .frame(minWidth: 20, minHeight: 24)
                    #endif
            }
            .buttonStyle(SecondaryButtonStyle())
            .accessibilityLabel(L10n.t("action_close"))
            .accessibilityIdentifier("player_close")
            #if os(tvOS)
            .focused($closeFocused)
            #endif
            if let number = player.currentChannel?.number {
                Text(String(number)).font(Theme.headline.monospacedDigit()).foregroundStyle(Theme.textSecondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(player.request?.title ?? "").font(Theme.headline).foregroundStyle(.white).lineLimit(1)
                if let channel = player.currentChannel, let now = nowProgramme(channel) {
                    Text(now.title).font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
            }
            Spacer()
            tools
        }
        #if os(tvOS)
        // VOD: not focusable until ▲ from play/pause (◀▶ there seeks); entering the row lands on close.
        .disabled(isVOD && !toolsActive)
        .focusSection()
        .defaultFocus($closeFocused, true, priority: .userInitiated)
        #endif
    }

    /// Centered transport: VOD ⟲10 · play/pause · 10⟳ (iOS), live/tvOS play/pause only
    /// (tvOS seeks with ◀▶ on the remote).
    private var transportRow: some View {
        HStack(spacing: Theme.isTV ? 0 : 44) {
            #if os(iOS)
            if isVOD {
                transportButton("gobackward.10", size: 56, label: "player_seek_back_10", id: "player_seek_back") { seek(by: -10) }
            }
            #endif
            playPauseButton
            #if os(iOS)
            if isVOD {
                transportButton("goforward.10", size: 56, label: "player_seek_forward_10", id: "player_seek_forward") { seek(by: 10) }
            }
            #endif
        }
    }

    private var playPauseButton: some View {
        let size: CGFloat = Theme.isTV ? 110 : 64
        let busy = player.phase == .loading || player.phase == .buffering
        return Button { togglePlayPause() } label: {
            ZStack {
                if busy {
                    ProgressView().tint(.white).controlSize(Theme.isTV ? .large : .regular)
                } else {
                    Image(systemName: showsPlayIcon ? "play.fill" : "pause.fill")
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .offset(x: showsPlayIcon ? size * 0.04 : 0)   // optical centre of the triangle
                }
            }
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(.black.opacity(0.6)))
            .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1))
            .contentShape(Circle())
        }
        .buttonStyle(CardButtonStyle(radius: size / 2, scale: 1.1))
        .accessibilityLabel(L10n.t(showsPlayIcon ? "player_play" : "player_pause"))
        .accessibilityValue(showsPlayIcon ? "paused" : "playing")
        .accessibilityIdentifier("player_play_pause")
        #if os(tvOS)
        .focused($playPauseFocused)
        // The surface gives up focus when the overlay appears: play/pause takes it (OK = pause).
        .onAppear { playPauseFocused = true }
        #endif
    }

    #if os(iOS)
    private func transportButton(_ symbol: String, size: CGFloat, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Circle().fill(.black.opacity(0.55)))
                .overlay(Circle().stroke(.white.opacity(0.2), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleButtonStyle())
        .accessibilityLabel(L10n.t(label))
        .accessibilityIdentifier(id)
    }
    #endif

    private var resumeChip: some View {
        VStack {
            Spacer()
            HStack {
                Button {
                    resumeChipVisible = false
                    player.restartFromBeginning()
                    showOverlay()
                } label: {
                    Label(L10n.t("action_play_from_start"), systemImage: "backward.end.fill")
                }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityIdentifier("player_play_from_start")
                Spacer()
            }
            .padding(.horizontal, Theme.safeH)
            // Above the bottom bar (timeline) when the overlay is shown.
            .padding(.bottom, Theme.safeV + (Theme.isTV ? 140 : 84))
        }
        .transition(.opacity)
    }

    private func nowProgramme(_ channel: Channel) -> EpgProgram? {
        guard let epgId = channel.epgId else { return nil }
        return (try? env.epg.nowNext(sourceId: channel.sourceId, epgIds: [epgId], at: Date()))?[epgId.lowercased()]?.now
    }

    private var tools: some View {
        HStack(spacing: Theme.isTV ? 24 : 18) {
            if !player.audioOptions.isEmpty {
                trackedMenu("speaker.wave.2", label: "player_audio") {
                    ForEach(player.audioOptions) { option in
                        Button { player.selectAudio(option.id); menuClosed() } label: {
                            Label(option.name ?? L10n.t("unknown_track", String(option.id + 1)), systemImage: player.selectedAudio == option.id ? "checkmark" : "")
                        }
                    }
                }
            }
            if !player.subtitleOptions.isEmpty {
                trackedMenu("captions.bubble", label: "player_subtitles") {
                    Button { player.selectSubtitle(nil); menuClosed() } label: { Label(L10n.t("off"), systemImage: player.selectedSubtitle == nil ? "checkmark" : "") }
                    ForEach(player.subtitleOptions) { option in
                        Button { player.selectSubtitle(option.id); menuClosed() } label: {
                            Label(option.name ?? L10n.t("unknown_track", String(option.id + 1)), systemImage: player.selectedSubtitle == option.id ? "checkmark" : "")
                        }
                    }
                }
            }
            trackedMenu("aspectratio", label: "player_aspect") {
                ForEach(AspectMode.allCases, id: \.self) { mode in
                    Button { env.player.aspect = mode; menuClosed() } label: { Label(L10n.t(mode.titleKey), systemImage: player.aspect == mode ? "checkmark" : "") }
                }
            }
            if player.request?.isLive == true {
                Button { channelListVisible = true } label: { toolIcon("list.bullet") }
                    .accessibilityLabel(L10n.t("action_channel_list"))
                if player.previousChannel != nil {
                    Button { player.switchToPreviousChannel() } label: { toolIcon("arrow.uturn.backward") }
                        .accessibilityLabel(L10n.t("player_previous_channel"))
                }
            }
            if let request = player.request, let channel = player.currentChannel {
                let fav = env.isFavorite(sourceId: channel.sourceId, kind: .live, itemId: channel.id)
                Button {
                    env.toggleFavorite(sourceId: channel.sourceId, kind: .live, itemId: channel.id, title: request.title, posterUrl: channel.logoUrl)
                } label: { toolIcon(fav ? "star.fill" : "star") }
                .accessibilityLabel(L10n.t(fav ? "action_remove_favorite" : "action_add_favorite"))
            }
        }
        .font(Theme.headline)
        .foregroundStyle(.white)
        .buttonStyle(.borderless)
    }

    /// Audio/subtitle/aspect menu. Its items appear while the menu is open: the overlay must not
    /// auto-hide then (removing the menu's source view would close it).
    private func trackedMenu<Items: View>(_ symbol: String, label: String, @ViewBuilder items: () -> Items) -> some View {
        Menu {
            items()
                #if os(iOS)
                .onAppear {
                    menuOpen = true
                    hideTask?.cancel()
                }
                .onDisappear {
                    menuOpen = false
                    if overlayVisible { scheduleHide() }
                }
                #endif
        } label: { toolIcon(symbol) }
        .accessibilityLabel(L10n.t(label))
    }

    /// Tool glyph with a ≥ 36 pt touch target on iOS.
    private func toolIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            #if os(iOS)
            .frame(minWidth: 36, minHeight: 36)
            .contentShape(Rectangle())
            #endif
    }

    /// A menu item was chosen: the menu is gone, the overlay's 3 s count restarts.
    private func menuClosed() {
        #if os(iOS)
        menuOpen = false
        #endif
        showOverlay()
    }

    @ViewBuilder
    private var bottomBar: some View {
        if player.request?.isLive == true {
            HStack(spacing: 16) {
                LiveBadge()
                if let channel = player.currentChannel, let now = nowProgramme(channel) {
                    ProgressBar(value: EpgSchedule.progress(of: now, at: Date()), color: Theme.live).frame(height: 5)
                    Text(env.timeFormatter.range(start: now.start, end: now.end)).font(Theme.caption.monospacedDigit()).foregroundStyle(.white)
                } else {
                    Spacer()
                }
            }
        } else {
            vodTimeline
        }
    }

    /// VOD timeline: iOS draggable scrubber, tvOS display bar (◀▶ seek).
    private var vodTimeline: some View {
        let duration = player.duration
        #if os(iOS)
        let shownTime = scrubFraction.map { $0 * duration } ?? player.currentTime
        #else
        let shownTime = player.currentTime
        #endif
        let fraction = duration > 0 ? min(1, max(0, player.currentTime / duration)) : 0
        return VStack(spacing: Theme.isTV ? 12 : 0) {
            #if os(iOS)
            PlayerScrubber(fraction: fraction, duration: duration, dragFraction: scrubBinding) { target in
                player.seek(toFraction: target)
            }
            #else
            ProgressBar(value: fraction).frame(height: 8)
            #endif
            HStack {
                Text(L10n.clock(shownTime))
                    .accessibilityIdentifier("player_time")
                Spacer()
                Text(duration > 0 ? L10n.clock(duration) : "--:--")
                    .accessibilityIdentifier("player_duration")
            }
            .font(Theme.caption.monospacedDigit())
            .foregroundStyle(.white)
        }
    }

    #if os(iOS)
    private var scrubBinding: Binding<Double?> {
        Binding(get: { scrubFraction }, set: { value in
            let ended = scrubFraction != nil && value == nil
            scrubFraction = value
            if value != nil { hideTask?.cancel() }
            if ended { scheduleHide() }
        })
    }
    #endif

    private func zapCard(_ channel: Channel) -> some View {
        VStack {
            HStack(spacing: 16) {
                if let n = channel.number { Text(String(n)).font(Theme.title.monospacedDigit()) }
                ChannelLogo(url: channel.logoUrl)
                VStack(alignment: .leading) {
                    Text(channel.name).font(Theme.headline)
                    if let now = nowProgramme(channel) { Text(now.title).font(Theme.caption).foregroundStyle(Theme.textSecondary) }
                }
                if player.phase == .loading { ProgressView() }
            }
            .foregroundStyle(.white)
            .padding(Theme.isTV ? 28 : 16)
            .background(RoundedRectangle(cornerRadius: Theme.cardRadius).fill(Theme.surfaceElevated.opacity(0.95)))
            Spacer()
        }
        .padding(.top, Theme.safeV + 20)
    }

    private var channelList: some View {
        HStack {
            Spacer()
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(player.request?.channels ?? []) { channel in
                        Button {
                            player.zap(to: channel)
                            channelListVisible = false
                        } label: {
                            HStack {
                                Text(channel.number.map(String.init) ?? "").frame(width: 50, alignment: .trailing)
                                ChannelLogo(url: channel.logoUrl, width: Theme.isTV ? 90 : 48)
                                Text(channel.name).lineLimit(1)
                                Spacer()
                            }
                            .font(Theme.caption)
                            .foregroundStyle(channel.id == player.currentChannel?.id ? Theme.primary : .white)
                            .padding(8)
                        }
                        .buttonStyle(CardButtonStyle())
                    }
                }
                .padding()
            }
            .frame(width: Theme.isTV ? 640 : 300)
            .background(Theme.surface.opacity(0.95))
            #if os(tvOS)
            .focusSection()
            #endif
        }
        .ignoresSafeArea()
        #if os(iOS)
        .onTapGesture { channelListVisible = false }
        #endif
    }
}

#if os(iOS)
/// Double-tap seek feedback ("−10 s" / "+20 s").
private struct SeekRipple: Equatable {
    var forward: Bool
    var seconds: Int
    var id: UUID
}

/// Transport glyph button: scales down while pressed (no platter).
private struct PressScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Draggable VOD timeline (44 pt touch height). While the finger is down `dragFraction` holds the
/// target – incoming time ticks do not move the thumb – and the seek happens on release.
private struct PlayerScrubber: View {
    let fraction: Double
    let duration: Double
    @Binding var dragFraction: Double?
    let onCommit: (Double) -> Void

    private var enabled: Bool { duration > 0 }

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let dragging = dragFraction != nil
            let shown = dragFraction ?? fraction
            let thumb: CGFloat = dragging ? 24 : 16
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.3)).frame(height: dragging ? 8 : 5)
                Capsule().fill(Theme.primary).frame(width: width * shown, height: dragging ? 8 : 5)
                if enabled {
                    Circle().fill(.white)
                        .frame(width: thumb, height: thumb)
                        .shadow(color: .black.opacity(0.4), radius: 3)
                        .offset(x: width * shown - thumb / 2)
                }
                if let dragFraction {
                    Text(L10n.clock(dragFraction * duration))
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(.white))
                        .fixedSize()
                        .offset(x: min(max(0, width * dragFraction - 36), width - 72), y: -34)
                }
            }
            .frame(width: width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(drag(width: width), including: enabled ? .all : .subviews)
            .animation(.easeOut(duration: 0.12), value: dragging)
        }
        .frame(height: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.t("player_position"))
        .accessibilityValue(L10n.clock((dragFraction ?? fraction) * duration))
        .accessibilityAdjustableAction { direction in
            guard enabled else { return }
            let step = 10 / duration
            onCommit(min(1, max(0, fraction + (direction == .increment ? step : -step))))
        }
        .accessibilityIdentifier("player_scrubber")
    }

    private func drag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in dragFraction = min(1, max(0, value.location.x / width)) }
            .onEnded { value in
                let target = min(1, max(0, value.location.x / width))
                onCommit(target)
                dragFraction = nil
            }
    }
}
#endif

#if os(tvOS)
/// Press-and-hold ◀▶ on the Siri Remote: SwiftUI's `onMoveCommand` fires once per press (no
/// repeat while held), so long-press recognizers for the arrow presses on the window repeat the
/// step every 0.3 s while the button stays down (10 s, 30 s once held for 1 s). A short press
/// fails them and reaches `onMoveCommand` as usual.
private struct TVHoldSeek: UIViewRepresentable {
    /// (direction, ms since the button went down)
    let onStep: @MainActor (Int, Int64) -> Void

    func makeUIView(context: Context) -> HoldView {
        let view = HoldView()
        view.onStep = onStep
        return view
    }

    func updateUIView(_ view: HoldView, context: Context) { view.onStep = onStep }

    static func dismantleUIView(_ view: HoldView, coordinator: ()) { view.detach() }

    final class HoldView: UIView {
        var onStep: (@MainActor (Int, Int64) -> Void)?
        private static let minimumPress: TimeInterval = 0.4
        private var recognizers: [UILongPressGestureRecognizer] = []
        private var repeatTask: Task<Void, Never>?
        private weak var attachedWindow: UIWindow?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { detach() } else { attach() }
        }

        private func attach() {
            guard let window, attachedWindow !== window else { return }
            detach()
            for type in [UIPress.PressType.leftArrow, .rightArrow] {
                let r = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
                r.allowedPressTypes = [NSNumber(value: type.rawValue)]
                r.minimumPressDuration = Self.minimumPress
                window.addGestureRecognizer(r)
                recognizers.append(r)
            }
            attachedWindow = window
        }

        func detach() {
            repeatTask?.cancel()
            for r in recognizers { r.view?.removeGestureRecognizer(r) }
            recognizers.removeAll()
            attachedWindow = nil
        }

        @objc private func held(_ recognizer: UILongPressGestureRecognizer) {
            let direction = recognizer.allowedPressTypes.first?.intValue == UIPress.PressType.leftArrow.rawValue ? -1 : 1
            switch recognizer.state {
            case .began:
                repeatTask?.cancel()
                let pressedAt = Date().addingTimeInterval(-Self.minimumPress)
                repeatTask = Task { @MainActor [weak self] in
                    while !Task.isCancelled {
                        self?.onStep?(direction, Int64(Date().timeIntervalSince(pressedAt) * 1000))
                        try? await Task.sleep(for: .milliseconds(300))
                    }
                }
            case .ended, .cancelled, .failed:
                repeatTask?.cancel()
            default:
                break
            }
        }
    }
}
#endif

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
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @State private var overlayVisible = true
    @State private var hideTask: Task<Void, Never>?
    /// In-player channel panel (category picker, favorites first; SCREENS §3.7).
    @State private var channelListVisible = false
    /// "Play from start" chip after an automatic resume (5 s, independent of the overlay).
    @State private var resumeChipVisible = false
    @State private var resumeChipTask: Task<Void, Never>?
    /// Audio → Sync panel (SCREENS §3.7): non-modal, at the bottom, the picture stays visible.
    @State private var syncPanelVisible = false
    /// "Sync can't be applied to this stream" (VLCKit failed, AVPlayer without the delay) – 4 s.
    @State private var syncNoticeVisible = false
    @State private var syncNoticeTask: Task<Void, Never>?
    /// Sync panel → "Calibrate audio sync" (Build 16) over the player.
    @State private var calibrationPresented = false
    /// An audio/subtitle/aspect menu is open: removing its source view would close it.
    @State private var menuOpen = false
    /// Seek bubble thumbnails (only where a second connection is safe – `SeekThumbnailPolicy`).
    @State private var thumbnails = SeekThumbnailLoader()
    /// Width of the VOD timeline (places the seek bubble above the target).
    @State private var timelineWidth: CGFloat = 0
    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// Scrubber position while the finger is down (nil = follow playback).
    @State private var scrubFraction: Double?
    @State private var ripple: SeekRipple?
    @State private var rippleTask: Task<Void, Never>?
    /// Position when the current scrub began (the bubble's "+2:30" is measured from it).
    @State private var scrubOrigin: Double?
    /// After release the bubble stays a moment on the landing point (`landingSeconds`).
    @State private var landing: SeekLanding?
    @State private var landingTask: Task<Void, Never>?
    #endif
    #if os(tvOS)
    @FocusState private var surfaceFocused: Bool
    @FocusState private var playPauseFocused: Bool
    /// Top row (close + tools). The root `onMoveCommand` swallows every move the focused control does
    /// not handle, so ◀▶ walk the row explicitly (`topRowMove`) and ▼ returns to play/pause.
    enum TopItem: Hashable { case close, audio, subtitles, aspect, resync, sleep, favorite, channelList, previous }
    @FocusState private var topFocus: TopItem?
    /// VOD: the top row (close + tools) takes focus only after ▲ from play/pause, so ◀▶ on the
    /// transport row seeks instead of moving the focus sideways into the tools.
    @State private var toolsActive = false
    /// Live: ▲ shows the channel info card (logo, name, now/next) with ⭐ focused (spec §2).
    @State private var infoCardVisible = false
    @State private var infoCardTask: Task<Void, Never>?
    @FocusState private var infoFavoriteFocused: Bool
    /// Undo button of the toast (below the info card: ▼ from ⭐ reaches it, no zap while offered).
    @FocusState private var undoFocused: Bool
    /// Now/next of the info card's channel (loaded per channel, not per render).
    @State private var infoNowNext: NowNext?
    /// Number zapping with digit keys (IR remote / keyboard): digits shown top right, tuned 1.5 s
    /// after the last one.
    @State private var numberZap = NumberZap()
    @State private var zapDigits = ""
    /// "No such channel" in the number indicator (numbered source without that number).
    @State private var zapNoChannel = false
    @State private var numberZapTask: Task<Void, Never>?
    /// Preview-then-commit seeking (VOD): ◀▶ / hold / touch-surface swipes move this target while
    /// playback continues; one seek on OK, Play/Pause or 0.8 s without input; Menu cancels.
    @State private var seekPreview: SeekPreview?
    @State private var seekCommitTask: Task<Void, Never>?
    /// When the last touch-surface swipe ended (a move command right after it is the same gesture).
    @State private var lastPanEndMs: Int64 = 0
    /// Next-episode card buttons (Build 16): "Play now" focused, ◀▶ between them, Menu cancels.
    @FocusState private var upNextPlayFocused: Bool
    @FocusState private var upNextCancelFocused: Bool
    #endif
    /// "Sleep timer: playback stopped" (4 s) after the sleep timer fired.
    @State private var sleepNoticeVisible = false
    @State private var sleepNoticeTask: Task<Void, Never>?

    private var player: PlayerController { env.player }
    private var isVOD: Bool { player.request.map { !$0.isLive } ?? false }
    /// The play/pause control shows "play" (paused by the user or finished).
    private var showsPlayIcon: Bool { player.phase == .paused || player.phase == .ended || player.phase == .idle }
    private static let autoHideSeconds = 3
    /// Per request, not per render: the series of an episode (⭐).
    @State private var episodeSeries: Series?

    /// Undo toast sits above the bottom bar; tvOS with the info card: below the card, at the right
    /// under ⭐, so ▼ moves the focus to "Undo".
    private var toastLift: CGFloat {
        #if os(tvOS)
        infoCardVisible ? 0 : 150
        #else
        96
        #endif
    }

    var body: some View {
        build16Handlers(layers)
            .guideParentalOverlays(inPlayer: true)   // Build 18: reminder banner + PIN pad over the video
    }

    private var mainLayers: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            video
            // Below the controls: an accessibility element above them (its label changes every second)
            // kept the player's Menus from opening under accessibility / XCUITest.
            if env.settings.showPerfOverlay {
                PerfOverlayView(player: player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(Theme.isTV ? 48 : 16)
            }
            if case .failed(let error) = player.phase {
                errorCard(error)
            } else if case .locked = player.phase {
                ErrorCardView(presentation: ErrorPresentation(titleKey: "trial_expired", bodyKey: "player_locked", actions: [.back])) { _ in
                    router.closePlayer()
                    router.paywallPresented = true
                }
            } else {
                // The overlay's play button carries the spinner while it is shown; the reconnect
                // status is always visible (above the transport row when the overlay is shown).
                if !overlayVisible { statusLayer }
                if case .reconnecting(let attempt, let max) = player.phase {
                    reconnectingCard(attempt, max).offset(y: overlayVisible ? reconnectLift : 0)
                }
                #if os(iOS)
                if let ripple { rippleLabel(ripple) }
                #endif
                if overlayVisible { overlay.transition(.opacity) }
                if resumeChipVisible, isVOD { resumeChip }
            }
            if let target = player.zapTarget { zapCard(target) }
            #if os(tvOS)
            if infoCardVisible, let channel = player.currentChannel { infoCard(channel) }
            if !zapDigits.isEmpty || zapNoChannel { numberIndicator }
            #endif
            if channelListVisible {
                PlayerChannelPanel(player: player) { closeChannelPanel() }
            }
            if syncPanelVisible {
                AudioSyncPanel(player: player, onClose: { closeSyncPanel() }, onCalibrate: { openCalibration() })
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if syncNoticeVisible { syncNotice }
            watchingPackLayers
            // Undo of a ⭐ toggle (4 s), above the bottom bar; independent of the overlay.
            UndoToast(undoFocus: undoFocusBinding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: toastAlignment)
                .padding(.bottom, Theme.safeV + toastLift)
        }
    }

    /// Build 16 layers: sleep-timer pill + notice, next-episode card.
    @ViewBuilder
    private var watchingPackLayers: some View {
        if let state = player.sleepTimer, overlayVisible || sleepTimerEndsSoon(state) {
            SleepTimerIndicator(state: state)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, Theme.safeV + (Theme.isTV ? 130 : (toolsBelowTitle ? 110 : 64)))
                .padding(.trailing, Theme.safeH)
        }
        if sleepNoticeVisible { sleepNotice }
        if let upNext = player.upNext, !channelListVisible, !syncPanelVisible { upNextCard(upNext) }
    }

    /// Build 16 handlers (kept out of `body` – one long modifier chain is too much for the type checker).
    private func build16Handlers<Content: View>(_ content: Content) -> some View {
        content
            .onChange(of: player.sleepTimerFiredCount) {
                sleepNoticeVisible = true
                sleepNoticeTask?.cancel()
                sleepNoticeTask = Task {
                    try? await Task.sleep(for: .seconds(4))
                    if !Task.isCancelled { sleepNoticeVisible = false }
                }
            }
            #if os(tvOS)
            .onChange(of: player.upNext != nil) { _, shown in
                // The card takes the focus ("Play now"); when it goes the picture gets it back.
                if shown { Task { @MainActor in upNextPlayFocused = true } } else { surfaceFocused = !overlayVisible }
            }
            #endif
            .fullScreenCover(isPresented: $calibrationPresented, onDismiss: { player.resumeAfterRelease() }) {
                AVSyncCalibrationView(onClose: { calibrationPresented = false }).environment(env)
            }
    }

    private var layers: some View {
        mainLayers
        .animation(.easeInOut(duration: 0.18), value: overlayVisible)
        .animation(.easeInOut(duration: 0.2), value: resumeChipVisible)
        .animation(.easeInOut(duration: 0.2), value: channelListVisible)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            PerfTrace.shared.launchPhase("surface")
            showOverlay()
            if player.resumedFromMs != nil { showResumeChip() }
        }
        .onDisappear {
            hideTask?.cancel()
            resumeChipTask?.cancel()
            thumbnails.reset()
            #if os(tvOS)
            infoCardTask?.cancel()
            numberZapTask?.cancel()
            seekCommitTask?.cancel()
            #else
            landingTask?.cancel()
            #endif
        }
        .onChange(of: player.phase) { _, phase in
            #if os(tvOS)
            // The item ended / failed under the preview: nothing left to seek in.
            switch phase {
            case .ended, .failed, .locked, .idle: cancelSeekPreview()
            default: break
            }
            #endif
            // Never hide while paused/buffering; once playing (again) the 3 s count starts.
            if overlayVisible, phase == .playing { scheduleHide() }
        }
        .onChange(of: player.request?.id) {
            thumbnails.reset()   // another item: its own connection rules and frames
            #if os(tvOS)
            cancelSeekPreview()
            #endif
        }
        .onChange(of: player.resumedFromMs) { _, ms in
            if ms != nil { showResumeChip() } else { resumeChipVisible = false }
        }
        .animation(.easeInOut(duration: 0.2), value: syncPanelVisible)
        .onChange(of: player.audioSyncUnavailable) { _, unavailable in
            guard unavailable else { return }
            syncNoticeVisible = true
            syncNoticeTask?.cancel()
            syncNoticeTask = Task {
                try? await Task.sleep(for: .seconds(4))
                if !Task.isCancelled { syncNoticeVisible = false }
            }
        }
        .task(id: player.request?.id) { loadEpisodeSeries() }
        #if os(iOS)
        .statusBarHidden()
        .gesture(DragGesture(minimumDistance: 40).onEnded { value in
            guard player.request?.isLive == true, !channelListVisible else { return }
            if abs(value.translation.height) > abs(value.translation.width) {
                player.zap(by: value.translation.height < 0 ? 1 : -1)
            } else if value.translation.width > 0, value.startLocation.x < Self.edgeSwipeWidth {
                openChannelPanel()   // swipe in from the left edge
            }
        })
        #endif
        #if os(tvOS)
        .background {
            if isVOD {
                ZStack {
                    TVHoldSeek { direction, heldMs in
                        guard seekInputAllowed else { return false }
                        tvSeek(direction, heldMs: heldMs)
                        return true
                    }
                    // Siri Remote touch surface: a horizontal swipe moves the seek target.
                    TVTouchScrub(enabled: seekInputAllowed,
                                 onBegan: { touchScrubBegan() },
                                 onChanged: { touchScrubMoved($0) },
                                 onEnded: { touchScrubEnded() })
                }
            }
        }
        .focusable(!overlayVisible && !channelListVisible && !infoCardVisible && !syncPanelVisible && player.upNext == nil)
        .focused($surfaceFocused)
        .onMoveCommand { direction in
            if syncPanelVisible { return }   // its rows handle ◀▶ themselves
            if player.upNext != nil, !channelListVisible {
                // Next-episode card: ◀▶ between "Play now" and "Cancel" (nothing else moves underneath).
                if direction == .left { upNextPlayFocused = true }
                if direction == .right { upNextCancelFocused = true }
                return
            }
            if TVHoldSeek.consumesRelease(direction) { return }   // a held ◀▶ already stepped
            if infoCardVisible {
                infoCardMove(direction)
                return
            }
            if overlayVisible, !channelListVisible, let item = topFocus {
                topRowMove(direction, from: item)
                return
            }
            if isVOD, overlayVisible, !channelListVisible {
                vodOverlayMove(direction)
                return
            }
            let live = player.request?.isLive == true
            if live, overlayVisible, !channelListVisible, direction == .up {
                // Live overlay: ▲ from play/pause into the top row (close + tools).
                toolsActive = true
                Task { @MainActor in topFocus = .close }   // after the row became focusable
                return
            }
            // Live overlay / channel list shown: no zapping underneath.
            if live, overlayVisible || channelListVisible { return }
            switch direction {
            case .up: live ? showInfoCard() : showOverlay()
            case .down: live ? player.zap(by: 1) : showOverlay()
            case .left: tvSeek(-1)
            case .right: tvSeek(1)
            @unknown default: break
            }
        }
        .onPlayPauseCommand {
            // While seeking: jump to the target, then pause/resume as always.
            if seekPreview != nil { commitSeekPreview() }
            togglePlayPause()
        }
        // A ⭐ toggle on the info card keeps it open for another full period.
        .onChange(of: env.favorites.pendingUndo) { _, pending in
            guard infoCardVisible else { return }
            scheduleInfoCardHide()
            if pending == nil { infoFavoriteFocused = true }   // the toast (and its focused Undo) is gone
        }
        .task(id: infoCardVisible ? player.currentChannel?.id : nil) {
            guard infoCardVisible, let channel = player.currentChannel, let id = channel.epgId else { infoNowNext = nil; return }
            infoNowNext = (try? env.epg.nowNext(sourceId: channel.sourceId, epgIds: [id], at: Date()))?[id.lowercased()]
        }
        // Select on the picture (overlay hidden): VOD pauses/resumes like the TV app; live opens the
        // channel panel (the overlay: ◀▶ or Play/Pause). Only for the picture itself: OK on a focused
        // Menu (Audio/Subtitles/Aspect) also reaches this gesture.
        .onTapGesture {
            if seekPreview != nil {
                commitSeekPreview()   // click while the overlay is still appearing
                return
            }
            guard !syncPanelVisible, !overlayVisible, !channelListVisible, !infoCardVisible, player.upNext == nil else { return }
            if isVOD { togglePlayPause() } else { openChannelPanel() }
        }
        // Digit keys (IR remote via HDMI-CEC / keyboard): number zapping on live.
        .onKeyPress(characters: .decimalDigits) { press in
            guard let digit = press.characters.first?.wholeNumberValue, player.request?.isLive == true, !syncPanelVisible else { return .ignored }
            numberKey(digit)
            return .handled
        }
        .onExitCommand {
            // Back rules (SCREENS §2): cancel a seek preview, close panel/menu first, then leave the player.
            if seekPreview != nil { cancelSeekPreview() }
            else if player.upNext != nil, !channelListVisible, !syncPanelVisible { player.dismissUpNext() }   // Menu = Cancel
            else if syncPanelVisible { closeSyncPanel() }
            else if infoCardVisible { hideInfoCard() }
            else if channelListVisible { closeChannelPanel() }
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
                            .exclusively(before: TapGesture(count: 1).onEnded {
                                // Sync panel open: a tap on the picture closes it (no overlay on top of it).
                                toggleOverlayOrClosePanel()
                            })
                    )
                #endif
            }
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("video_surface")
        .accessibilityAction(named: L10n.t("player_show_controls")) { showOverlay() }
    }

    @ViewBuilder
    private var statusLayer: some View {
        switch player.phase {
        case .loading, .buffering:
            ProgressView().controlSize(.large).tint(.white)
        default:
            EmptyView()
        }
    }

    /// iPhone landscape (compact height): one-line card.
    private var compactHeight: Bool {
        #if os(iOS)
        verticalSizeClass == .compact
        #else
        false
        #endif
    }

    /// Reconnect card offset while the overlay is shown: between the top bar and the transport row.
    /// iPhone landscape (375–440 pt high): the 46 pt card at −80 spans ~85…145 pt from the top – below
    /// the top bar (12…56) and above play/pause (from H/2 − 32 ≥ 155); −120 with the two-line card
    /// reached up to ~35 pt and covered the title.
    private var reconnectLift: CGFloat {
        if Theme.isTV { return -190 }
        return compactHeight ? -80 : -120
    }

    private func reconnectingCard(_ attempt: Int, _ max: Int) -> some View {
        let layout = compactHeight ? AnyLayout(HStackLayout(spacing: 10)) : AnyLayout(VStackLayout(spacing: 10))
        return layout {
            ProgressView().tint(.white)
            LText("player_reconnecting", String(attempt), String(max)).font(Theme.body).foregroundStyle(.white)
        }
        .padding(compactHeight ? 12 : 20).background(RoundedRectangle(cornerRadius: 12).fill(.black.opacity(0.6)))
    }

    private func errorCard(_ error: PlaybackError) -> some View {
        ErrorCardView(presentation: error.presentation(engineOverride: player.engineOverride)) { action in
            switch action {
            case .retry: player.retry()
            case .channelList: openChannelPanel()
            default: router.closePlayer()
            }
        }
        .padding(Theme.safeH)
    }

    // MARK: Audio sync panel

    /// Opens the Sync panel and hides the overlay, so only the panel covers the picture's bottom.
    private func openSyncPanel() {
        hideTask?.cancel()
        syncPanelVisible = true
        overlayVisible = false
        menuOpen = false
        #if os(tvOS)
        toolsActive = false
        #endif
    }

    private func closeSyncPanel() {
        syncPanelVisible = false
        #if os(tvOS)
        surfaceFocused = true
        #endif
    }

    /// Sync panel → "Calibrate audio sync": the stream is released while the test clip plays (one decoder,
    /// one connection) and reopened when the screen closes (VOD at the position, live at the live edge).
    private func openCalibration() {
        closeSyncPanel()
        player.release()
        calibrationPresented = true
    }

    private var syncNotice: some View {
        Text(L10n.t("audio_sync_unavailable"))
            .font(Theme.caption)
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Capsule().fill(Color.black.opacity(0.75)))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, Theme.safeV + (Theme.isTV ? 40 : 56))
            .allowsHitTesting(false)
            .accessibilityIdentifier("audio_sync_unavailable_notice")
    }

    // MARK: Build 16 – next episode, sleep timer

    /// The sleep-timer pill shows with the overlay, and on its own during the last minute.
    private func sleepTimerEndsSoon(_ state: SleepTimerState) -> Bool {
        guard let deadline = state.deadlineMs else { return false }
        return deadline - SystemClock.monotonicMs() <= 60_000
    }

    private var sleepNotice: some View {
        Text(L10n.t("sleep_timer_fired"))
            .font(Theme.caption)
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Capsule().fill(Color.black.opacity(0.75)))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, Theme.safeV + (Theme.isTV ? 40 : 56))
            .allowsHitTesting(false)
            .accessibilityIdentifier("sleep_timer_fired")
    }

    /// Bottom right, above the timeline; tvOS: a focus section with "Play now" focused.
    private func upNextCard(_ upNext: UpNext) -> some View {
        Group {
            #if os(tvOS)
            UpNextCard(upNext: upNext, onPlay: { player.playNextEpisode() }, onCancel: { player.dismissUpNext() },
                       playFocus: $upNextPlayFocused, cancelFocus: $upNextCancelFocused)
                .focusSection()
                .defaultFocus($upNextPlayFocused, true)
            #else
            UpNextCard(upNext: upNext, onPlay: { player.playNextEpisode() }, onCancel: { player.dismissUpNext() })
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(.trailing, Theme.safeH)
        .padding(.bottom, Theme.safeV + (Theme.isTV ? 170 : (overlayVisible ? 132 : 24)))
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }

    // MARK: Channel panel

    /// Left-edge band that starts the "swipe in" of the channel panel (iOS).
    private static let edgeSwipeWidth: CGFloat = 44

    /// Opens the channel panel and hides the overlay (and its top row), so closing the panel leaves
    /// the picture alone instead of an overlay that would never auto-hide.
    private func openChannelPanel() {
        guard player.request?.isLive == true else { return }
        hideTask?.cancel()
        channelListVisible = true
        overlayVisible = false
        menuOpen = false
        #if os(tvOS)
        toolsActive = false
        topFocus = nil
        infoCardTask?.cancel()
        infoCardVisible = false
        #endif
    }

    private func closeChannelPanel() {
        channelListVisible = false
        if overlayVisible { scheduleHide() }   // e.g. Play/Pause showed it while the panel was open
        #if os(tvOS)
        surfaceFocused = true
        #endif
    }

    // MARK: Overlay visibility

    /// Never on top of the Sync panel (double tap, Play/Pause, VoiceOver "show controls"): the panel
    /// replaces the overlay until it is closed.
    private func showOverlay() {
        guard !syncPanelVisible else { return }
        overlayVisible = true
        scheduleHide()
    }

    private func hideOverlay() {
        hideTask?.cancel()
        overlayVisible = false
        menuOpen = false   // a menu dismissed without a choice
        #if os(iOS)
        scrubFraction = nil   // a drag cut off by the hide never ends
        scrubOrigin = nil
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
        // VoiceOver users navigate the controls element by element: never pull them away.
        guard player.phase == .playing, !channelListVisible, !voiceOverEnabled else { return false }
        #if os(iOS)
        if scrubFraction != nil || menuOpen { return false }
        #else
        // tvOS: the top row (and the menus opened from it) is in use; ▼ to play/pause re-arms the hide.
        // (Menu items' onAppear is not a reliable "menu open" signal on tvOS.)
        if toolsActive || seekPreview != nil { return false }
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

    /// The play/pause control: tvOS OK while the seek target is shown jumps there (no pause).
    private func playPausePressed() {
        #if os(tvOS)
        if seekPreview != nil {
            commitSeekPreview()
            return
        }
        #endif
        togglePlayPause()
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
            if seekPreview != nil { commitSeekPreview() }
            toolsActive = true
            Task { @MainActor in topFocus = .close }   // after the row became focusable
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

    /// Controls of the top row, left to right (as shown by `topBar` / `tools`).
    private var topItems: [TopItem] {
        var items: [TopItem] = [.close, .audio]
        if !player.subtitleOptions.isEmpty { items.append(.subtitles) }
        items += [.aspect, .resync, .sleep]
        if favoriteTarget != nil { items.append(.favorite) }
        if player.request?.isLive == true {
            items.append(.channelList)
            if player.previousChannel != nil { items.append(.previous) }
        }
        return items
    }

    /// Focus in the top row: ◀▶ move along it (stopping at the ends), ▼ back to play/pause (VOD: ◀▶ seek again).
    private func topRowMove(_ direction: MoveCommandDirection, from item: TopItem) {
        let items = topItems
        switch direction {
        case .left, .right:
            if let index = items.firstIndex(of: item) {
                let next = index + (direction == .left ? -1 : 1)
                if items.indices.contains(next) { topFocus = items[next] }
            }
        case .down:
            toolsActive = false
            topFocus = nil
            playPauseFocused = true
        default:
            break
        }
        scheduleHide()
    }

    /// ◀▶ / held ◀▶ / swipes may move the seek target (no panel, top row or menu in use).
    private var seekInputAllowed: Bool {
        !channelListVisible && !syncPanelVisible && !infoCardVisible && !(overlayVisible && toolsActive)
    }

    /// ◀▶ moves the seek target 10 s; held (`TVHoldSeek` repeats every 0.3 s) 30 → 60 → 120 s steps
    /// (`SeekAccelerator`). The seek itself happens once, on commit.
    private func tvSeek(_ direction: Int, heldMs: Int64 = 0) {
        guard isVOD else { showOverlay(); return }
        let now = SystemClock.monotonicMs()
        // A swipe on the touch surface is already moving the target (or just did).
        if seekPreview?.isPanning == true || now - lastPanEndMs < 250 { return }
        var preview = seekPreview ?? SeekPreview(origin: player.currentTime, duration: player.duration, nowMs: now)
        preview.step(direction: direction, heldMs: heldMs, nowMs: now)
        updateSeekPreview(preview)
        scheduleSeekCommit()
    }

    /// Shows the target (overlay + bubble, no auto-hide) and asks for its thumbnail.
    private func updateSeekPreview(_ preview: SeekPreview) {
        if seekPreview == nil { thumbnails.prepare(player: player) }
        seekPreview = preview
        hideTask?.cancel()
        if !overlayVisible { overlayVisible = true }
        thumbnails.request(preview.target)
    }

    /// Commits after `SeekPreview.commitIdleMs` without input (a resting finger keeps the preview).
    private func scheduleSeekCommit() {
        seekCommitTask?.cancel()
        seekCommitTask = Task {
            let idleMs = player.seekCommitIdleMs
            try? await Task.sleep(for: .milliseconds(idleMs + 20))
            guard !Task.isCancelled, let preview = seekPreview,
                  preview.isCommitDue(nowMs: SystemClock.monotonicMs(), idleMs: idleMs) else { return }
            commitSeekPreview(automatic: true)
        }
    }

    /// One seek to the target (none when it did not move); the overlay's 3 s count restarts. `automatic` (idle
    /// commit) stops 10 s before the end (B-19); OK / Play may go to the very end.
    private func commitSeekPreview(automatic: Bool = false) {
        seekCommitTask?.cancel()
        guard let preview = seekPreview else { return }
        seekPreview = nil
        thumbnails.endScrub()
        let target = automatic ? preview.autoCommitTarget : preview.target
        if abs(target - preview.origin) >= 0.5 { player.seek(toSeconds: target) }
        if overlayVisible { scheduleHide() }
    }

    /// Menu: the target snaps back, no seek.
    private func cancelSeekPreview() {
        seekCommitTask?.cancel()
        guard seekPreview != nil else { return }
        seekPreview = nil
        thumbnails.endScrub()
        if overlayVisible { scheduleHide() }
    }

    private func touchScrubBegan() {
        guard isVOD else { return }
        let now = SystemClock.monotonicMs()
        seekCommitTask?.cancel()
        var preview = seekPreview ?? SeekPreview(origin: player.currentTime, duration: player.duration, nowMs: now)
        preview.beginPan(nowMs: now)
        updateSeekPreview(preview)
    }

    /// `translation`: horizontal finger travel as a share of the surface width.
    private func touchScrubMoved(_ translation: Double) {
        guard var preview = seekPreview else { return }
        preview.pan(translation: translation, nowMs: SystemClock.monotonicMs())
        updateSeekPreview(preview)
    }

    private func touchScrubEnded() {
        let now = SystemClock.monotonicMs()
        lastPanEndMs = now
        guard var preview = seekPreview else { return }
        preview.endPan(nowMs: now)
        seekPreview = preview
        scheduleSeekCommit()
    }

    // MARK: Info card (tvOS live)

    private static let infoCardSeconds = 6

    private func showInfoCard() {
        infoCardVisible = true
        scheduleInfoCardHide()
    }

    private func hideInfoCard() {
        infoCardTask?.cancel()
        infoCardVisible = false
        surfaceFocused = true
    }

    private func scheduleInfoCardHide() {
        infoCardTask?.cancel()
        infoCardTask = Task {
            try? await Task.sleep(for: .seconds(Self.infoCardSeconds))
            guard !Task.isCancelled, !voiceOverEnabled else { return }
            hideInfoCard()
        }
    }

    /// Card shown: ▲▼ zap (the card follows the channel), anything else keeps it open. While the undo
    /// toast is offered, ▼ goes to "Undo" and ▲ back to ⭐ instead of zapping.
    private func infoCardMove(_ direction: MoveCommandDirection) {
        let undoOffered = env.favorites.pendingUndo != nil
        switch direction {
        case .up where undoOffered: infoFavoriteFocused = true
        case .down where undoOffered: undoFocused = true
        case .up: player.zap(by: -1)
        case .down: player.zap(by: 1)
        default: break
        }
        scheduleInfoCardHide()
    }

    /// Channel info (spec §2 "▲ = kanal bilgisi"): logo, number, name, now/next; ⭐ has the focus.
    private func infoCard(_ channel: Channel) -> some View {
        let nowNext = infoNowNext
        return VStack {
            Spacer()
            HStack(alignment: .center, spacing: 36) {
                ChannelLogo(url: channel.logoUrl, width: 160)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 16) {
                        if let n = channel.number { Text(String(n)).font(Theme.headline.monospacedDigit()).foregroundStyle(Theme.textSecondary) }
                        Text(channel.name).font(Theme.title).foregroundStyle(.white).lineLimit(1)
                    }
                    if let now = nowNext?.now {
                        HStack(spacing: 14) {
                            LText("epg_now").font(Theme.caption.weight(.heavy)).foregroundStyle(Theme.live)
                            Text(env.timeFormatter.range(start: now.start, end: now.end)).font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.textSecondary)
                            Text(now.title).font(Theme.body.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                        }
                        ProgressBar(value: EpgSchedule.progress(of: now, at: Date()), color: Theme.live).frame(width: 520, height: 5)
                    } else {
                        LText("epg_no_info").font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    }
                    if let next = nowNext?.next {
                        HStack(spacing: 14) {
                            LText("epg_next").font(Theme.caption.weight(.heavy)).foregroundStyle(Theme.textSecondary)
                            Text(env.timeFormatter.time(next.start)).font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.textSecondary)
                            Text(next.title).font(Theme.body).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 20)
                if let target = env.favoriteTarget(channel) {
                    FavoriteButton(target: target, style: .labeled)
                        .buttonStyle(SecondaryButtonStyle())
                        .focused($infoFavoriteFocused)
                        .onAppear { infoFavoriteFocused = true }
                }
            }
            .padding(36)
            .background(RoundedRectangle(cornerRadius: Theme.cardRadius * 2, style: .continuous).fill(Theme.surfaceElevated.opacity(0.95)))
            .padding(.horizontal, Theme.safeH)
            .padding(.bottom, Theme.safeV + 20 + (env.favorites.pendingUndo != nil ? 120 : 0))   // room for the toast below
        }
        .focusSection()
        .defaultFocus($infoFavoriteFocused, true)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player_info_card")
    }

    // MARK: Number zapping (tvOS)

    private static let numberZapTimeoutMs = 1500

    private func numberKey(_ digit: Int) {
        zapNoChannel = false
        zapDigits = numberZap.input(digit, atMs: SystemClock.monotonicMs())
        numberZapTask?.cancel()
        numberZapTask = Task {
            try? await Task.sleep(for: .milliseconds(Self.numberZapTimeoutMs + 20))
            guard !Task.isCancelled else { return }
            commitNumberZap()
        }
    }

    /// Tunes the typed number anywhere in the source (CatalogRepository.channelForNumberZap); a channel
    /// outside the zap list brings its category window (100 before/after it) as the new zap list.
    /// Unknown → "No such channel"; a database error keeps the current channel (logged, no UI).
    private func commitNumberZap() {
        let number = numberZap.commitIfDue(atMs: SystemClock.monotonicMs())
        zapDigits = ""
        guard let number, let current = player.currentChannel else { return }
        let target: Channel?
        do {
            target = try env.catalog.channelForNumberZap(sourceId: current.sourceId, number: number)
        } catch {
            SafeLog.error("number zap lookup failed: \(error)")
            return
        }
        guard let channel = target else {
            zapNoChannel = true
            numberZapTask = Task {
                try? await Task.sleep(for: .seconds(2))
                if !Task.isCancelled { zapNoChannel = false }
            }
            return
        }
        guard channel.id != current.id else { return }
        if player.request?.channels.contains(where: { $0.id == channel.id }) == true {
            player.zap(to: channel)
            return
        }
        var window: [Channel] = []
        if let categoryId = channel.categoryId {
            do {
                window = try env.catalog.channelZapWindow(sourceId: channel.sourceId, categoryId: categoryId, around: channel.id)
            } catch {
                SafeLog.error("number zap list failed: \(error)")
                return
            }
        }
        player.zap(to: channel, channels: window.isEmpty ? [channel] : window)
    }

    /// Big digits top right while a number is typed.
    private var numberIndicator: some View {
        Text(verbatim: zapNoChannel ? L10n.t("zap_no_channel") : zapDigits)
            .font(zapNoChannel ? Theme.title : .system(size: 96, weight: .heavy).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 36).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: Theme.cardRadius).fill(.black.opacity(0.6)))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.top, Theme.safeV)
            .padding(.trailing, Theme.safeH)
            .allowsHitTesting(false)
            .accessibilityLabel(zapNoChannel ? L10n.t("zap_no_channel") : L10n.t("zap_number", zapDigits))
            .accessibilityIdentifier("player_number_zap")
    }
    #endif

    #if os(iOS)
    /// Single tap / double tap outside the seek thirds: the sync panel closes first (no overlay on
    /// top of it), otherwise the overlay toggles.
    private func toggleOverlayOrClosePanel() {
        if syncPanelVisible { closeSyncPanel() } else if overlayVisible { hideOverlay() } else { showOverlay() }
    }

    private func doubleTap(at x: CGFloat, width: CGFloat) {
        guard isVOD, width > 0 else {
            toggleOverlayOrClosePanel()
            return
        }
        let third = width / 3
        guard x < third || x > width - third else {
            toggleOverlayOrClosePanel()
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

    /// iPhone portrait / narrow iPad windows (IOS-01): the tools get their own row under close + title – in one
    /// row the live tools (up to 7) were wider than the screen and pushed the whole overlay past both edges.
    private var toolsBelowTitle: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact && verticalSizeClass != .compact
        #else
        false
        #endif
    }

    @ViewBuilder
    private var topBar: some View {
        if toolsBelowTitle {
            VStack(alignment: .leading, spacing: 10) {
                titleRow(withTools: false)
                // Never wider than the screen: tighter spacing, then a horizontal scroller (AX text sizes).
                ViewThatFits(in: .horizontal) {
                    HStack { Spacer(minLength: 0); tools() }
                    HStack { Spacer(minLength: 0); tools(spacing: 6) }
                    ScrollView(.horizontal, showsIndicators: false) { tools(spacing: 6) }
                }
            }
            .accessibilityElement(children: .contain)
        } else {
            titleRow(withTools: true)
        }
    }

    private func titleRow(withTools: Bool) -> some View {
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
            .focused($topFocus, equals: .close)
            .overlay(alignment: .bottom) { toolCaption(.close, "action_close") }
            #endif
            if let number = player.currentChannel?.number {
                Text(String(number)).font(Theme.headline.monospacedDigit()).foregroundStyle(Theme.textSecondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(player.request?.title ?? "").font(Theme.headline).foregroundStyle(.white).lineLimit(1)
                    .accessibilityIdentifier("player_title")
                if let channel = player.currentChannel, let now = nowProgramme(channel) {
                    Text(now.title).font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 0)
            if withTools { tools() }
        }
        #if os(tvOS)
        // Entering the row lands on close. Not focusable until ▲ from play/pause (VOD: ◀▶ there seek; live: the ◀▶ that shows the
        // overlay must not carry the focus on into the tools).
        .disabled(!toolsActive)
        .focusSection()
        .defaultFocus($topFocus, .close, priority: .userInitiated)
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
        let busy: Bool = {
            switch player.phase {
            case .loading, .buffering, .reconnecting: return true
            default: return false
            }
        }()
        return Button { playPausePressed() } label: {
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
        .accessibilityValue(L10n.t(showsPlayIcon ? "player_state_paused" : "player_state_playing"))
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

    private func tools(spacing: CGFloat? = nil) -> some View {
        HStack(spacing: spacing ?? (Theme.isTV ? 24 : 18)) {
            // Always shown: the Sync row exists even without selectable audio tracks.
            trackedMenu("speaker.wave.2", label: "player_audio") {
                ForEach(player.audioOptions) { option in
                    Button { player.selectAudio(option.id); menuClosed() } label: {
                        Label(option.name ?? L10n.t("unknown_track", String(option.id + 1)), systemImage: player.selectedAudio == option.id ? "checkmark" : "")
                    }
                }
                Button { menuClosed(); openSyncPanel() } label: {
                    Label("\(L10n.t("audio_sync")) (\(AudioDelayControl.shortLabel(player.contentAudioDelay)))", systemImage: "waveform")
                }
                .accessibilityIdentifier("player_audio_sync")
            }
            #if os(tvOS)
            .focused($topFocus, equals: .audio)
            .overlay(alignment: .bottom) { toolCaption(.audio, "player_audio") }
            #endif
            if !player.subtitleOptions.isEmpty {
                trackedMenu("captions.bubble", label: "player_subtitles") {
                    Button { player.selectSubtitle(nil); menuClosed() } label: { Label(L10n.t("off"), systemImage: player.selectedSubtitle == nil ? "checkmark" : "") }
                    ForEach(player.subtitleOptions) { option in
                        Button { player.selectSubtitle(option.id); menuClosed() } label: {
                            Label(option.name ?? L10n.t("unknown_track", String(option.id + 1)), systemImage: player.selectedSubtitle == option.id ? "checkmark" : "")
                        }
                    }
                    Divider()
                    SubtitleOptionsMenuItems(player: player) { menuClosed() }
                }
                #if os(tvOS)
                .focused($topFocus, equals: .subtitles)
                .overlay(alignment: .bottom) { toolCaption(.subtitles, "player_subtitles") }
                #endif
            }
            trackedMenu("aspectratio", label: "player_aspect") {
                ForEach(AspectMode.allCases, id: \.self) { mode in
                    Button { env.player.aspect = mode; menuClosed() } label: { Label(L10n.t(mode.titleKey), systemImage: player.aspect == mode ? "checkmark" : "") }
                }
            }
            #if os(tvOS)
            .focused($topFocus, equals: .aspect)
            .overlay(alignment: .bottom) { toolCaption(.aspect, "player_aspect") }
            #endif
            // "Fix sync": reopen the stream (live edge / current position).
            Button { player.resync(); showOverlay() } label: { toolIcon("arrow.triangle.2.circlepath") }
                .accessibilityLabel(L10n.t("audio_sync_fix"))
                .accessibilityIdentifier("action_resync")
                #if os(tvOS)
                .focused($topFocus, equals: .resync)
                .overlay(alignment: .bottom) { toolCaption(.resync, "audio_sync_fix") }
                #endif
            // Sleep timer (Build 16): Off · 15 · 30 · 60 · 90 min · end of episode/movie.
            trackedMenu(player.sleepTimer == nil ? "moon.zzz" : "moon.zzz.fill", label: "sleep_timer") {
                SleepTimerMenuItems(player: player) { menuClosed() }
            }
            .accessibilityIdentifier("player_sleep_timer")
            #if os(tvOS)
            .focused($topFocus, equals: .sleep)
            .overlay(alignment: .bottom) { toolCaption(.sleep, "sleep_timer") }
            #endif
            if let target = favoriteTarget {
                FavoriteButton(target: target, minTapSize: Theme.isTV ? 0 : 36)
                    #if os(tvOS)
                    .focused($topFocus, equals: .favorite)
                    #endif
            }
            if player.request?.isLive == true {
                Button { openChannelPanel() } label: { toolIcon("list.bullet") }
                    .accessibilityLabel(L10n.t("action_channel_list"))
                    .accessibilityIdentifier("action_channel_list")
                    #if os(tvOS)
                    .focused($topFocus, equals: .channelList)
                    .overlay(alignment: .bottom) { toolCaption(.channelList, "action_channel_list") }
                    #endif
                if player.previousChannel != nil {
                    Button { player.switchToPreviousChannel() } label: { toolIcon("arrow.uturn.backward") }
                        .accessibilityLabel(L10n.t("player_previous_channel"))
                        #if os(tvOS)
                        .focused($topFocus, equals: .previous)
                        .overlay(alignment: .bottom) { toolCaption(.previous, "player_previous_channel") }
                        #endif
                }
            }
        }
        .font(Theme.headline)
        .foregroundStyle(.white)
        .buttonStyle(.borderless)
        // Glyphs with VoiceOver labels: they grow with Dynamic Type only up to XL, so the row stays on screen
        // at accessibility sizes (IOS-01); the menus they open use the full text size.
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
    }

    /// ⭐ of what is playing: the current channel, the movie, or the series of an episode.
    private var favoriteTarget: FavoriteTarget? {
        if let channel = player.currentChannel { return env.favoriteTarget(channel) }
        switch player.request?.item {
        case .movie(let m)?:
            return env.favoriteTarget(m)
        case .episode(let e, let seriesTitle)?:
            if let series = episodeSeries, series.id == e.seriesId { return env.favoriteTarget(series) }
            return env.favoriteTarget(sourceId: e.sourceId, kind: .series, itemId: e.seriesId, title: seriesTitle, posterUrl: nil)
        default:
            return nil
        }
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

    #if os(tvOS)
    /// U-04 (Build 16): the focused top-row tool shows its name under the icon (icons alone were ambiguous
    /// from the sofa: ↻ Fix sync, ↶ last channel, moon = sleep timer).
    @ViewBuilder
    private func toolCaption(_ item: TopItem, _ key: String) -> some View {
        if topFocus == item {
            Text(L10n.t(key))
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(Color.black.opacity(0.7)))
                .offset(y: 56)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
    #endif

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
        menuOpen = false
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

    /// VOD timeline: iOS draggable scrubber, tvOS display bar (◀▶ / swipes move the seek target).
    /// Both show the seek bubble (target time · jump, thumbnail where safe) above the target.
    private var vodTimeline: some View {
        let duration = player.duration
        let fraction = duration > 0 ? min(1, max(0, player.currentTime / duration)) : 0
        #if os(iOS)
        let target = scrubFraction.map { $0 * duration }
        let bubble: SeekLanding? = target.map { SeekLanding(target: $0, delta: $0 - (scrubOrigin ?? player.currentTime)) } ?? landing
        #else
        let target = seekPreview?.target
        let bubble = seekPreview.map { SeekLanding(target: $0.target, delta: $0.delta) }
        #endif
        let shownTime = target ?? player.currentTime
        return VStack(spacing: Theme.isTV ? 12 : 0) {
            #if os(iOS)
            PlayerScrubber(fraction: fraction, duration: duration, dragFraction: scrubBinding) { target in
                player.seek(toFraction: target)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { timelineWidth = $0 }
            .overlay(alignment: .bottomLeading) {
                if let bubble {
                    SeekBubble(target: bubble.target, delta: bubble.delta, thumbnail: thumbnails.image)
                        .modifier(BubblePlacement(fraction: duration > 0 ? bubble.target / duration : 0, width: timelineWidth, lift: 50))
                        .transition(.opacity)
                }
            }
            #else
            tvTimelineBar(fraction: fraction)
            #endif
            HStack {
                Text(L10n.clock(shownTime))
                    .accessibilityIdentifier("player_time")
                Spacer()
                // While seeking: the time left from the target.
                Text(duration > 0 ? (target.map { "\u{2212}" + L10n.clock(max(0, duration - $0)) } ?? L10n.clock(duration)) : "--:--")
                    .accessibilityIdentifier("player_duration")
            }
            .font(Theme.caption.monospacedDigit())
            .foregroundStyle(.white)
        }
        .animation(.easeOut(duration: 0.15), value: bubble != nil)
    }

    #if os(tvOS)
    /// Display bar; while a seek target is shown it grows and carries a marker + the bubble.
    private func tvTimelineBar(fraction: Double) -> some View {
        let preview = seekPreview
        let barHeight: CGFloat = preview != nil ? 16 : 8
        return ProgressBar(value: fraction)
            .frame(height: barHeight)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { timelineWidth = $0 }
            .overlay(alignment: .leading) {
                if let targetFraction = preview?.fraction {
                    Capsule().fill(.white)
                        .frame(width: 8, height: 40)
                        .shadow(color: .black.opacity(0.5), radius: 4)
                        .offset(x: timelineWidth * min(1, max(0, targetFraction)) - 4)
                        .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if let preview {
                    SeekBubble(target: preview.target, delta: preview.delta, thumbnail: thumbnails.image)
                        .modifier(BubblePlacement(fraction: preview.fraction ?? fraction, width: timelineWidth, lift: barHeight + 30))
                }
            }
    }
    #endif

    #if os(iOS)
    private var scrubBinding: Binding<Double?> {
        Binding(get: { scrubFraction }, set: { value in
            let started = scrubFraction == nil && value != nil
            let ended = scrubFraction != nil && value == nil
            let last = scrubFraction
            if started {
                scrubOrigin = player.currentTime
                landingTask?.cancel()
                landing = nil
                thumbnails.prepare(player: player)
            }
            scrubFraction = value
            if let value, player.duration > 0 { thumbnails.request(value * player.duration) }
            if value != nil { hideTask?.cancel() }
            if ended {
                // The bubble stays a moment on the landing point (the scrubber seeks on release).
                if let last, player.duration > 0 {
                    let target = last * player.duration
                    landing = SeekLanding(target: target, delta: target - (scrubOrigin ?? target))
                    landingTask?.cancel()
                    landingTask = Task {
                        try? await Task.sleep(for: .seconds(Self.landingSeconds))
                        guard !Task.isCancelled else { return }
                        landing = nil
                        thumbnails.endScrub()
                    }
                } else {
                    thumbnails.endScrub()
                }
                scrubOrigin = nil
                scheduleHide()
            }
        })
    }

    /// How long the bubble stays on the landing point after the finger lifts.
    private static let landingSeconds = 1.5
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

    /// The series of a playing episode (its poster/name for ⭐), once per request.
    private func loadEpisodeSeries() {
        guard case .episode(let e, _)? = player.request?.item else { episodeSeries = nil; return }
        episodeSeries = (try? env.catalog.seriesItem(sourceId: e.sourceId, id: e.seriesId)) ?? nil
    }

    private var toastAlignment: Alignment {
        #if os(tvOS)
        infoCardVisible ? .bottomTrailing : .bottom
        #else
        .bottom
        #endif
    }

    private var undoFocusBinding: FocusState<Bool>.Binding? {
        #if os(tvOS)
        $undoFocused
        #else
        nil
        #endif
    }
}

/// What the seek bubble shows: target position and the jump from where seeking started.
private struct SeekLanding: Equatable {
    var target: Double
    var delta: Double
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
/// target – incoming time ticks do not move the thumb – and the seek happens on release. The target
/// bubble (`SeekBubble`) is drawn by `PlayerView` above it.
private struct PlayerScrubber: View {
    let fraction: Double
    let duration: Double
    @Binding var dragFraction: Double?
    let onCommit: (Double) -> Void
    /// Finger position; SwiftUI resets it when the drag ends *or is cancelled* (view removed,
    /// second touch, interruption) – mirrored into `dragFraction`, so a cancelled drag cannot
    /// leave the timeline frozen and the overlay pinned.
    @GestureState private var fingerFraction: Double?

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
            }
            .frame(width: width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(drag(width: width), including: enabled ? .all : .subviews)
            .onChange(of: fingerFraction) { _, value in dragFraction = value }
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
        .onDisappear { dragFraction = nil }
    }

    private func drag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($fingerFraction) { value, state, _ in state = min(1, max(0, value.location.x / width)) }
            .onEnded { value in onCommit(min(1, max(0, value.location.x / width))) }
    }
}
#endif

#if os(tvOS)
/// Press-and-hold ◀▶ on the Siri Remote: SwiftUI's `onMoveCommand` fires once per press, on release
/// (no repeat while held). A press observer on the window starts repeating the step 0.4 s after the
/// arrow went down and every 0.3 s after that, until it comes up (`heldMs` drives the acceleration).
///
/// Not a `UILongPressGestureRecognizer`: the focus engine's own directional press recognizer (its
/// hold-to-repeat) and SwiftUI's press recognizer compete for the same press, and whichever passes
/// its threshold first wins the exclusive recognition – the long press then never began and the
/// hold became one 10 s step. The observer never recognizes, so it can neither be prevented nor
/// prevent anything; it sees every press. When a hold was handled (`onStep` returned true), the
/// `onMoveCommand` SwiftUI still sends on release is swallowed via `consumesRelease`. A short
/// press reaches `onMoveCommand` as usual. Also used by the audio delay stepper.
struct TVHoldSeek: UIViewRepresentable {
    /// (direction, ms since the button went down) → whether the step was handled (only then is the
    /// release's `onMoveCommand` swallowed).
    let onStep: @MainActor (Int, Int64) -> Bool

    /// Last handled hold: its direction and when the arrow came up.
    @MainActor private static var lastHoldRelease: (direction: Int, at: TimeInterval)?

    /// `onMoveCommand` arriving right after a handled hold of the same arrow is that hold's release
    /// (it follows the press-up within milliseconds): true once, then the hold is forgotten.
    @MainActor static func consumesRelease(_ direction: MoveCommandDirection) -> Bool {
        let value: Int
        switch direction {
        case .left: value = -1
        case .right: value = 1
        default: return false
        }
        guard let last = lastHoldRelease else { return false }
        lastHoldRelease = nil
        return last.direction == value && ProcessInfo.processInfo.systemUptime - last.at < 0.25
    }

    func makeUIView(context: Context) -> HoldView {
        let view = HoldView()
        view.onStep = onStep
        return view
    }

    func updateUIView(_ view: HoldView, context: Context) { view.onStep = onStep }

    static func dismantleUIView(_ view: HoldView, coordinator: ()) { view.detach() }

    final class HoldView: UIView {
        var onStep: (@MainActor (Int, Int64) -> Bool)?
        private static let minimumPressMs = 400
        private static let repeatMs = 300
        private var observer: ArrowPressObserver?
        private var repeatTask: Task<Void, Never>?
        private var handledHold = false
        private weak var attachedWindow: UIWindow?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { detach() } else { attach() }
        }

        private func attach() {
            guard let window, attachedWindow !== window else { return }
            detach()
            let observer = ArrowPressObserver()
            observer.onDown = { [weak self] direction in self?.pressDown(direction) }
            observer.onUp = { [weak self] direction in self?.pressUp(direction) }
            window.addGestureRecognizer(observer)
            self.observer = observer
            attachedWindow = window
        }

        func detach() {
            repeatTask?.cancel()
            repeatTask = nil
            handledHold = false
            if let observer { observer.view?.removeGestureRecognizer(observer) }
            observer = nil
            attachedWindow = nil
        }

        private func pressDown(_ direction: Int) {
            repeatTask?.cancel()
            handledHold = false
            let pressedAt = ProcessInfo.processInfo.systemUptime
            repeatTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(Self.minimumPressMs))
                while !Task.isCancelled, let self {
                    let heldMs = Int64((ProcessInfo.processInfo.systemUptime - pressedAt) * 1000)
                    if self.onStep?(direction, heldMs) == true { self.handledHold = true }
                    try? await Task.sleep(for: .milliseconds(Self.repeatMs))
                }
            }
        }

        private func pressUp(_ direction: Int) {
            repeatTask?.cancel()
            repeatTask = nil
            if handledHold {
                TVHoldSeek.lastHoldRelease = (direction, ProcessInfo.processInfo.systemUptime)
            }
            handledHold = false
        }
    }

    /// Reports ◀▶ press down/up as the window sees them. Never recognizes: it cannot be prevented by
    /// (nor prevent) the focus engine's or SwiftUI's press recognizers, and delays nothing.
    final class ArrowPressObserver: UIGestureRecognizer {
        var onDown: ((Int) -> Void)?
        var onUp: ((Int) -> Void)?
        private var down: (press: UIPress, direction: Int)?

        init() {
            super.init(target: nil, action: nil)
            allowedPressTypes = [UIPress.PressType.leftArrow, .rightArrow].map { NSNumber(value: $0.rawValue) }
            allowedTouchTypes = []
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
        }

        override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
        override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

        private static func direction(of press: UIPress) -> Int? {
            switch press.type {
            case .leftArrow: -1
            case .rightArrow: 1
            default: nil
            }
        }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent) {
            guard let press = presses.first(where: { Self.direction(of: $0) != nil }),
                  let direction = Self.direction(of: press) else { return }
            if let previous = down { onUp?(previous.direction) }   // a second arrow replaces the first
            down = (press, direction)
            onDown?(direction)
        }

        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent) { finish(presses) }
        override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent) { finish(presses) }

        private func finish(_ presses: Set<UIPress>) {
            if let current = down, presses.contains(current.press) {
                down = nil
                onUp?(current.direction)
            }
            if down == nil { state = .failed }   // back to .possible for the next press
        }

        override func reset() {
            super.reset()
            if let current = down {
                down = nil
                onUp?(current.direction)
            }
        }
    }
}

/// Horizontal swipes on the Siri Remote touch surface (indirect touches) for the seek preview: a pan
/// recognizer on the window reports the finger's travel as a share of the window width (a full
/// swipe ≈ 1). Vertical swipes are left to the focus engine; disabled while panels/the top row are in use.
struct TVTouchScrub: UIViewRepresentable {
    var enabled: Bool
    let onBegan: @MainActor () -> Void
    let onChanged: @MainActor (Double) -> Void
    let onEnded: @MainActor () -> Void

    func makeUIView(context: Context) -> PanView {
        let view = PanView()
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ view: PanView, context: Context) {
        view.onBegan = onBegan
        view.onChanged = onChanged
        view.onEnded = onEnded
        view.enabled = enabled
    }

    static func dismantleUIView(_ view: PanView, coordinator: ()) { view.detach() }

    final class PanView: UIView, UIGestureRecognizerDelegate {
        var onBegan: (@MainActor () -> Void)?
        var onChanged: (@MainActor (Double) -> Void)?
        var onEnded: (@MainActor () -> Void)?
        var enabled = true {
            didSet { recognizer?.isEnabled = enabled }
        }
        private var recognizer: UIPanGestureRecognizer?
        private weak var attachedWindow: UIWindow?
        private var active = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { detach() } else { attach() }
        }

        private func attach() {
            guard let window, attachedWindow !== window else { return }
            detach()
            let r = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
            r.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
            r.cancelsTouchesInView = false
            r.delegate = self
            r.isEnabled = enabled
            window.addGestureRecognizer(r)
            recognizer = r
            attachedWindow = window
        }

        func detach() {
            if active { onEnded?() }
            active = false
            if let recognizer { recognizer.view?.removeGestureRecognizer(recognizer) }
            recognizer = nil
            attachedWindow = nil
        }

        @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
            let width = max(1, recognizer.view?.bounds.width ?? 1)
            let share = Double(recognizer.translation(in: recognizer.view).x / width)
            switch recognizer.state {
            case .began:
                active = true
                onBegan?()
                onChanged?(share)
            case .changed:
                if active { onChanged?(share) }
            case .ended, .cancelled, .failed:
                // No momentum: the target stays where the finger left it.
                if active { onEnded?() }
                active = false
            default:
                break
            }
        }

        /// Only clearly horizontal swipes start a scrub (UIView already declares this delegate selector).
        override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer, pan === recognizer else { return super.gestureRecognizerShouldBegin(gestureRecognizer) }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y) * 1.5
        }

        /// The focus engine and the press recognizers keep working alongside.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}
#endif

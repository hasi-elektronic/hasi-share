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
    @State private var channelListVisible = false
    /// "Play from start" chip after an automatic resume (5 s, independent of the overlay).
    @State private var resumeChipVisible = false
    @State private var resumeChipTask: Task<Void, Never>?
    /// Audio → Sync panel (SCREENS §3.7): non-modal, at the bottom, the picture stays visible.
    @State private var syncPanelVisible = false
    /// "Sync can't be applied to this stream" (VLCKit failed, AVPlayer without the delay) – 4 s.
    @State private var syncNoticeVisible = false
    @State private var syncNoticeTask: Task<Void, Never>?
    /// An audio/subtitle/aspect menu is open: removing its source view would close it.
    @State private var menuOpen = false
    #if os(iOS)
    /// Scrubber position while the finger is down (nil = follow playback).
    @State private var scrubFraction: Double?
    @State private var ripple: SeekRipple?
    @State private var rippleTask: Task<Void, Never>?
    #endif
    #if os(tvOS)
    @FocusState private var surfaceFocused: Bool
    @FocusState private var playPauseFocused: Bool
    /// Top row (close + tools). The root `onMoveCommand` swallows every move the focused control does
    /// not handle, so ◀▶ walk the row explicitly (`topRowMove`) and ▼ returns to play/pause.
    enum TopItem: Hashable { case close, audio, subtitles, aspect, resync, favorite, channelList, previous }
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
    #endif

    private var player: PlayerController { env.player }
    private var isVOD: Bool { player.request.map { !$0.isLive } ?? false }
    /// The play/pause control shows "play" (paused by the user or finished).
    private var showsPlayIcon: Bool { player.phase == .paused || player.phase == .ended || player.phase == .idle }
    private static let autoHideSeconds = 3
    /// Per request / per opening, not per render: the series of an episode (⭐) and the zap list
    /// with favorites on top.
    @State private var episodeSeries: Series?
    @State private var channelListCache: [Channel] = []

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
                    reconnectingCard(attempt, max).offset(y: overlayVisible ? (Theme.isTV ? -190 : -120) : 0)
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
            #endif
            if channelListVisible { channelList }
            if syncPanelVisible {
                AudioSyncPanel(player: player) { closeSyncPanel() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if syncNoticeVisible { syncNotice }
            // Undo of a ⭐ toggle (4 s), above the bottom bar; independent of the overlay.
            UndoToast(undoFocus: undoFocusBinding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: toastAlignment)
                .padding(.bottom, Theme.safeV + toastLift)
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
            #if os(tvOS)
            infoCardTask?.cancel()
            #endif
        }
        .onChange(of: player.phase) { _, phase in
            // Never hide while paused/buffering; once playing (again) the 3 s count starts.
            if overlayVisible, phase == .playing { scheduleHide() }
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
        .onChange(of: channelListVisible) { _, visible in if visible { refreshChannelListOrder() } }
        .onChange(of: env.libraryVersion) { if channelListVisible { refreshChannelListOrder() } }
        #if os(iOS)
        .statusBarHidden()
        .gesture(DragGesture(minimumDistance: 40).onEnded { value in
            guard player.request?.isLive == true, abs(value.translation.height) > abs(value.translation.width) else { return }
            player.zap(by: value.translation.height < 0 ? 1 : -1)
        })
        #endif
        #if os(tvOS)
        .background {
            if isVOD {
                TVHoldSeek { direction, heldMs in
                    if !channelListVisible, !syncPanelVisible, !(overlayVisible && toolsActive) { tvSeek(direction, heldMs: heldMs) }
                }
            }
        }
        .focusable(!overlayVisible && !channelListVisible && !infoCardVisible && !syncPanelVisible)
        .focused($surfaceFocused)
        .onMoveCommand { direction in
            if syncPanelVisible { return }   // its rows handle ◀▶ themselves
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
                topFocus = .close
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
        .onPlayPauseCommand { togglePlayPause() }
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
        // Select on the picture (overlay hidden): VOD pauses/resumes like the TV app; live shows the info.
        .onTapGesture {
            guard !syncPanelVisible else { return }
            if isVOD { togglePlayPause() } else { showOverlay() }
        }
        .onExitCommand {
            // Back rules (SCREENS §2): close panel/menu first, then leave the player.
            if syncPanelVisible { closeSyncPanel() }
            else if infoCardVisible { hideInfoCard() }
            else if channelListVisible { channelListVisible = false }
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
                                if syncPanelVisible { closeSyncPanel() } else if overlayVisible { hideOverlay() } else { showOverlay() }
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

    // MARK: Overlay visibility

    private func showOverlay() {
        overlayVisible = true
        scheduleHide()
    }

    private func hideOverlay() {
        hideTask?.cancel()
        overlayVisible = false
        menuOpen = false   // a menu dismissed without a choice
        #if os(iOS)
        scrubFraction = nil   // a drag cut off by the hide never ends
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
        if toolsActive { return false }
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
        items += [.aspect, .resync]
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

    /// ◀▶: 10 s; held (`TVHoldSeek` repeats every 0.3 s) 30 s steps once held for 1 s.
    private func tvSeek(_ direction: Int, heldMs: Int64 = 0) {
        guard isVOD else { showOverlay(); return }
        player.seek(by: SeekAccelerator.step(direction: direction, heldMs: heldMs))
        showOverlay()
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
            .focused($topFocus, equals: .close)
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

    private var tools: some View {
        HStack(spacing: Theme.isTV ? 24 : 18) {
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
            #endif
            if !player.subtitleOptions.isEmpty {
                trackedMenu("captions.bubble", label: "player_subtitles") {
                    Button { player.selectSubtitle(nil); menuClosed() } label: { Label(L10n.t("off"), systemImage: player.selectedSubtitle == nil ? "checkmark" : "") }
                    ForEach(player.subtitleOptions) { option in
                        Button { player.selectSubtitle(option.id); menuClosed() } label: {
                            Label(option.name ?? L10n.t("unknown_track", String(option.id + 1)), systemImage: player.selectedSubtitle == option.id ? "checkmark" : "")
                        }
                    }
                }
                #if os(tvOS)
                .focused($topFocus, equals: .subtitles)
                #endif
            }
            trackedMenu("aspectratio", label: "player_aspect") {
                ForEach(AspectMode.allCases, id: \.self) { mode in
                    Button { env.player.aspect = mode; menuClosed() } label: { Label(L10n.t(mode.titleKey), systemImage: player.aspect == mode ? "checkmark" : "") }
                }
            }
            #if os(tvOS)
            .focused($topFocus, equals: .aspect)
            #endif
            // "Fix sync": reopen the stream (live edge / current position).
            Button { player.resync(); showOverlay() } label: { toolIcon("arrow.triangle.2.circlepath") }
                .accessibilityLabel(L10n.t("audio_sync_fix"))
                .accessibilityIdentifier("action_resync")
                #if os(tvOS)
                .focused($topFocus, equals: .resync)
                #endif
            if let target = favoriteTarget {
                FavoriteButton(target: target, minTapSize: Theme.isTV ? 0 : 36)
                    #if os(tvOS)
                    .focused($topFocus, equals: .favorite)
                    #endif
            }
            if player.request?.isLive == true {
                Button { channelListVisible = true } label: { toolIcon("list.bullet") }
                    .accessibilityLabel(L10n.t("action_channel_list"))
                    #if os(tvOS)
                    .focused($topFocus, equals: .channelList)
                    #endif
                if player.previousChannel != nil {
                    Button { player.switchToPreviousChannel() } label: { toolIcon("arrow.uturn.backward") }
                        .accessibilityLabel(L10n.t("player_previous_channel"))
                        #if os(tvOS)
                        .focused($topFocus, equals: .previous)
                        #endif
                }
            }
        }
        .font(Theme.headline)
        .foregroundStyle(.white)
        .buttonStyle(.borderless)
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

    /// Zap list with the favorite channels on top (spec §2: favorites always first) – computed when
    /// the list opens / favorites change, not on every render.
    private func refreshChannelListOrder() {
        let all = player.request?.channels ?? []
        let isFavorite: (Channel) -> Bool = { c in env.favoriteTarget(c).map { env.favorites.isFavorite($0.contentKey) } ?? false }
        channelListCache = all.filter(isFavorite) + all.filter { !isFavorite($0) }
    }

    private var channelListOrder: [Channel] { channelListCache.isEmpty ? (player.request?.channels ?? []) : channelListCache }

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

    private var channelList: some View {
        HStack {
            Spacer()
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(channelListOrder) { channel in
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
/// Press-and-hold ◀▶ on the Siri Remote: SwiftUI's `onMoveCommand` fires once per press (no
/// repeat while held), so long-press recognizers for the arrow presses on the window repeat the
/// step every 0.3 s while the button stays down (10 s, 30 s once held for 1 s). A short press
/// fails them and reaches `onMoveCommand` as usual. Also used by the audio delay stepper.
struct TVHoldSeek: UIViewRepresentable {
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

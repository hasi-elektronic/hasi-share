import AVFoundation
import IPTVCore
import IPTVKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Full-screen player with overlay (SCREENS §3.7).
struct PlayerView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    @State private var overlayVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var channelListVisible = false
    #if os(tvOS)
    @FocusState private var surfaceFocused: Bool
    #endif

    private var player: PlayerController { env.player }

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
                statusLayer
                #if os(iOS)
                // Faded, not removed: an audio/subtitle/aspect menu opened from the overlay must
                // survive the 3 s auto-hide (removing its source view would close the menu).
                overlay
                    .opacity(overlayVisible ? 1 : 0)
                    .allowsHitTesting(overlayVisible)
                    .accessibilityHidden(!overlayVisible)
                #else
                if overlayVisible { overlay.transition(.opacity) }
                #endif
            }
            if let target = player.zapTarget { zapCard(target) }
            if channelListVisible { channelList }
        }
        .animation(.easeInOut(duration: 0.18), value: overlayVisible)
        .persistentSystemOverlays(.hidden)
        .onAppear { showOverlay() }
        .onDisappear { hideTask?.cancel() }
        #if os(iOS)
        .statusBarHidden()
        .gesture(DragGesture(minimumDistance: 40).onEnded { value in
            guard player.request?.isLive == true, abs(value.translation.height) > abs(value.translation.width) else { return }
            player.zap(by: value.translation.height < 0 ? 1 : -1)
        })
        #endif
        #if os(tvOS)
        .focusable(!overlayVisible && !channelListVisible)
        .focused($surfaceFocused)
        .onMoveCommand { direction in
            switch direction {
            case .up: player.request?.isLive == true ? player.zap(by: -1) : showOverlay()
            case .down: player.request?.isLive == true ? player.zap(by: 1) : showOverlay()
            case .left: player.seek(by: -10); showOverlay()
            case .right: player.seek(by: 10); showOverlay()
            @unknown default: break
            }
        }
        .onPlayPauseCommand { player.togglePlayPause(); showOverlay() }
        .onTapGesture { showOverlay() }
        .onExitCommand {
            // Back rules (SCREENS §2): close panel/menu first, then leave the player.
            if channelListVisible { channelListVisible = false }
            else if overlayVisible { overlayVisible = false; surfaceFocused = true }
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
            // AVPlayer layer or VLCKit drawable, whichever engine plays this stream.
            EngineVideoSurface(engine: player.engine, aspect: player.aspect)
                .frame(width: size.width, height: size.height)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .ignoresSafeArea()
        #if os(iOS)
        // Tap on the picture toggles the overlay. Kept off the root view so taps on the overlay
        // tools (audio/subtitle/aspect menus) do not also toggle – and thereby close – it.
        .contentShape(Rectangle())
        .onTapGesture { overlayVisible ? (overlayVisible = false) : showOverlay() }
        #endif
        .accessibilityIdentifier("video_surface")
    }

    @ViewBuilder
    private var statusLayer: some View {
        switch player.phase {
        case .loading, .buffering:
            ProgressView().controlSize(.large).tint(.white)
        case .reconnecting(let attempt, let max):
            VStack(spacing: 10) {
                ProgressView().tint(.white)
                LText("player_reconnecting", String(attempt), String(max)).font(Theme.body).foregroundStyle(.white)
            }
            .padding(20).background(RoundedRectangle(cornerRadius: 12).fill(.black.opacity(0.6)))
        default:
            EmptyView()
        }
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

    private func showOverlay() {
        overlayVisible = true
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled, player.phase == .playing, !channelListVisible { overlayVisible = false }
            #if os(tvOS)
            if !overlayVisible { surfaceFocused = true }
            #endif
        }
    }

    // MARK: Overlay

    private var overlay: some View {
        VStack {
            HStack(alignment: .top, spacing: 16) {
                Button { router.closePlayer() } label: { Image(systemName: "xmark") }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityLabel(L10n.t("action_close"))
                    .accessibilityIdentifier("player_close")
                if let number = player.currentChannel?.number {
                    Text(String(number)).font(Theme.headline.monospacedDigit()).foregroundStyle(Theme.textSecondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(player.request?.title ?? "").font(Theme.headline).foregroundStyle(.white).lineLimit(1)
                    if let channel = player.currentChannel, let now = nowProgramme(channel) {
                        Text(now.title).font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
                Spacer()
                tools
            }
            Spacer()
            if player.resumedFromMs != nil, player.request?.isLive == false {
                HStack {
                    Button(L10n.t("action_play_from_start")) { player.restartFromBeginning() }.buttonStyle(SecondaryButtonStyle())
                    Spacer()
                }
            }
            bottomBar
        }
        .padding(.horizontal, Theme.safeH)
        .padding(.vertical, Theme.safeV)
        .background(
            LinearGradient(colors: [.black.opacity(0.7), .clear, .clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                #if os(iOS)
                .onTapGesture { overlayVisible = false }   // tap outside the controls hides the overlay
                #endif
        )
        #if os(tvOS)
        .focusSection()
        #endif
    }

    private func nowProgramme(_ channel: Channel) -> EpgProgram? {
        guard let epgId = channel.epgId else { return nil }
        return (try? env.epg.nowNext(sourceId: channel.sourceId, epgIds: [epgId], at: Date()))?[epgId.lowercased()]?.now
    }

    private var tools: some View {
        HStack(spacing: Theme.isTV ? 24 : 10) {
            if !player.audioOptions.isEmpty {
                Menu {
                    ForEach(player.audioOptions) { option in
                        Button { player.selectAudio(option.id); showOverlay() } label: {
                            Label(option.name ?? L10n.t("unknown_track", String(option.id + 1)), systemImage: player.selectedAudio == option.id ? "checkmark" : "")
                        }
                    }
                } label: { Image(systemName: "speaker.wave.2") }
                .accessibilityLabel(L10n.t("player_audio"))
            }
            if !player.subtitleOptions.isEmpty {
                Menu {
                    Button { player.selectSubtitle(nil); showOverlay() } label: { Label(L10n.t("off"), systemImage: player.selectedSubtitle == nil ? "checkmark" : "") }
                    ForEach(player.subtitleOptions) { option in
                        Button { player.selectSubtitle(option.id); showOverlay() } label: {
                            Label(option.name ?? L10n.t("unknown_track", String(option.id + 1)), systemImage: player.selectedSubtitle == option.id ? "checkmark" : "")
                        }
                    }
                } label: { Image(systemName: "captions.bubble") }
                .accessibilityLabel(L10n.t("player_subtitles"))
            }
            Menu {
                ForEach(AspectMode.allCases, id: \.self) { mode in
                    Button { env.player.aspect = mode; showOverlay() } label: { Label(L10n.t(mode.titleKey), systemImage: player.aspect == mode ? "checkmark" : "") }
                }
            } label: { Image(systemName: "aspectratio") }
            .accessibilityLabel(L10n.t("player_aspect"))
            if player.request?.isLive == true {
                Button { channelListVisible = true } label: { Image(systemName: "list.bullet") }
                    .accessibilityLabel(L10n.t("action_channel_list"))
                if player.previousChannel != nil {
                    Button { player.switchToPreviousChannel() } label: { Image(systemName: "arrow.uturn.backward") }
                        .accessibilityLabel(L10n.t("player_previous_channel"))
                }
            }
            if let request = player.request, let channel = player.currentChannel {
                let fav = env.isFavorite(sourceId: channel.sourceId, kind: .live, itemId: channel.id)
                Button {
                    env.toggleFavorite(sourceId: channel.sourceId, kind: .live, itemId: channel.id, title: request.title, posterUrl: channel.logoUrl)
                } label: { Image(systemName: fav ? "star.fill" : "star") }
                .accessibilityLabel(L10n.t(fav ? "action_remove_favorite" : "action_add_favorite"))
            }
        }
        .font(Theme.headline)
        .foregroundStyle(.white)
        .buttonStyle(.borderless)
    }

    private var bottomBar: some View {
        HStack(spacing: 16) {
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.phase == .playing ? "pause.fill" : "play.fill")
            }
            .buttonStyle(SecondaryButtonStyle())
            if player.request?.isLive == true {
                LiveBadge()
                if let channel = player.currentChannel, let now = nowProgramme(channel) {
                    ProgressBar(value: EpgSchedule.progress(of: now, at: Date()), color: Theme.live).frame(height: 5)
                    Text(env.timeFormatter.range(start: now.start, end: now.end)).font(Theme.caption.monospacedDigit()).foregroundStyle(.white)
                } else {
                    Spacer()
                }
            } else {
                Text(L10n.clock(player.currentTime)).font(Theme.caption.monospacedDigit()).foregroundStyle(.white)
                ProgressBar(value: player.duration > 0 ? player.currentTime / player.duration : 0).frame(height: 5)
                Text(L10n.clock(player.duration)).font(Theme.caption.monospacedDigit()).foregroundStyle(.white)
            }
        }
    }

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

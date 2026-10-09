# Performance & UX (Apple) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the iPhone/iPad + Apple TV app measurably fast (start, zap, lists), favorites one-tap, menus shallow, and audio sync user-fixable.

**Architecture:** Pure, unit-tested logic lives in `apple/IPTVKit` (PerfTrace, LiveStartTuning, ZapPrefetcher, QuickStartDecision, FavoritesController, AudioDelayStore) and is wired into the existing `PlayerController` / `AppEnvironment`; SwiftUI views in `apple/Shared/Views` and the VLC engine in `apple/Shared/Player` consume it. Normative docs (`docs/SCREENS.md`, `docs/ARCHITECTURE.md`, `spec/CONTRACT.md` §6.1) are updated in the same task as the behaviour.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI (iOS 17 / tvOS 17), AVFoundation, VLCKit 3.7.3 (`MobileVLCKit`/`TVVLCKit`), XCTest, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-10-06-performance-ux-design.md`

## Global Constraints

- Work only under `iptv-player/`. Commit after each task with a message ending in `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; push to `claude/iptv-player`.
- Swift 6 language mode, strict concurrency; never disable checks.
- UI strings only via `spec/strings.json` with **en + tr + de** for every new key, then `node spec/tools/gen-strings.mjs` (generator fails on missing de). Never hand-edit `Localizable.xcstrings`.
- Logs go through `SafeLog` (Redactor); never log stream URLs or credentials — PerfTrace logs durations only.
- tvOS: a Form/List row may hold only ONE focusable control.
- Do not build with `CODE_SIGNING_ALLOWED=NO` for runtime/UI tests (unsigned simulator builds can't use the Keychain). Project signing (ad-hoc) is correct.
- Budgets (verbatim from spec): cold start → last channel first frame ≤ 1.5 s; zap neighbour HLS ≤ 1.0 s p50 / ≤ 1.8 s p90; channel list open / FTS search with 50 000 channels ≤ 100 ms; now/next per visible page ≤ 20 ms; EPG scrolling 60 fps.
- Prefetch limits: ≤ 256 KB per neighbour, ≤ 2 concurrent, off on cellular / Low Data Mode.
- Audio delay range −2000…+2000 ms, 50 ms steps; effective delay ≠ 0 → VLCKit engine.
- Favorite order is device-local in v1 (sync contract unchanged).

### Verification commands (used by every task)
- `cd apple/IPTVKit && swift test` (and `cd apple/IPTVCore && swift test` if touched)
- `cd apple && xcodegen generate && xcodebuild -project NovaPlayer.xcodeproj -scheme NovaPlayer-iOS -destination 'generic/platform=iOS Simulator' build -quiet` and the same with `NovaPlayer-tvOS` / `'generic/platform=tvOS Simulator'`
- UI tests (tasks that touch UI): local media server first — `cd /private/tmp/claude-501/-Users-hguencavdi-hasi-share/1f2597b2-bac6-4b01-9cb5-597300a6fe3b/scratchpad/apple-www && python3 -m http.server 8765 --bind 127.0.0.1` (background, long timeout), then `TEST_RUNNER_SEED_M3U=http://localhost:8765/redesign/demo.m3u xcodebuild test -project NovaPlayer.xcodeproj -scheme NovaPlayer-iOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro'` and `-scheme NovaPlayer-tvOS -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)'`.
- VLC/VOD media server (Range-capable, needed by the VLCKit and player-control UI tests: `vlc-live.m3u`, `vlc-movie.m3u` MKV, `vod-movie.m3u` MP4 → AVPlayer; those tests `XCTSkip` without it): `cd /private/tmp/claude-501/-Users-hguencavdi-hasi-share/1f2597b2-bac6-4b01-9cb5-597300a6fe3b/scratchpad/vlc-www && python3 ../range_server.py 8766` (background, long timeout; check `lsof -iTCP:8766 -sTCP:LISTEN`). Start it together with the 8765 server before any UI suite run.

---

## Phase 1 — Speed

### Task 1: PerfTrace + performance overlay

**Files:**
- Create: `apple/IPTVKit/Sources/IPTVKit/Support/PerfTrace.swift`
- Create: `apple/IPTVKit/Tests/IPTVKitTests/PerfTraceTests.swift`
- Modify: `apple/IPTVKit/Sources/IPTVKit/Player/PlayerController.swift` (mark `playRequested` in `open`, `firstFrame` on first `.playing`)
- Modify: `apple/IPTVKit/Sources/IPTVKit/Support/AppSettings.swift` (add `showPerfOverlay: Bool`, key `pref.perfOverlay`, default false)
- Create: `apple/Shared/Views/PerfOverlayView.swift`; Modify: `apple/Shared/Views/PlayerView.swift` (overlay when setting on); Modify: `apple/Shared/Views/SettingsView.swift` (Diagnostics toggle)
- Modify: `spec/strings.json` keys `perf_overlay`, `perf_zap`, `perf_engine`, `perf_buffer`, `perf_bitrate`, `perf_dropped`

**Interfaces:**
- Produces:
```swift
public enum PerfMark: String, Sendable { case appLaunch, playRequested, firstFrame }
@MainActor public final class PerfTrace {
    public static let shared: PerfTrace
    public init(clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds })
    public func mark(_ m: PerfMark)
    /// ms between two marks of the current play attempt (nil if missing)
    public func interval(from: PerfMark, to: PerfMark) -> Double?
    public private(set) var lastZapMs: Double?        // playRequested → firstFrame
    public private(set) var lastColdStartMs: Double?  // appLaunch → first firstFrame after launch
    public private(set) var zapSamples: [Double]      // last 50
    public func percentile(_ p: Double) -> Double?   // over zapSamples
}
```

- [ ] **Step 1: Write the failing test** (`PerfTraceTests.swift`)
```swift
import XCTest
@testable import IPTVKit

@MainActor
final class PerfTraceTests: XCTestCase {
    func testZapAndColdStartIntervals() {
        var now: UInt64 = 0
        let t = PerfTrace(clock: { now })
        t.mark(.appLaunch)
        now = 200_000_000; t.mark(.playRequested)
        now = 1_100_000_000; t.mark(.firstFrame)
        XCTAssertEqual(t.lastColdStartMs, 1100, accuracy: 0.01)
        XCTAssertEqual(t.lastZapMs, 900, accuracy: 0.01)
        now = 2_000_000_000; t.mark(.playRequested)
        now = 2_500_000_000; t.mark(.firstFrame)
        XCTAssertEqual(t.lastZapMs, 500, accuracy: 0.01)
        XCTAssertEqual(t.lastColdStartMs, 1100, accuracy: 0.01, "cold start only counts the first frame after launch")
        XCTAssertEqual(t.zapSamples, [900, 500])
        XCTAssertEqual(t.percentile(0.5), 500)
    }

    func testFirstFrameWithoutRequestIsIgnored() {
        var now: UInt64 = 0
        let t = PerfTrace(clock: { now })
        now = 10; t.mark(.firstFrame)
        XCTAssertNil(t.lastZapMs)
    }
}
```
- [ ] **Step 2: Run** `cd apple/IPTVKit && swift test --filter PerfTraceTests` → FAIL (`PerfTrace` undefined).
- [ ] **Step 3: Implement** `PerfTrace.swift`
```swift
import Foundation

public enum PerfMark: String, Sendable { case appLaunch, playRequested, firstFrame }

/// Lightweight timing marks for the performance budgets (spec §1). Durations only – no URLs.
@MainActor
public final class PerfTrace {
    public static let shared = PerfTrace()
    private let clock: @Sendable () -> UInt64
    private var marks: [PerfMark: UInt64] = [:]
    private var coldStartDone = false
    public private(set) var lastZapMs: Double?
    public private(set) var lastColdStartMs: Double?
    public private(set) var zapSamples: [Double] = []

    public init(clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) { self.clock = clock }

    public func mark(_ m: PerfMark) {
        let now = clock()
        switch m {
        case .appLaunch, .playRequested:
            marks[m] = now
            if m == .playRequested { marks[.firstFrame] = nil }
        case .firstFrame:
            guard let req = marks[.playRequested], marks[.firstFrame] == nil else { return }
            marks[.firstFrame] = now
            let zap = Double(now - req) / 1_000_000
            lastZapMs = zap
            zapSamples.append(zap); if zapSamples.count > 50 { zapSamples.removeFirst() }
            if !coldStartDone, let launch = marks[.appLaunch] {
                lastColdStartMs = Double(now - launch) / 1_000_000
                coldStartDone = true
                SafeLog.info("perf coldStartMs=\(Int(lastColdStartMs!))")
            }
            SafeLog.info("perf zapMs=\(Int(zap))")
        }
    }

    public func interval(from a: PerfMark, to b: PerfMark) -> Double? {
        guard let x = marks[a], let y = marks[b], y >= x else { return nil }
        return Double(y - x) / 1_000_000
    }

    public func percentile(_ p: Double) -> Double? {
        guard !zapSamples.isEmpty else { return nil }
        let s = zapSamples.sorted()
        let idx = min(s.count - 1, max(0, Int((Double(s.count) * p).rounded(.up)) - 1))
        return s[idx]
    }
}
```
- [ ] **Step 4: Run** the filter again → PASS.
- [ ] **Step 5: Wire it**: in `PlayerController.open(_:)` right after `phase = .loading` add `PerfTrace.shared.mark(.playRequested)`; in `handle(_:)` `case .playing:` add `PerfTrace.shared.mark(.firstFrame)` (idempotent per attempt). In both app entry points (`Apps/iOS/NovaPlayerApp.swift`, `Apps/tvOS/NovaPlayerTVApp.swift`) call `PerfTrace.shared.mark(.appLaunch)` in `init()`. Add `showPerfOverlay` to `AppSettings`, a "Performans katmanı" toggle under Settings → Diagnostics, and `PerfOverlayView` (top-left monospaced 12pt on iOS / 22pt on tvOS, black 60 % background) showing: engine (`player.engineKind`), last zap ms + p50/p90, buffer state (`player.phase`), and — for AVPlayer — indicated bitrate and dropped frames read from `AVPlayerItem.accessLog().events.last` (`indicatedBitrate`, `numberOfDroppedVideoFrames`); for VLC show "—". Expose those two values through a new `PlaybackEngine` requirement `var diagnostics: EngineDiagnostics { get }` with `public struct EngineDiagnostics: Sendable, Equatable { public var bitrate: Double?; public var droppedFrames: Int?; public var resolution: String?; public init(...) }` — AVPlayerEngine fills from access log / `presentationSize`, VLC engine returns `VLCMedia.statistics` (`demuxBitrate*8_000_000`, `lostPictures`) and fake engines in tests return `.init()`. Add the strings (en/tr/de) and run gen-strings.
- [ ] **Step 6: Verify** IPTVKit tests + iOS/tvOS builds (commands above).
- [ ] **Step 7: Commit** `perf: PerfTrace marks + diagnostics overlay`

### Task 2: Live start tuning (faster first frame)

**Files:**
- Create: `apple/IPTVKit/Sources/IPTVKit/Player/LiveStartTuning.swift`
- Test: `apple/IPTVKit/Tests/IPTVKitTests/LiveStartTuningTests.swift`
- Modify: `apple/IPTVKit/Sources/IPTVKit/Player/AVPlayerEngine.swift`, `apple/Shared/Player/VLCPlaybackEngine.swift`, `apple/IPTVKit/Sources/IPTVKit/Player/PlaybackEngine.swift` (pass tuning), `PlayerController.swift` (build tuning from `largeBuffer`)
- Modify: `docs/ARCHITECTURE.md` §3.2 + §7 (live start values)

**Interfaces:**
- Produces:
```swift
public struct LiveStartTuning: Sendable, Equatable {
    public var forwardBufferSeconds: Double      // AVPlayer preferredForwardBufferDuration
    public var waitToMinimizeStallingAfter: Double // seconds after first frame to re-enable automaticallyWaitsToMinimizeStalling
    public var initialPeakBitRate: Double?       // bps cap for the first variant
    public var peakBitRateReleaseAfter: Double   // seconds after first frame to remove the cap
    public var vlcNetworkCachingMs: Int
    public static func make(isLive: Bool, largeBuffer: Bool) -> LiveStartTuning
}
```
- `PlaybackEngine.load(...)` gains a trailing parameter `tuning: LiveStartTuning`.

- [ ] **Step 1: Failing test**
```swift
import XCTest
@testable import IPTVKit
final class LiveStartTuningTests: XCTestCase {
    func testLiveDefaults() {
        let t = LiveStartTuning.make(isLive: true, largeBuffer: false)
        XCTAssertEqual(t.forwardBufferSeconds, 1)
        XCTAssertEqual(t.waitToMinimizeStallingAfter, 3)
        XCTAssertEqual(t.initialPeakBitRate, 2_500_000)
        XCTAssertEqual(t.peakBitRateReleaseAfter, 4)
        XCTAssertEqual(t.vlcNetworkCachingMs, 1000)
    }
    func testLargeBufferAndVOD() {
        XCTAssertEqual(LiveStartTuning.make(isLive: true, largeBuffer: true).vlcNetworkCachingMs, 3000)
        XCTAssertNil(LiveStartTuning.make(isLive: true, largeBuffer: true).initialPeakBitRate)
        let vod = LiveStartTuning.make(isLive: false, largeBuffer: false)
        XCTAssertEqual(vod.forwardBufferSeconds, 0)
        XCTAssertNil(vod.initialPeakBitRate)
        XCTAssertEqual(vod.vlcNetworkCachingMs, 2000)
    }
}
```
- [ ] **Step 2:** run → FAIL.
- [ ] **Step 3: Implement**
```swift
public struct LiveStartTuning: Sendable, Equatable {
    public var forwardBufferSeconds: Double
    public var waitToMinimizeStallingAfter: Double
    public var initialPeakBitRate: Double?
    public var peakBitRateReleaseAfter: Double
    public var vlcNetworkCachingMs: Int

    public static func make(isLive: Bool, largeBuffer: Bool) -> LiveStartTuning {
        if !isLive {
            return .init(forwardBufferSeconds: 0, waitToMinimizeStallingAfter: 0, initialPeakBitRate: nil,
                         peakBitRateReleaseAfter: 0, vlcNetworkCachingMs: largeBuffer ? 4000 : 2000)
        }
        if largeBuffer {
            return .init(forwardBufferSeconds: 6, waitToMinimizeStallingAfter: 0, initialPeakBitRate: nil,
                         peakBitRateReleaseAfter: 0, vlcNetworkCachingMs: 3000)
        }
        return .init(forwardBufferSeconds: 1, waitToMinimizeStallingAfter: 3, initialPeakBitRate: 2_500_000,
                     peakBitRateReleaseAfter: 4, vlcNetworkCachingMs: 1000)
    }
}
```
- [ ] **Step 4:** run → PASS.
- [ ] **Step 5: Apply in engines.** AVPlayerEngine `load`: `item.preferredForwardBufferDuration = tuning.forwardBufferSeconds`; `player.automaticallyWaitsToMinimizeStalling = tuning.waitToMinimizeStallingAfter == 0`; `if let cap = tuning.initialPeakBitRate { item.preferredPeakBitRate = cap }`; on first `.playing` schedule `Task { try? await Task.sleep(for: .seconds(...)); item.preferredPeakBitRate = 0; player.automaticallyWaitsToMinimizeStalling = true }` (cancel on next load/stop). VLC engine: replace the hardcoded `":network-caching=1500"/"2000"` with `":network-caching=\(tuning.vlcNetworkCachingMs)"`. PlayerController passes `LiveStartTuning.make(isLive:largeBuffer:)` (add `public var largeBuffer = false` on PlayerController, set from `AppSettings.largeBuffer` where the controller is created in `AppEnvironment`). Update fake engines in tests to the new signature. Update ARCHITECTURE §3.2/§7 with the values.
- [ ] **Step 6:** IPTVKit tests + iOS/tvOS builds + iOS UI tests (VLC + flow) green.
- [ ] **Step 7: Commit** `perf: faster live start (small initial buffer, capped first variant)`

### Task 3: ZapPrefetcher (neighbour channel warm-up)

**Files:**
- Create: `apple/IPTVKit/Sources/IPTVKit/Player/ZapPrefetcher.swift`
- Test: `apple/IPTVKit/Tests/IPTVKitTests/ZapPrefetcherTests.swift`
- Modify: `PlayerController.swift` (after first frame of a live channel: prefetch neighbours; on zap: use cached resolution)
- Modify: `docs/ARCHITECTURE.md` §7 (prefetch rule)

**Interfaces:**
- Produces:
```swift
public protocol PrefetchFetcher: Sendable {
    /// Fetches at most `maxBytes` of `url` (GET with Range); returns bytes read.
    func fetch(_ url: URL, headers: [String: String], maxBytes: Int) async throws -> Int
}
public protocol NetworkConditions: Sendable { var isExpensiveOrConstrained: Bool { get } }
@MainActor public final class ZapPrefetcher {
    public init(resolver: @escaping @MainActor (PlaybackRequest) async throws -> ResolvedStream,
                fetcher: any PrefetchFetcher, network: any NetworkConditions,
                maxBytes: Int = 262_144, maxConcurrent: Int = 2)
    /// Neighbours of `current` in `channels` (previous, next; wraps around).
    public static func neighbours(of current: Channel, in channels: [Channel]) -> [Channel]
    public func prefetch(around current: Channel, request: PlaybackRequest)
    /// Cached resolution for a channel id (consumed once), nil if none.
    public func takeResolved(channelId: String) -> ResolvedStream?
    public func cancelAll()
}
```
- Consumes: `PlaybackRequest` (fields `item`, `source`, `channels`), `ResolvedStream` (`url`, `container`, `headers`, `engine`).

- [ ] **Step 1: Failing tests**
```swift
import XCTest
@testable import IPTVKit
import IPTVCore

private final class CountingFetcher: PrefetchFetcher, @unchecked Sendable {
    let lock = NSLock(); var urls: [URL] = []; var maxBytesSeen: [Int] = []; var inFlight = 0; var peak = 0
    func fetch(_ url: URL, headers: [String: String], maxBytes: Int) async throws -> Int {
        lock.withLock { urls.append(url); maxBytesSeen.append(maxBytes); inFlight += 1; peak = max(peak, inFlight) }
        try await Task.sleep(for: .milliseconds(20))
        lock.withLock { inFlight -= 1 }
        return maxBytes
    }
}
private struct Net: NetworkConditions { var isExpensiveOrConstrained: Bool }

@MainActor
final class ZapPrefetcherTests: XCTestCase {
    func channels(_ n: Int) -> [Channel] { (0..<n).map { TestData.channel(id: "c\($0)") } }

    func testNeighboursWrapAround() {
        let list = channels(3)
        XCTAssertEqual(ZapPrefetcher.neighbours(of: list[0], in: list).map(\.id), ["c2", "c1"])
        XCTAssertEqual(ZapPrefetcher.neighbours(of: list[1], in: list).map(\.id), ["c0", "c2"])
        XCTAssertEqual(ZapPrefetcher.neighbours(of: list[0], in: [list[0]]).map(\.id), [])
    }

    func testPrefetchResolvesAndFetchesWithinLimits() async throws {
        let list = channels(5)
        let fetcher = CountingFetcher()
        let p = ZapPrefetcher(resolver: { req in
            guard case .channel(let c) = req.item else { throw CancellationError() }
            return ResolvedStream(url: URL(string: "http://h/\(c.id).m3u8")!, container: .hls, headers: [:])
        }, fetcher: fetcher, network: Net(isExpensiveOrConstrained: false))
        p.prefetch(around: list[2], request: PlaybackRequest(item: .channel(list[2]), source: nil, channels: list))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(Set(fetcher.urls.map(\.lastPathComponent)), ["c1.m3u8", "c3.m3u8"])
        XCTAssertTrue(fetcher.maxBytesSeen.allSatisfy { $0 <= 262_144 })
        XCTAssertLessThanOrEqual(fetcher.peak, 2)
        XCTAssertEqual(p.takeResolved(channelId: "c3")?.url.lastPathComponent, "c3.m3u8")
        XCTAssertNil(p.takeResolved(channelId: "c3"), "consumed once")
    }

    func testDisabledOnExpensiveNetwork() async throws {
        let list = channels(3); let fetcher = CountingFetcher()
        let p = ZapPrefetcher(resolver: { _ in ResolvedStream(url: URL(string: "http://h/x")!, container: .hls, headers: [:]) },
                              fetcher: fetcher, network: Net(isExpensiveOrConstrained: true))
        p.prefetch(around: list[1], request: PlaybackRequest(item: .channel(list[1]), source: nil, channels: list))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(fetcher.urls.isEmpty)
        XCTAssertNil(p.takeResolved(channelId: "c2"))
    }
}
```
Note: if `TestData.channel(id:)` or the `PlaybackRequest(item:source:channels:)` initializer differ in `TestSupport.swift` / `StreamResolver.swift`, add a small helper in `TestSupport.swift` building a `Channel` with the given id (all other fields default) — check the real initializer first and use it.
- [ ] **Step 2:** run → FAIL.
- [ ] **Step 3: Implement** `ZapPrefetcher.swift`
```swift
import Foundation
import IPTVCore
#if canImport(Network)
import Network
#endif

public protocol PrefetchFetcher: Sendable {
    func fetch(_ url: URL, headers: [String: String], maxBytes: Int) async throws -> Int
}
public protocol NetworkConditions: Sendable { var isExpensiveOrConstrained: Bool { get } }

/// Warms neighbour channels while a live channel plays (spec §1): resolves their stream URL
/// and pre-reads ≤ maxBytes (manifest / first bytes) so DNS, TCP/TLS and the playlist are hot.
@MainActor
public final class ZapPrefetcher {
    private let resolver: @MainActor (PlaybackRequest) async throws -> ResolvedStream
    private let fetcher: any PrefetchFetcher
    private let network: any NetworkConditions
    private let maxBytes: Int
    private let maxConcurrent: Int
    private var resolved: [String: ResolvedStream] = [:]
    private var tasks: [Task<Void, Never>] = []

    public init(resolver: @escaping @MainActor (PlaybackRequest) async throws -> ResolvedStream,
                fetcher: any PrefetchFetcher, network: any NetworkConditions,
                maxBytes: Int = 262_144, maxConcurrent: Int = 2) {
        self.resolver = resolver; self.fetcher = fetcher; self.network = network
        self.maxBytes = maxBytes; self.maxConcurrent = max(1, maxConcurrent)
    }

    public static func neighbours(of current: Channel, in channels: [Channel]) -> [Channel] {
        guard channels.count > 1, let i = channels.firstIndex(where: { $0.id == current.id }) else { return [] }
        let prev = channels[(i - 1 + channels.count) % channels.count]
        let next = channels[(i + 1) % channels.count]
        return prev.id == next.id ? [prev] : [prev, next]
    }

    public func prefetch(around current: Channel, request: PlaybackRequest) {
        cancelAll()
        guard !network.isExpensiveOrConstrained else { return }
        let targets = Self.neighbours(of: current, in: request.channels).prefix(maxConcurrent)
        for channel in targets {
            var req = request
            req.item = .channel(channel)
            let maxBytes = self.maxBytes, fetcher = self.fetcher
            tasks.append(Task { [weak self] in
                guard let self, let stream = try? await self.resolver(req), !Task.isCancelled else { return }
                self.resolved[channel.id] = stream
                _ = try? await fetcher.fetch(stream.url, headers: stream.headers, maxBytes: maxBytes)
            })
        }
    }

    public func takeResolved(channelId: String) -> ResolvedStream? { resolved.removeValue(forKey: channelId) }

    public func cancelAll() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        resolved.removeAll()
    }
}

/// URLSession-backed fetcher: Range GET, stops after maxBytes.
public struct URLSessionPrefetchFetcher: PrefetchFetcher {
    public init() {}
    public func fetch(_ url: URL, headers: [String: String], maxBytes: Int) async throws -> Int {
        var request = URLRequest(url: url, timeoutInterval: 5)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.setValue("bytes=0-\(maxBytes - 1)", forHTTPHeaderField: "Range")
        let (bytes, _) = try await URLSession.shared.bytes(for: request)
        var n = 0
        for try await _ in bytes { n += 1; if n >= maxBytes { break } }
        return n
    }
}

#if canImport(Network)
/// Reads NWPathMonitor; expensive (cellular/hotspot) or constrained (Low Data Mode) → no prefetch.
public final class PathNetworkConditions: NetworkConditions, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var flag = false
    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.lock.withLock { self?.flag = path.isExpensive || path.isConstrained }
        }
        monitor.start(queue: DispatchQueue(label: "prefetch.path"))
    }
    public var isExpensiveOrConstrained: Bool { lock.withLock { flag } }
}
#endif
```
- [ ] **Step 4:** run → PASS.
- [ ] **Step 5: Wire into PlayerController.** Add an optional `prefetcher: ZapPrefetcher?` (created in `AppEnvironment` with `resolver: { try await resolver.resolve($0) }`, `URLSessionPrefetchFetcher()`, `PathNetworkConditions()`). In `handle(.playing)` for a live channel request → `prefetcher?.prefetch(around: channel, request: request)`. In `open(_:)` for `.channel(c)`: `if let cached = prefetcher?.takeResolved(channelId: c.id) { self.stream = cached; load(cached, ...) }` skipping `resolver.resolve` (keep the rest of the open flow identical). `stopPlayback()` / release → `prefetcher?.cancelAll()`. Add a PlayerController unit test with a fake engine verifying the cached stream is used without calling the resolver a second time (count resolver calls). ARCHITECTURE §7: document limits.
- [ ] **Step 6:** IPTVKit tests + builds + iOS/tvOS UI tests.
- [ ] **Step 7: Commit** `perf: neighbour channel prefetch for sub-second zapping`

### Task 4: QuickStart (instant last channel on launch)

**Files:**
- Create: `apple/IPTVKit/Sources/IPTVKit/Player/QuickStart.swift`; Test: `apple/IPTVKit/Tests/IPTVKitTests/QuickStartTests.swift`
- Modify: `AppSettings.swift` (`quickStart: Bool`, key `pref.quickStart`, default true; `lastSession: LastSession?` JSON key `state.lastSession`)
- Modify: `PlayerController.swift` (record `LastSession` when a live channel plays, clear when VOD plays or the user exits the player via Back/close)
- Modify: `apple/Shared/Support/AppBootstrap.swift` / app entry (on launch, after environment is ready and BEFORE awaiting any source refresh, if decision says play → `router.play(.channel(channel), channels: page)`)
- Modify: `SettingsView.swift` (toggle "Hızlı başlat" in top settings group), `spec/strings.json` key `settings_quick_start` (+ `_hint`)
- Modify: `docs/SCREENS.md` §3.2 (QuickStart rule)

**Interfaces:**
```swift
public struct LastSession: Codable, Sendable, Equatable {
    public var sourceId: String; public var channelId: String; public var endedInPlayer: Bool
}
public enum QuickStartDecision: Equatable { case none, play(sourceId: String, channelId: String) }
public enum QuickStart {
    public static func decide(enabled: Bool, last: LastSession?, canPlay: Bool, channelExists: Bool) -> QuickStartDecision
}
```
- [ ] **Step 1: Failing test**
```swift
import XCTest
@testable import IPTVKit
final class QuickStartTests: XCTestCase {
    let s = LastSession(sourceId: "s", channelId: "c", endedInPlayer: true)
    func testPlaysLastChannelWhenAllowed() {
        XCTAssertEqual(QuickStart.decide(enabled: true, last: s, canPlay: true, channelExists: true), .play(sourceId: "s", channelId: "c"))
    }
    func testNoneCases() {
        XCTAssertEqual(QuickStart.decide(enabled: false, last: s, canPlay: true, channelExists: true), .none)
        XCTAssertEqual(QuickStart.decide(enabled: true, last: nil, canPlay: true, channelExists: true), .none)
        XCTAssertEqual(QuickStart.decide(enabled: true, last: s, canPlay: false, channelExists: true), .none)
        XCTAssertEqual(QuickStart.decide(enabled: true, last: s, canPlay: true, channelExists: false), .none)
        var left = s; left.endedInPlayer = false
        XCTAssertEqual(QuickStart.decide(enabled: true, last: left, canPlay: true, channelExists: true), .none)
    }
}
```
- [ ] **Step 2:** run → FAIL. **Step 3:** implement:
```swift
public struct LastSession: Codable, Sendable, Equatable {
    public var sourceId: String
    public var channelId: String
    /// true if the app went to background/terminated while this live channel was playing
    public var endedInPlayer: Bool
    public init(sourceId: String, channelId: String, endedInPlayer: Bool) {
        self.sourceId = sourceId; self.channelId = channelId; self.endedInPlayer = endedInPlayer
    }
}
public enum QuickStartDecision: Equatable { case none, play(sourceId: String, channelId: String) }
public enum QuickStart {
    public static func decide(enabled: Bool, last: LastSession?, canPlay: Bool, channelExists: Bool) -> QuickStartDecision {
        guard enabled, let last, last.endedInPlayer, canPlay, channelExists else { return .none }
        return .play(sourceId: last.sourceId, channelId: last.channelId)
    }
}
```
- [ ] **Step 4:** run → PASS. **Step 5:** wire: PlayerController writes `LastSession(endedInPlayer: true)` on live `.playing`, sets `endedInPlayer = false` when the user closes the player (explicit close/back), leaves it `true` on scenePhase background release. App launch: read setting + last session, look up the channel via `catalog.channel(sourceId:id:)`, check `license.canPlay`, then open the player with the channel and `catalog.channels(sourceId:categoryId:limit:200)` of its category for zapping. Strings en/tr/de. SCREENS §3.2.
- [ ] **Step 6:** add iOS UI test `testQuickStartReopensLastChannel` (persistent mode: add source, play first channel, `XCUIDevice.shared.press(.home)`, `app.terminate()`, relaunch without `-uiTestReset`, assert `video_surface` exists within 5 s). Verify all.
- [ ] **Step 7: Commit** `perf: quick start resumes the last live channel instantly`

### Task 5: List/search/EPG performance budgets at 50 000 channels

**Files:**
- Test: `apple/IPTVKit/Tests/IPTVKitTests/CatalogPerformanceTests.swift`
- Modify (only if a budget fails): `apple/IPTVKit/Sources/IPTVKit/Repositories/CatalogRepository.swift`, `EpgRepository` (or wherever now/next is queried), `apple/IPTVKit/Sources/IPTVKit/Database/*` (indices), image cache in `apple/Shared` / IPTVKit (downsampling)

**Interfaces:** consumes `CatalogRepository.channels(sourceId:categoryId:offset:limit:)`, `search(_:sourceId:limit:)`, `beginRefresh(sourceId:)`/`write(categories:channels:...)`/`commit()`, and the EPG now/next query used by the live grid (find it: `grep -rn "nowNext\|now(" IPTVKit/Sources`).

- [ ] **Step 1: Write the budget tests** (fail if over budget; use wall clock, 5 runs, take median, generous only on debug overhead ×1.0 — budgets are for release, debug tests use 2× budget):
```swift
import XCTest
@testable import IPTVKit
import IPTVCore

final class CatalogPerformanceTests: XCTestCase {
    static let n = 50_000
    func makeCatalog() throws -> CatalogRepository {
        let db = try AppDatabase.inMemory()
        let repo = CatalogRepository(database: db)
        let session = try repo.beginRefresh(sourceId: "s")
        let cats = (0..<50).map { IPTVCore.Category(sourceId: "s", id: "k\($0)", name: "Kategorie \($0)", kind: .live, sort: $0) }
        try session.write(categories: cats, channels: (0..<Self.n).map {
            TestData.channel(id: "c\($0)", name: "Kanal \($0) \(["Sport", "News", "Kids", "Film"][$0 % 4]) HD", categoryId: "k\($0 % 50)", sort: $0)
        })
        try session.commit()
        return repo
    }
    func median(_ block: () throws -> Void) rethrows -> Double {
        var t: [Double] = []
        for _ in 0..<5 { let s = DispatchTime.now(); try block(); t.append(Double(DispatchTime.now().uptimeNanoseconds - s.uptimeNanoseconds) / 1e6) }
        return t.sorted()[2]
    }
    #if DEBUG
    let factor = 2.0
    #else
    let factor = 1.0
    #endif
    func testListPageUnderBudget() throws {
        let repo = try makeCatalog()
        let ms = try median { _ = try repo.channels(sourceId: "s", categoryId: "k7", offset: 0, limit: 100) }
        XCTAssertLessThan(ms, 100 * factor, "list page \(ms) ms")
    }
    func testSearchUnderBudget() throws {
        let repo = try makeCatalog()
        let ms = try median { _ = try repo.search("sport", sourceId: "s", limit: 60) }
        XCTAssertLessThan(ms, 100 * factor, "search \(ms) ms")
    }
}
```
(Adapt `IPTVCore.Category(...)` / `TestData.channel(...)` to the real initializers — read `Content.swift` and `TestSupport.swift`; extend `TestData.channel` with `name`, `categoryId`, `sort` parameters if missing.) Add a third test for the EPG now/next query over the first 100 channels with 5 programmes each (budget 20 ms).
- [ ] **Step 2:** run `swift test --filter CatalogPerformanceTests`. If a budget fails: run `EXPLAIN QUERY PLAN` on the offending SQL (print via a temporary test), add the missing index (e.g. `CREATE INDEX IF NOT EXISTS idx_channels_src_cat_sort ON channels(source_id, category_id, sort)`; EPG `(source_id, channel_epg_id, start)`), as a new migration step in the database schema list, and re-run until green.
- [ ] **Step 3: Image downsampling check.** Find the image loader (`grep -rn "NSCache\|URLCache" apple`). If images are decoded at full size, change decoding to `CGImageSourceCreateThumbnailAtIndex` with `kCGImageSourceThumbnailMaxPixelSize = targetPoints * displayScale` and cache the downsampled image keyed by `url+size`; cancel the load task in `onDisappear`. Add a unit test that a 2000×2000 PNG decoded for a 100-pt target yields ≤ 300 px.
- [ ] **Step 4: Verify** all tests + builds. **Step 5: Commit** `perf: 50k-channel budgets enforced by tests (+ indices/downsampling)`

## Phase 2 — One-tap favorites

### Task 6: FavoritesController (optimistic toggle + undo + local order)

**Files:**
- Create: `apple/IPTVKit/Sources/IPTVKit/Repositories/FavoritesController.swift`; Test: `apple/IPTVKit/Tests/IPTVKitTests/FavoritesControllerTests.swift`
- Modify: `AppEnvironment.swift` (expose `favorites: FavoritesController`)

**Interfaces:**
- Consumes: `LibraryRepository.setFavorite(_:contentKey:title:kind:posterUrl:nowMs:)`, `isFavorite(contentKey:)`, `favorites(kind:)`; `KeyValueStore`.
- Produces:
```swift
public struct FavoriteTarget: Sendable, Hashable {
    public var contentKey: String; public var title: String; public var kind: ContentKind; public var posterUrl: String?
    public init(contentKey: String, title: String, kind: ContentKind, posterUrl: String?)
}
@MainActor @Observable public final class FavoritesController {
    public init(library: LibraryRepository, kv: any KeyValueStore, now: @escaping () -> Int64, onChange: @escaping @MainActor () -> Void = {})
    public func isFavorite(_ contentKey: String) -> Bool          // O(1), cached set
    @discardableResult public func toggle(_ t: FavoriteTarget) -> Bool   // returns new state; sets pendingUndo
    public private(set) var pendingUndo: FavoriteTarget?          // cleared after 4 s or on undo
    public func undo()
    public func orderedKeys(kind: ContentKind) -> [String]        // local order first, then newest-first remainder
    public func move(kind: ContentKind, from: IndexSet, to: Int)
    public private(set) var favoriteCategoryIds: Set<String>      // per-device (key "fav.categories")
    public func toggleCategory(_ id: String)
}
```
- [ ] **Step 1: Failing tests**
```swift
import XCTest
@testable import IPTVKit
import IPTVCore

@MainActor
final class FavoritesControllerTests: XCTestCase {
    func make() throws -> FavoritesController {
        let lib = LibraryRepository(database: try AppDatabase.inMemory())
        var t: Int64 = 1_000
        return FavoritesController(library: lib, kv: InMemoryKeyValueStore(), now: { t += 1; return t })
    }
    let a = FavoriteTarget(contentKey: "ch:a", title: "A", kind: .channel, posterUrl: nil)
    let b = FavoriteTarget(contentKey: "ch:b", title: "B", kind: .channel, posterUrl: nil)

    func testToggleIsImmediateAndUndoable() throws {
        let f = try make()
        XCTAssertTrue(f.toggle(a))
        XCTAssertTrue(f.isFavorite("ch:a"))
        XCTAssertEqual(f.pendingUndo, a)
        f.undo()
        XCTAssertFalse(f.isFavorite("ch:a"))
        XCTAssertNil(f.pendingUndo)
    }
    func testLocalOrderPersistsAndNewestFirstForRest() throws {
        let f = try make()
        f.toggle(a); f.toggle(b)
        XCTAssertEqual(f.orderedKeys(kind: .channel), ["ch:b", "ch:a"])
        f.move(kind: .channel, from: IndexSet(integer: 1), to: 0)
        XCTAssertEqual(f.orderedKeys(kind: .channel), ["ch:a", "ch:b"])
    }
    func testFavoriteCategories() throws {
        let f = try make()
        f.toggleCategory("k1"); XCTAssertEqual(f.favoriteCategoryIds, ["k1"])
        f.toggleCategory("k1"); XCTAssertTrue(f.favoriteCategoryIds.isEmpty)
    }
}
```
(Use the real `ContentKind` case names — check `IPTVCore` `ContentKind`; use `InMemoryKeyValueStore` from IPTVKit tests/support.)
- [ ] **Step 2:** run → FAIL. **Step 3: Implement**
```swift
import Foundation
import IPTVCore
import Observation

public struct FavoriteTarget: Sendable, Hashable {
    public var contentKey: String
    public var title: String
    public var kind: ContentKind
    public var posterUrl: String?
    public init(contentKey: String, title: String, kind: ContentKind, posterUrl: String?) {
        self.contentKey = contentKey; self.title = title; self.kind = kind; self.posterUrl = posterUrl
    }
}

/// One-tap favorites (spec §2): in-memory set for O(1) lookups, optimistic toggle, 4 s undo,
/// device-local manual order and favorite categories.
@MainActor
@Observable
public final class FavoritesController {
    @ObservationIgnored private let library: LibraryRepository
    @ObservationIgnored private let kv: any KeyValueStore
    @ObservationIgnored private let now: () -> Int64
    @ObservationIgnored private let onChange: @MainActor () -> Void
    @ObservationIgnored private var undoTask: Task<Void, Never>?
    private var keys: Set<String>
    public private(set) var pendingUndo: FavoriteTarget?
    public private(set) var favoriteCategoryIds: Set<String>

    public init(library: LibraryRepository, kv: any KeyValueStore, now: @escaping () -> Int64,
                onChange: @escaping @MainActor () -> Void = {}) {
        self.library = library; self.kv = kv; self.now = now; self.onChange = onChange
        self.keys = Set(((try? library.favorites()) ?? []).compactMap { $0.contentKey })
        self.favoriteCategoryIds = kv.value(Set<String>.self, forKey: "fav.categories") ?? []
    }

    public func isFavorite(_ contentKey: String) -> Bool { keys.contains(contentKey) }

    @discardableResult
    public func toggle(_ t: FavoriteTarget) -> Bool {
        let on = !keys.contains(t.contentKey)
        apply(on, t)
        pendingUndo = t
        undoTask?.cancel()
        undoTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.pendingUndo = nil
        }
        return on
    }

    public func undo() {
        guard let t = pendingUndo else { return }
        undoTask?.cancel()
        apply(!keys.contains(t.contentKey), t)
        pendingUndo = nil
    }

    private func apply(_ on: Bool, _ t: FavoriteTarget) {
        if on { keys.insert(t.contentKey) } else { keys.remove(t.contentKey) }
        _ = try? library.setFavorite(on, contentKey: t.contentKey, title: t.title, kind: t.kind,
                                     posterUrl: t.posterUrl, nowMs: now())
        onChange()
    }

    private func orderKey(_ kind: ContentKind) -> String { "fav.order.\(kind.rawValue)" }

    public func orderedKeys(kind: ContentKind) -> [String] {
        let newestFirst = ((try? library.favorites(kind: kind)) ?? []).compactMap(\.contentKey)
        let saved = (kv.value([String].self, forKey: orderKey(kind)) ?? []).filter { newestFirst.contains($0) }
        return saved + newestFirst.filter { !saved.contains($0) }
    }

    public func move(kind: ContentKind, from: IndexSet, to: Int) {
        var list = orderedKeys(kind: kind)
        list.move(fromOffsets: from, toOffset: to)
        kv.setValue(list, forKey: orderKey(kind))
        onChange()
    }

    public func toggleCategory(_ id: String) {
        if favoriteCategoryIds.contains(id) { favoriteCategoryIds.remove(id) } else { favoriteCategoryIds.insert(id) }
        kv.setValue(favoriteCategoryIds, forKey: "fav.categories")
        onChange()
    }
}
```
(Adjust `$0.contentKey` to the real `SyncItem` property name — read `IPTVCore/Sources/IPTVCore/Sync/SyncItem.swift`; `list.move(fromOffsets:toOffset:)` requires `import SwiftUI` or a manual implementation — implement manually in IPTVKit to avoid SwiftUI: remove the indices in descending order, insert at `to - removedBefore`.)
- [ ] **Step 4:** run → PASS. **Step 5:** expose in `AppEnvironment` (`favorites` created with the env's library + kv; `onChange` triggers the existing library-changed notification used by Home/Live views). Replace direct `library.setFavorite` / `isFavorite` calls in views/view models with `env.favorites` (grep `setFavorite(` in `apple/Shared` and `IPTVKit/ViewModels`).
- [ ] **Step 6:** verify tests/builds. **Step 7: Commit** `feat: FavoritesController – instant toggle, undo, local order, favorite categories`

### Task 7: One-tap ⭐ everywhere (UI) + favorites first

**Files:**
- Create: `apple/Shared/Views/FavoriteButton.swift`, `apple/Shared/Views/UndoToast.swift`
- Modify: `apple/Shared/Views/LiveTVView.swift` (channel card ⭐; favorites section first; ⭐ on category chip menu), `VODViews.swift` (poster card corner ⭐ on iOS, detail page ⭐), `PlayerView.swift` (⭐ in overlay; tvOS up-arrow info card with ⭐ focused), `HomeView.swift` (favorites rows use `orderedKeys`), Favorites screen (find with `grep -rn "Favorites" apple/Shared/Views`: drag reorder on iOS via `.onMove`, tvOS "Taşı" mode: select → up/down → select)
- Modify: `spec/strings.json` keys `fav_added`, `fav_removed`, `action_undo`, `fav_move`, `fav_move_done`, `fav_category_add`, `fav_category_remove`
- Modify: `docs/SCREENS.md` §3.3–3.7 + new rule list in §2 ("Favori: her yerde tek dokunuş, onaysız, 4 sn geri al")
- Modify: `apple/UITests/iOS/IOSFlowTests.swift`, `apple/UITests/tvOS/TVFlowTests.swift`

**Interfaces:** consumes `FavoritesController` (Task 6). `FavoriteButton(target: FavoriteTarget, style: .icon | .labeled)` — accessibility id `fav_<contentKey>`, label `fav_add`/`fav_remove` strings; tvOS uses `.buttonStyle(.card)`-compatible focusable button.

- [ ] **Step 1: UI tests first** (iOS): `testOneTapFavoriteFromLiveCard` — open Live tab, tap `fav_<firstChannelKey>`, assert `undo_toast` appears and Home shows the channel in the favorites row; tap `action_undo`, assert removed. `testFavoriteFromPlayerOverlay` — play a channel, tap overlay, tap ⭐, back, Live grid shows that channel in the first ("Favoriler") section. tvOS: `testUpArrowInfoCardFavorite` — play channel, `XCUIRemote.shared.press(.up)`, ⭐ is focused, press `.select`, back → Live first section contains it.
- [ ] **Step 2:** run → FAIL. **Step 3:** implement `FavoriteButton`, `UndoToast` (bottom capsule, 4 s, reads `favorites.pendingUndo`, button `action_undo`, VoiceOver announcement), wire into all places above; Live grid: render `favorites.orderedKeys(kind: .channel)` channels as the first section headed "Favoriler", then favorite categories, then the rest; category chip context menu: `fav_category_add/remove`. Player: iOS overlay ⭐ next to aspect/tracks; tvOS: up arrow while playing shows the info card (channel logo, name, now/next) with the ⭐ button as default focus (`.defaultFocus`). Long-press card menus: first item favorite add/remove.
- [ ] **Step 4:** run UI tests (iOS + tvOS) → PASS; screenshots to `scratchpad/screens/perf-ux/`.
- [ ] **Step 5:** SCREENS.md + strings + gen-strings; **Step 6: Commit** `feat: one-tap favorites everywhere with undo, favorites first`

## Phase 3 — Simple menus

### Task 8: In-player channel panel + TV number zapping + 3-tap rule + simplified settings

**Files:**
- Create: `apple/Shared/Views/PlayerChannelPanel.swift`
- Create: `apple/IPTVKit/Sources/IPTVKit/Player/NumberZap.swift`; Test: `apple/IPTVKit/Tests/IPTVKitTests/NumberZapTests.swift`
- Modify: `PlayerView.swift` (iOS: list button + left-edge swipe opens panel; tvOS: OK/select while overlay hidden opens panel, digits via `onKeyPress`/`pressesBegan` → NumberZap), `SettingsView.swift` (top group: Kaynaklar, Dil, Ses dili, Altyazı dili, Hızlı başlat; everything else under a "Gelişmiş" navigation row), `HomeView.swift` (Recently watched row first)
- Modify: `docs/SCREENS.md` §2 (3-tap rule with the list of paths), §3.7, §3.9; strings `player_channels`, `settings_advanced`, `zap_number`
- Modify: UI tests

**Interfaces:**
```swift
public struct NumberZap {
    public init(timeoutMs: Int = 1500)
    /// Feed a digit at time `ms`; returns the buffer to display.
    public mutating func input(_ digit: Int, atMs ms: Int64) -> String
    /// Returns the number to tune to if the timeout elapsed since the last digit (and clears), else nil.
    public mutating func commitIfDue(atMs ms: Int64) -> Int?
}
```
- [ ] **Step 1: Failing test**
```swift
import XCTest
@testable import IPTVKit
final class NumberZapTests: XCTestCase {
    func testCollectsDigitsAndCommitsAfterTimeout() {
        var z = NumberZap()
        XCTAssertEqual(z.input(1, atMs: 0), "1")
        XCTAssertEqual(z.input(2, atMs: 800), "12")
        XCTAssertNil(z.commitIfDue(atMs: 2000))
        XCTAssertEqual(z.commitIfDue(atMs: 2300), 12)
        XCTAssertNil(z.commitIfDue(atMs: 5000))
    }
    func testMaxFourDigits() {
        var z = NumberZap()
        for (i, d) in [1, 2, 3, 4, 5].enumerated() { _ = z.input(d, atMs: Int64(i * 100)) }
        XCTAssertEqual(z.commitIfDue(atMs: 2000), 1234)
    }
}
```
- [ ] **Step 2:** FAIL. **Step 3:** implement:
```swift
public struct NumberZap {
    private let timeoutMs: Int64
    private var buffer = ""
    private var lastMs: Int64 = 0
    public init(timeoutMs: Int = 1500) { self.timeoutMs = Int64(timeoutMs) }
    public mutating func input(_ digit: Int, atMs ms: Int64) -> String {
        if buffer.count < 4 { buffer.append(String(digit)) }
        lastMs = ms
        return buffer
    }
    public mutating func commitIfDue(atMs ms: Int64) -> Int? {
        guard !buffer.isEmpty, ms - lastMs >= timeoutMs else { return nil }
        defer { buffer = "" }
        return Int(buffer)
    }
}
```
- [ ] **Step 4:** PASS. **Step 5:** UI: `PlayerChannelPanel` (overlay panel on the leading side, 40 % width iOS landscape / full height sheet portrait, tvOS 600 pt; category picker at top, favorites first, rows with logo + name + now programme; selecting zaps via existing zap path; playback continues behind). tvOS digits: big number indicator top-right, after commit tune to channel with `number == n` (fallback: 1-based index). Settings restructure as listed. Recently watched row first on Home.
- [ ] **Step 6: UI tests** — iOS `testThreeTapPaths`: from Home reach (a) a live channel playing in ≤ 3 taps (Live tab → card), (b) settings language in ≤ 3 (gear → Dil), (c) add source in ≤ 3 (gear → Kaynaklar → +). `testInPlayerChannelPanel`: play, open panel, tap another channel, `video_surface` still present, title changed. tvOS `testChannelPanelOK`.
- [ ] **Step 7:** verify, SCREENS, strings. **Step 8: Commit** `feat: in-player channel panel, TV number zap, simpler settings`

## Phase 4 — Audio sync

### Task 9: Audio delay (per content + device) with VLC routing, and "Fix sync"

**Files:**
- Create: `apple/IPTVKit/Sources/IPTVKit/Player/AudioDelayStore.swift`; Test: `apple/IPTVKit/Tests/IPTVKitTests/AudioDelayTests.swift`
- Modify: `PlaybackEngine.swift` (`func setAudioDelay(ms: Int)`), `AVPlayerEngine.swift` (no-op), `apple/Shared/Player/VLCPlaybackEngine.swift` (`player.currentAudioPlaybackDelay = ms * 1000`), `PlayerController.swift` (engine choice + `resync()` + auto-resync after reconnect), `PlayerView.swift` (Audio menu → "Senkron" slider −2000…+2000 step 50 with live apply; "Senkronu düzelt" button), `SettingsView.swift` (Oynatma → "Cihaz/soundbar gecikmesi")
- Modify: `spec/CONTRACT.md` §6.1 (engine rule `audioDelayMs ≠ 0 → VLCKit`), `docs/ARCHITECTURE.md` §3.2, `docs/SCREENS.md` §3.7; strings `audio_sync`, `audio_sync_hint`, `audio_sync_fix`, `settings_device_audio_delay`, `audio_sync_vlc_note`

**Interfaces:**
```swift
public struct AudioDelayStore: Sendable {
    public init(kv: any KeyValueStore)
    public static let range: ClosedRange<Int> = -2000...2000
    public static let step = 50
    public func contentDelay(_ contentKey: String) -> Int        // default 0
    public func setContentDelay(_ ms: Int, for contentKey: String) // clamped + rounded to step; 0 removes the key
    public var deviceDelay: Int { get }
    public func setDeviceDelay(_ ms: Int)
    public func effectiveDelay(_ contentKey: String) -> Int      // clamp(content + device)
}
// PlayerController additions
public var audioDelayStore: AudioDelayStore?
public var currentAudioDelay: Int { get }              // effective for current request
public func setAudioDelay(_ ms: Int)                   // stores per content; if engine is AVPlayer and ms != 0 → reload same position in VLC
public func resync()                                   // live: reload at live edge; VOD: reload at currentTime
```
- [ ] **Step 1: Failing tests**
```swift
import XCTest
@testable import IPTVKit
final class AudioDelayTests: XCTestCase {
    func testClampRoundAndEffective() {
        let s = AudioDelayStore(kv: InMemoryKeyValueStore())
        s.setContentDelay(130, for: "ch:a")
        XCTAssertEqual(s.contentDelay("ch:a"), 150)
        s.setContentDelay(9999, for: "ch:a")
        XCTAssertEqual(s.contentDelay("ch:a"), 2000)
        s.setDeviceDelay(-300)
        XCTAssertEqual(s.effectiveDelay("ch:a"), 1700)
        XCTAssertEqual(s.effectiveDelay("ch:b"), -300)
        s.setContentDelay(0, for: "ch:a")
        XCTAssertEqual(s.contentDelay("ch:a"), 0)
    }
}
```
plus PlayerController tests with fake engines (in `EngineTests.swift` style): (1) HLS stream with effective delay 0 → AVPlayer engine; with stored delay 200 → VLC engine and `setAudioDelay(200)` called on it; (2) `setAudioDelay(300)` while on AVPlayer → reload on VLC with `startMs` ≈ current position (VOD) ; (3) `resync()` on live → engine `load` called again with `startMs == nil`; (4) after a reconnect success event → resync was applied once.
- [ ] **Step 2:** FAIL. **Step 3: Implement** `AudioDelayStore`:
```swift
public struct AudioDelayStore: Sendable {
    private let kv: any KeyValueStore
    public static let range: ClosedRange<Int> = -2000...2000
    public static let step = 50
    public init(kv: any KeyValueStore) { self.kv = kv }
    static func normalize(_ ms: Int) -> Int {
        let c = min(max(ms, range.lowerBound), range.upperBound)
        return Int((Double(c) / Double(step)).rounded()) * step
    }
    private func key(_ k: String) -> String { "audioDelay.\(k)" }
    public func contentDelay(_ contentKey: String) -> Int { kv.value(Int.self, forKey: key(contentKey)) ?? 0 }
    public func setContentDelay(_ ms: Int, for contentKey: String) {
        let v = Self.normalize(ms)
        if v == 0 { kv.set(nil, forKey: key(contentKey)) } else { kv.setValue(v, forKey: key(contentKey)) }
    }
    public var deviceDelay: Int { kv.value(Int.self, forKey: "audioDelay.device") ?? 0 }
    public func setDeviceDelay(_ ms: Int) { kv.setValue(Self.normalize(ms), forKey: "audioDelay.device") }
    public func effectiveDelay(_ contentKey: String) -> Int { Self.normalize(contentDelay(contentKey) + deviceDelay) }
}
```
PlayerController: `engineKind(for:)` returns `.vlcKit` when `engines.vlcAvailable && currentAudioDelay != 0`; after `load`, call `engine.setAudioDelay(ms: currentAudioDelay)`. `setAudioDelay(_:)` stores via `audioDelayStore.setContentDelay(_, for: contentKey)`; if VLC active → `engine.setAudioDelay`; if AVPlayer active and new effective ≠ 0 → `fallbackEngine = .vlcKit; load(stream, startMs: isLive ? nil : Int64(currentTime*1000))`. `resync()` → `load(stream, startMs: isLive ? nil : Int64(currentTime*1000))`. Hook: when `reconnectState` transitions from reconnecting to `.playing`, call `resync()` once for live streams. `contentKey` = existing content-key helper for the request item (grep `ContentKeys` in IPTVCore).
- [ ] **Step 4:** PASS. **Step 5: UI** — Audio menu "Senkron" row opens a sheet/popover: slider (iOS) or −/+ buttons with value label (tvOS, single focus per row → use a horizontal stepper control that is ONE focusable custom view handling left/right via `onMoveCommand`), current value "+150 ms", note string `audio_sync_vlc_note` shown when the current engine is AVPlayer ("Gecikme ayarlanınca bu kanal VLC motoruyla oynatılır"). "Senkronu düzelt" button in the overlay (icon `arrow.triangle.2.circlepath`, id `action_resync`). Settings → Oynatma → device delay (same control).
- [ ] **Step 6:** CONTRACT §6.1 + vectors: if `spec/test-vectors/media/expected.json` `appleEngine` section encodes engine choice, add cases with `audioDelayMs` (follow `spec/test-vectors/README.md`; keep Kotlin `./gradlew -p core test` green — Kotlin ignores the Apple section). ARCHITECTURE §3.2, SCREENS §3.7, strings en/tr/de.
- [ ] **Step 6b: Live HLS preference for M3U `.ts` channels.** In `StreamResolver` (live channel from an M3U source): if the URL matches the Xtream live pattern `^(https?://[^/]+)/(live/)?([^/]+)/([^/]+)/(\d+)\.ts$` (tested in `IPTVCore` `XtreamURLBuilder`/`StreamFormat` style), first try the same URL with `.m3u8` via a 1.5 s HEAD/GET-range probe (`VLCFailureClassifier.probe`-like, status 200 and body starting with `#EXTM3U`); on success return the m3u8 with engine `.avPlayer`, else keep `.ts` → VLCKit. Unit test with a fake transport: (a) m3u8 available → m3u8/AVPlayer, (b) 404 → ts/VLCKit, (c) non-matching URL → no probe. Document in CONTRACT §4.5/§6.1 and add a vector to `spec/test-vectors/xtream/url-vectors.json` only if that file covers M3U-derived URLs (follow its README).
- [ ] **Step 7: UI test** iOS `testAudioSyncRoutesToVLC`: play HLS channel (engine label in perf overlay = AVPlayer — enable overlay via launch arg `-perfOverlay` added in DEBUG hooks), open Audio → Senkron, set +200 → perf overlay engine shows VLCKit within 5 s; press `action_resync` → still playing. Run iOS + tvOS suites.
- [ ] **Step 8: Commit** `feat: per-channel audio delay (VLC), device delay, one-tap resync`

### Task 10: Docs, full verification, TestFlight build 6

**Files:** `docs/TEST_PLAN.md` (map new tests), `apple/README.md` (perf overlay, quick start, audio sync), `apple/Config/Shared.xcconfig` (`CURRENT_PROJECT_VERSION = 6`)

- [ ] **Step 1:** Run every verification command (IPTVCore, IPTVKit, Kotlin core, backend `npm test`, iOS + tvOS builds, iOS + tvOS UI suites with media servers on 8765 and 8766 — VLC server: `cd scratchpad/vlc-www && python3 ../range_server.py 8766`). All green; record counts.
- [ ] **Step 2:** Measure on simulator with perf overlay: cold start and 10 zaps on the demo HLS channels; record p50/p90 in `docs/TEST_PLAN.md` (simulator numbers; real-device numbers come from the user via TestFlight). Run Instruments "Animation Hitches" (`xcrun xctrace record --template 'Animation Hitches' --attach NovaPlayer --time-limit 20s`) while scrolling the Live grid and TV Guide on iPhone simulator; record hitch ratio (target < 1 %). Verify a source refresh of the 50k demo list (generate with the Task 5 data via a DEBUG launch arg or a local M3U) keeps the UI responsive (Live grid scrolls during refresh).
- [ ] **Step 3:** Update docs; bump build to 6; commit `docs: perf/UX program results; build 6`; push.
- [ ] **Step 4 (coordinator):** archive + export + upload iOS and tvOS build 6 (same commands as builds 4/5) and wait until VALID.

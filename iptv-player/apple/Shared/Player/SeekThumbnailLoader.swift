import AVFoundation
import CoreGraphics
import IPTVCore
import IPTVKit
import Observation

/// Preview thumbnails for the seek bubble (docs/SCREENS.md §3.7). Only where
/// `SeekThumbnailPolicy.allows` says a second connection is safe (AVPlayer, progressive VOD, no
/// single-connection Xtream account); otherwise it stays disabled and opens nothing. Requests go
/// through `SeekThumbnailSchedule`: the newest 10 s bucket only (a stale request is cancelled), at most
/// one start per 300 ms, ~320 px wide, cached per bucket for the current stream.
@MainActor
@Observable
final class SeekThumbnailLoader {
    /// Thumbnail of the bucket last asked for (or the previous one until it arrives); nil = none / disabled.
    private(set) var image: CGImage?

    @ObservationIgnored private var generator: AVAssetImageGenerator?
    @ObservationIgnored private var stream: ResolvedStream?
    @ObservationIgnored private var schedule = SeekThumbnailSchedule()
    @ObservationIgnored private var cache: [Int: CGImage] = [:]
    @ObservationIgnored private var cacheOrder: [Int] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var failures = 0
    /// Bucket the bubble shows (its image replaces `image` once generated).
    @ObservationIgnored private var shownBucket: Int?

    private static let cacheLimit = 60
    /// Consecutive failures after which the stream gets no more requests.
    private static let failureLimit = 3

    /// A scrub starts: (re)creates the generator for this stream when allowed, else disables.
    func prepare(player: PlayerController) {
        let allowed = SeekThumbnailPolicy.allows(engine: player.engineKind, request: player.request, stream: player.stream)
        guard allowed, let stream = player.stream else {
            reset()
            return
        }
        guard stream != self.stream || generator == nil else { return }
        reset()
        self.stream = stream
        var options: [String: Any] = [:]
        // Same headers (User-Agent / Referer) as the playing item.
        if !stream.headers.isEmpty { options["AVURLAssetHTTPHeaderFieldsKey"] = stream.headers }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: stream.url, options: options))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: SeekThumbnailPolicy.maxWidth, height: SeekThumbnailPolicy.maxWidth)
        // A nearby keyframe is good enough for a preview (much faster than an exact frame).
        let tolerance = CMTime(seconds: SeekThumbnailPolicy.bucketSeconds / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        self.generator = generator
    }

    /// The bubble shows `seconds`.
    func request(_ seconds: Double) {
        guard generator != nil, failures < Self.failureLimit else { return }
        let bucket = SeekThumbnailPolicy.bucket(seconds)
        shownBucket = bucket
        if let cached = cache[bucket] {
            image = cached
            _ = schedule.want(seconds)   // settled → nothing wanted
            return
        }
        if schedule.want(seconds) {
            // The request in flight is for a position the user already left.
            generator?.cancelAllCGImageGeneration()
        }
        pump()
    }

    /// The scrub ended: nothing more is requested; the cache stays for the next scrub.
    func endScrub() {
        schedule.clearWanted()
        shownBucket = nil
        image = nil
    }

    /// Drops the generator, cache and pending work (other stream, unsafe, player closed).
    func reset() {
        task?.cancel()
        task = nil
        generator?.cancelAllCGImageGeneration()
        generator = nil
        stream = nil
        schedule = SeekThumbnailSchedule()
        cache.removeAll()
        cacheOrder.removeAll()
        failures = 0
        shownBucket = nil
        image = nil
    }

    private func pump() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while let self, !Task.isCancelled {
                guard let delay = self.schedule.delayBeforeNext(nowMs: SystemClock.monotonicMs()) else { break }
                if delay > 0 {
                    try? await Task.sleep(for: .milliseconds(delay))
                    continue
                }
                guard let generator = self.generator, let bucket = self.schedule.start(nowMs: SystemClock.monotonicMs()) else { break }
                let result = await Self.generate(generator, at: SeekThumbnailPolicy.time(ofBucket: bucket))
                guard !Task.isCancelled, self.generator === generator else { break }
                switch result {
                case .image(let image):
                    self.failures = 0
                    self.schedule.finish(bucket, settle: true)
                    self.store(image, for: bucket)
                    if self.shownBucket == bucket { self.image = image }
                case .cancelled:
                    self.schedule.finish(bucket, settle: false)
                case .failed:
                    self.failures += 1
                    self.schedule.finish(bucket, settle: true)
                    if self.failures >= Self.failureLimit {
                        SafeLog.info("seek thumbnails off for this stream after \(self.failures) failures")
                        self.generator = nil
                    }
                }
            }
            self?.task = nil
        }
    }

    private func store(_ image: CGImage, for bucket: Int) {
        cache[bucket] = image
        cacheOrder.append(bucket)
        while cacheOrder.count > Self.cacheLimit {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
    }

    private enum Outcome: Sendable {
        case image(CGImage)
        case cancelled
        case failed
    }

    /// One image via the completion-handler API (its callback runs on a generator queue).
    private static func generate(_ generator: AVAssetImageGenerator, at seconds: Double) async -> Outcome {
        await withCheckedContinuation { continuation in
            generator.generateCGImageAsynchronously(for: CMTime(seconds: seconds, preferredTimescale: 600)) { image, _, error in
                if let image {
                    continuation.resume(returning: .image(image))
                } else if (error as NSError?)?.code == AVError.operationCancelled.rawValue
                            || (error as NSError?)?.code == NSUserCancelledError {
                    continuation.resume(returning: .cancelled)
                } else {
                    continuation.resume(returning: .failed)
                }
            }
        }
    }
}

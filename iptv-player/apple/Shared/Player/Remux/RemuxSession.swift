import CNovaRemux
import Foundation

/// One remuxed stream: the FFmpeg context (`nova_remux.c`) over a `RemuxByteSource`, its HLS
/// playlists and on-demand fMP4 segments. All FFmpeg calls run on ONE serial worker queue; segment
/// requests from the local HTTP server are answered from a small cache or generated there.
///
/// Scheduling: a request interrupts a running *prefetch* of another segment and a running request
/// whose HTTP client went away (AVPlayer cancelled it after a seek). After a request the next segment
/// is prefetched, so steady playback is served from the cache.
final class RemuxSession: @unchecked Sendable {
    struct Info: Sendable {
        var duration: Double
        var width: Int
        var height: Int
        var fps: Double
        var videoCodec: String
        var codecs: String
        var videoRange: String
        var audioIn: String
        var audioOut: String
        var audioLanguage: String
        var audioTranscoded: Bool
        var audioChannels: Int
        var audioTrackCount: Int
        var bitrate: Int
        var segments: [(start: Double, duration: Double)]
        var targetDuration: Double
        var openBytes: Int64
    }

    struct SegmentTiming: Sendable {
        var index: Int
        var ms: Double
        var bytes: Int
        var encodeMs: Double
        var prefetch: Bool
        var videoFirst: Double
        var videoEnd: Double
        var audioFirst: Double
        var audioEnd: Double
    }

    enum RemuxError: Error, Equatable {
        case open(code: Int32, message: String)
        case segment(code: Int32)
        case cancelled
    }

    typealias Completion = @Sendable (Result<Data, RemuxError>) -> Void

    let token: String
    let info: Info
    private let source: RemuxByteSource
    private let queue: DispatchQueue
    private let lock = NSLock()
    // Guarded by `lock`.
    private var ctx: OpaquePointer?
    private var cache: [Int: Data] = [:]
    private var cacheOrder: [Int] = []
    private var initData: Data?
    private var waiters: [Int: [(id: UInt64, completion: Completion)]] = [:]
    private var running: (index: Int, prefetch: Bool)?
    private var nextWaiterId: UInt64 = 0
    private var timings: [SegmentTiming] = []
    private let maxCached = 4

    /// Called with each finished segment (diagnostics / spike measurements).
    var onSegment: (@Sendable (SegmentTiming) -> Void)?

    private init(token: String, info: Info, source: RemuxByteSource, ctx: OpaquePointer, queue: DispatchQueue) {
        self.token = token
        self.info = info
        self.source = source
        self.ctx = ctx
        self.queue = queue
    }

    deinit {
        if let ctx { nr_close(ctx) }
    }

    // MARK: Open

    /// Opens and indexes the stream (blocking network IO on the worker queue).
    static func open(url: URL, headers: [String: String], audioLanguage: String?, targetSegment: Double = 4,
                     forceAudioTranscode: Bool = false, blockSize: Int = 1 << 20, maxInFlight: Int = 1) async throws -> RemuxSession {
        let queue = DispatchQueue(label: "nova.remux.worker", qos: .userInitiated)
        let source = RemuxByteSource(url: url, headers: headers, blockSize: blockSize,
                                     maxBlocks: max(8, (24 << 20) / blockSize), readAhead: max(2, (3 << 20) / blockSize),
                                     maxInFlight: maxInFlight)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try source.open()
                } catch let error as RemuxByteSource.SourceError {
                    let code: Int32 = if case .httpStatus(let status) = error { Int32(status) } else { -1 }
                    continuation.resume(throwing: RemuxError.open(code: code, message: "\(error)"))
                    return
                } catch {
                    continuation.resume(throwing: RemuxError.open(code: -1, message: "source"))
                    return
                }
                let opaque = Unmanaged.passUnretained(source).toOpaque()
                var code: Int32 = 0
                var err = [CChar](repeating: 0, count: 256)
                let ctx = nr_open(opaque, remuxRead, remuxSeek, audioLanguage, targetSegment, forceAudioTranscode ? 1 : 0,
                                  &code, &err, Int32(err.count))
                guard let ctx else {
                    source.close()
                    continuation.resume(throwing: RemuxError.open(code: code, message: String(decoding: err.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)))
                    return
                }
                var raw = NRInfo()
                nr_get_info(ctx, &raw)
                var segments: [(Double, Double)] = []
                segments.reserveCapacity(Int(raw.segment_count))
                for i in 0..<raw.segment_count { segments.append((nr_segment_start(ctx, i), nr_segment_duration(ctx, i))) }
                let info = Info(duration: raw.duration, width: Int(raw.width), height: Int(raw.height), fps: raw.fps,
                                videoCodec: string(raw.video_codec), codecs: string(raw.codecs),
                                videoRange: string(raw.video_range), audioIn: string(raw.audio_codec_in),
                                audioOut: string(raw.audio_codec_out), audioLanguage: string(raw.audio_language),
                                audioTranscoded: raw.audio_transcoded != 0, audioChannels: Int(raw.audio_channels),
                                audioTrackCount: Int(raw.audio_track_count), bitrate: Int(raw.bitrate),
                                segments: segments, targetDuration: raw.target_duration, openBytes: raw.open_bytes_read)
                let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
                continuation.resume(returning: RemuxSession(token: token, info: info, source: source, ctx: ctx, queue: queue))
            }
        }
    }

    func close() {
        source.close()
        lock.lock()
        let ctx = self.ctx
        if let ctx { nr_interrupt(ctx, 1) }
        let pendingWaiters = waiters.values.flatMap { $0 }
        waiters.removeAll()
        lock.unlock()
        for waiter in pendingWaiters { waiter.completion(.failure(.cancelled)) }
        // Free on the worker queue, after any running job.
        queue.async { [self] in
            lock.lock()
            let ctx = self.ctx
            self.ctx = nil
            cache.removeAll()
            lock.unlock()
            if let ctx { nr_close(ctx) }
        }
    }

    var byteStats: RemuxByteSource.Stats { source.statistics }
    var segmentTimings: [SegmentTiming] { lock.withLock { timings } }

    // MARK: Playlists

    func masterPlaylist() -> String {
        var attrs = "BANDWIDTH=\(max(info.bitrate, 100_000)),CODECS=\"\(info.codecs)\""
        if info.width > 0, info.height > 0 { attrs += ",RESOLUTION=\(info.width)x\(info.height)" }
        if info.fps > 0 { attrs += ",FRAME-RATE=\(String(format: "%.3f", info.fps))" }
        attrs += ",VIDEO-RANGE=\(info.videoRange)"
        return "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-INDEPENDENT-SEGMENTS\n#EXT-X-STREAM-INF:\(attrs)\nmedia.m3u8\n"
    }

    func mediaPlaylist() -> String {
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:\(Int(info.targetDuration.rounded(.up)))",
                     "#EXT-X-MEDIA-SEQUENCE:0", "#EXT-X-PLAYLIST-TYPE:VOD", "#EXT-X-INDEPENDENT-SEGMENTS",
                     "#EXT-X-MAP:URI=\"init.mp4\""]
        for (i, segment) in info.segments.enumerated() {
            lines.append(String(format: "#EXTINF:%.6f,", segment.duration))
            lines.append("seg\(i).m4s")
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Segments

    func initSegment(completion: @escaping Completion) {
        if let data = lock.withLock({ initData }) { return completion(.success(data)) }
        queue.async { [self] in
            if let data = lock.withLock({ initData }) { return completion(.success(data)) }
            guard let ctx = lock.withLock({ self.ctx }) else { return completion(.failure(.cancelled)) }
            nr_interrupt(ctx, 0)
            source.setInterrupted(false)
            var ptr: UnsafeMutablePointer<UInt8>?
            var size = 0
            var seg0: UnsafeMutablePointer<UInt8>?
            var seg0Size = 0
            var stats = NRSegmentStats()
            let started = DispatchTime.now().uptimeNanoseconds
            let ret = nr_init_segment(ctx, &ptr, &size, &seg0, &seg0Size, &stats)
            guard ret >= 0, let ptr else { return completion(.failure(.segment(code: ret))) }
            let data = Data(bytes: ptr, count: size)
            nr_free(ptr)
            var timing: SegmentTiming?
            lock.withLock {
                initData = data
                // Segment 0 came with it: AVPlayer's first media request is a cache hit.
                if let seg0, cache[0] == nil {
                    cache[0] = Data(bytes: seg0, count: seg0Size)
                    cacheOrder.append(0)
                    timing = SegmentTiming(index: 0, ms: Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000,
                                           bytes: seg0Size, encodeMs: stats.encode_ms, prefetch: true,
                                           videoFirst: stats.video_first_pts, videoEnd: stats.video_end_pts,
                                           audioFirst: stats.audio_first_pts, audioEnd: stats.audio_end_pts)
                    timings.append(timing!)
                }
            }
            if let seg0 { nr_free(seg0) }
            if let timing { onSegment?(timing) }
            completion(.success(data))
        }
    }

    /// Requests segment `index`; returns an id for `cancel(waiter:)` (HTTP client gone).
    @discardableResult
    func segment(_ index: Int, completion: @escaping Completion) -> UInt64 {
        lock.lock()
        if let data = cache[index] {
            lock.unlock()
            completion(.success(data))
            schedulePrefetch(index + 1)
            return 0
        }
        nextWaiterId += 1
        let id = nextWaiterId
        waiters[index, default: []].append((id, completion))
        if let running, running.index != index, running.prefetch || (waiters[running.index]?.isEmpty ?? true) {
            interruptLocked()
        }
        lock.unlock()
        queue.async { [self] in run(index, prefetch: false) }
        return id
    }

    /// The HTTP client of a waiting request went away.
    func cancel(waiter id: UInt64) {
        lock.lock()
        for (index, list) in waiters {
            if let i = list.firstIndex(where: { $0.id == id }) {
                waiters[index]?.remove(at: i)
                if waiters[index]?.isEmpty == true { waiters[index] = nil }
            }
        }
        lock.unlock()
    }

    private func interruptLocked() {
        if let ctx { nr_interrupt(ctx, 1) }
        source.setInterrupted(true)
    }

    private func schedulePrefetch(_ index: Int) {
        guard index < info.segments.count else { return }
        let needed = lock.withLock { cache[index] == nil && running?.index != index }
        guard needed else { return }
        queue.async { [self] in run(index, prefetch: true) }
    }

    /// Worker queue.
    private func run(_ index: Int, prefetch: Bool) {
        lock.lock()
        if let data = cache[index] {
            let list = waiters.removeValue(forKey: index) ?? []
            lock.unlock()
            for waiter in list { waiter.completion(.success(data)) }
            return
        }
        // A request nobody waits for any more (seeked away) is skipped.
        if !prefetch, waiters[index]?.isEmpty ?? true {
            lock.unlock()
            return
        }
        guard let ctx else { lock.unlock(); return }
        running = (index, prefetch)
        lock.unlock()
        nr_interrupt(ctx, 0)
        source.setInterrupted(false)

        let started = DispatchTime.now().uptimeNanoseconds
        var ptr: UnsafeMutablePointer<UInt8>?
        var size = 0
        var stats = NRSegmentStats()
        let ret = nr_media_segment(ctx, Int32(index), &ptr, &size, &stats)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000

        lock.lock()
        running = nil
        let list = waiters.removeValue(forKey: index) ?? []
        guard ret >= 0, let ptr else {
            lock.unlock()
            for waiter in list { waiter.completion(.failure(ret == -0x54495845 ? .cancelled : .segment(code: ret))) }
            return
        }
        let data = Data(bytes: ptr, count: size)
        nr_free(ptr)
        cache[index] = data
        cacheOrder.append(index)
        while cacheOrder.count > maxCached { cache[cacheOrder.removeFirst()] = nil }
        let timing = SegmentTiming(index: index, ms: ms, bytes: size, encodeMs: stats.encode_ms, prefetch: prefetch,
                                   videoFirst: stats.video_first_pts, videoEnd: stats.video_end_pts,
                                   audioFirst: stats.audio_first_pts, audioEnd: stats.audio_end_pts)
        timings.append(timing)
        if timings.count > 200 { timings.removeFirst() }
        lock.unlock()
        onSegment?(timing)
        for waiter in list { waiter.completion(.success(data)) }
        if !prefetch { schedulePrefetch(index + 1) }
    }
}

private func string<T>(_ tuple: T) -> String {
    withUnsafeBytes(of: tuple) { raw in
        let bytes = raw.bindMemory(to: CChar.self)
        return String(cString: bytes.baseAddress!)
    }
}

// MARK: C callbacks (worker thread)

private let remuxRead: NRReadFn = { opaque, buffer, size in
    guard let opaque, let buffer else { return -1 }
    let source = Unmanaged<RemuxByteSource>.fromOpaque(opaque).takeUnretainedValue()
    return Int32(source.read(into: buffer, count: Int(size)))
}

private let remuxSeek: NRSeekFn = { opaque, offset, whence in
    guard let opaque else { return -1 }
    let source = Unmanaged<RemuxByteSource>.fromOpaque(opaque).takeUnretainedValue()
    return source.seek(offset: offset, whence: whence)
}

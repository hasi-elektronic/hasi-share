import CoreGraphics
import Foundation
import ImageIO

/// Poster/logo loading: URLCache (200 MB disk, 30 MB memory) for the bytes + NSCache for
/// decoded, downsampled images (docs/ARCHITECTURE.md §2, §7).
public final class ImageLoader: @unchecked Sendable {
    public static let shared = ImageLoader()

    private let session: URLSession
    private let cache = NSCache<NSString, CGImage>()
    public let urlCache: URLCache

    public init(diskCapacity: Int = 200 * 1024 * 1024, memoryCapacity: Int = 30 * 1024 * 1024) {
        urlCache = URLCache(memoryCapacity: memoryCapacity, diskCapacity: diskCapacity, directory: nil)
        let config = URLSessionConfiguration.default
        config.urlCache = urlCache
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.timeoutIntervalForRequest = 15
        config.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: config)
        cache.countLimit = 400
        cache.totalCostLimit = 120 * 1024 * 1024
    }

    /// Cached decoded image, if any.
    public func cached(_ url: URL, maxPixel: Int) -> CGImage? {
        cache.object(forKey: "\(maxPixel)|\(url.absoluteString)" as NSString)
    }

    /// Loads and downsamples an image to at most `maxPixel` on its longest side.
    public func image(for url: URL, maxPixel: Int) async -> CGImage? {
        let key = "\(maxPixel)|\(url.absoluteString)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              let image = Self.downsample(data, maxPixel: maxPixel) else { return nil }
        cache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }

    static func downsample(_ data: Data, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceShouldCacheImmediately: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// "Clear image cache" in diagnostics.
    public func clear() {
        cache.removeAllObjects()
        urlCache.removeAllCachedResponses()
    }
}

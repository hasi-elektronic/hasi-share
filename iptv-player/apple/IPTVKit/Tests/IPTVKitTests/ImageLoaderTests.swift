import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import IPTVKit

final class ImageLoaderTests: XCTestCase {
    private func pngData(width: Int, height: Int) -> Data {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return data as Data
    }

    /// 2000x2000 source for a 100-pt target at 3x scale → at most 300 px decoded.
    func testLargePNGIsDecodedAtTargetSize() throws {
        let data = pngData(width: 2000, height: 2000)
        let image = try XCTUnwrap(ImageLoader.downsample(data, maxPixel: 100 * 3))
        XCTAssertLessThanOrEqual(max(image.width, image.height), 300)
        XCTAssertEqual(max(image.width, image.height), 300)
    }

    func testSmallerImageIsNotUpscaled() throws {
        let image = try XCTUnwrap(ImageLoader.downsample(pngData(width: 120, height: 60), maxPixel: 300))
        XCTAssertLessThanOrEqual(max(image.width, image.height), 300)
        XCTAssertEqual(image.width, 120)
    }
}

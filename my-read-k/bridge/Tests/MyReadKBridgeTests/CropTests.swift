import XCTest
@testable import MyReadKBridge

final class CropTests: XCTestCase {
    private func image(bodyGray: CGFloat, marginGray: CGFloat) -> CGImage {
        let context = CGContext(
            data: nil, width: 10, height: 10, bitsPerComponent: 8,
            bytesPerRow: 40, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: bodyGray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        context.setFillColor(CGColor(gray: marginGray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 10))
        return context.makeImage()!
    }

    func testNormalizedTopLeftCropConvertsToPixels() throws {
        let crop = try NormalizedCrop(x: 0.1, y: 0.2, width: 0.5, height: 0.4)
        XCTAssertEqual(crop.pixelRect(imageWidth: 1000, imageHeight: 800),
                       CGRect(x: 100, y: 160, width: 500, height: 320))
    }

    func testRejectsOutOfBoundsCrop() {
        XCTAssertThrowsError(try NormalizedCrop(x: -0.1, y: 0, width: 1, height: 1))
        XCTAssertThrowsError(try NormalizedCrop(x: 0.5, y: 0, width: 0.6, height: 1))
        XCTAssertThrowsError(try NormalizedCrop(x: 0, y: 0, width: 0, height: 1))
    }

    func testContentFingerprintIgnoresPixelsOutsideCrop() throws {
        let crop = try NormalizedCrop(x: 0.2, y: 0, width: 0.8, height: 1)
        let first = image(bodyGray: 1, marginGray: 0)
        let overlayChanged = image(bodyGray: 1, marginGray: 0.5)
        let contentChanged = image(bodyGray: 0.75, marginGray: 0)
        let firstFingerprint = try ScreenshotImage.pixelFingerprint(
            image: first.cropping(to: crop.pixelRect(imageWidth: 10, imageHeight: 10))!)
        let overlayFingerprint = try ScreenshotImage.pixelFingerprint(
            image: overlayChanged.cropping(to: crop.pixelRect(imageWidth: 10, imageHeight: 10))!)
        let contentFingerprint = try ScreenshotImage.pixelFingerprint(
            image: contentChanged.cropping(to: crop.pixelRect(imageWidth: 10, imageHeight: 10))!)
        XCTAssertEqual(firstFingerprint, overlayFingerprint)
        XCTAssertNotEqual(firstFingerprint, contentFingerprint)
    }
}

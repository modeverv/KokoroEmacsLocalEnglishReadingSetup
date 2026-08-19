import XCTest
@testable import MyReadKBridge

final class CropTests: XCTestCase {
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
}

import XCTest
@testable import MyReadK2Bridge

final class KindlePageTests: XCTestCase {
    func testParsesKindlePagePositions() {
        let identifier = #"pageDetails:{"start":{"short":8783,"long":""},"end":{"short":9885,"long":""},"words":[]}"#
        let positions = KindlePage.positions(from: identifier)
        XCTAssertEqual(positions.start, 8783)
        XCTAssertEqual(positions.end, 9885)
    }

    func testPagePositionMakesStableFingerprint() {
        let page = KindlePage(text: "English text", identifier: "ignored", start: 10, end: 20)
        XCTAssertEqual(page.fingerprint, "kindle-position:10-20")
    }
}

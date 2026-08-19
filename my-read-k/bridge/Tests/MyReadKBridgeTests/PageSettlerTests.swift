import XCTest
@testable import MyReadKBridge

final class PageSettlerTests: XCTestCase {
    func testStableAfterChange() {
        XCTAssertEqual(PageSettler.evaluate(before: "A", samples: ["B", "C", "C"], stableSamples: 2), .stable)
    }

    func testDidNotChange() {
        XCTAssertEqual(PageSettler.evaluate(before: "A", samples: ["A", "A", "A"], stableSamples: 2), .didNotChange)
    }

    func testChangedButNeverStable() {
        XCTAssertEqual(PageSettler.evaluate(before: "A", samples: ["B", "C", "D"], stableSamples: 2), .timeout)
    }
}

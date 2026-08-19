import XCTest
@testable import MyReadKBridge

final class ChromeTargetTests: XCTestCase {
    func testSelectsOnlyMatchingPageWithWebSocket() {
        let targets = [
            ChromeTarget(id: "a", type: "page", title: "Other", url: "https://example.com", webSocketDebuggerUrl: "ws://a"),
            ChromeTarget(id: "b", type: "service_worker", title: "Kindle", url: "https://read.amazon.co.jp/sw", webSocketDebuggerUrl: "ws://b"),
            ChromeTarget(id: "c", type: "page", title: "Kindle", url: "https://read.amazon.co.jp/?asin=1", webSocketDebuggerUrl: "ws://c")
        ]
        XCTAssertEqual(ChromeTarget.select(from: targets, urlPattern: "read.amazon")?.id, "c")
        XCTAssertNil(ChromeTarget.select(from: targets, urlPattern: "does-not-exist"))
    }
}

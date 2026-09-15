import Testing
@testable import MyReadK2Bridge

struct KindlePageTests {
    @Test func logicalNavigationUsesLayoutIndependentPageKeys() {
        // macOS Page Down / Page Up, rather than physical Right / Left.
        // The same mapping is used when prefetch visits pages and returns.
        #expect(PageDirection.next.keyCode == 121)
        #expect(PageDirection.previous.keyCode == 116)
    }

    @Test func parsesKindlePagePositions() {
        let identifier = #"pageDetails:{"start":{"short":8783,"long":""},"end":{"short":9885,"long":""},"words":[]}"#
        let positions = KindlePage.positions(from: identifier)
        #expect(positions.start == 8783)
        #expect(positions.end == 9885)
    }

    @Test func pagePositionMakesStableFingerprint() {
        let page = KindlePage(text: "English text", identifier: "ignored", start: 10, end: 20)
        #expect(page.fingerprint == "kindle-position:10-20")
    }

    @Test func automaticBookTitleUsesDetectedMetadata() {
        #expect(KindleBookTitle.resolve(
            override: nil,
            detected: "Full Metal Panic! Volume 1") == "Full Metal Panic! Volume 1")
        #expect(KindleBookTitle.resolve(
            override: "Kindle.app",
            detected: "Full Metal Panic! Volume 1") == "Full Metal Panic! Volume 1")
    }

    @Test func explicitBookTitleOverridesDetectedMetadata() {
        #expect(KindleBookTitle.resolve(
            override: "My preferred title",
            detected: "Metadata title") == "My preferred title")
    }
}

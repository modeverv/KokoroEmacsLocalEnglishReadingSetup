import Testing
@testable import MyReadK2Bridge

struct KindlePageTests {
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
}

import XCTest
@testable import MyReadKBridge

final class VisionOCRTests: XCTestCase {
    func testReadingOrderUsesVisionLowerLeftCoordinates() {
        let lines = [
            OCRLine(text: "second", confidence: 1, bbox: [0.1, 0.70, 0.4, 0.03]),
            OCRLine(text: "right", confidence: 1, bbox: [0.6, 0.90, 0.2, 0.03]),
            OCRLine(text: "left", confidence: 1, bbox: [0.1, 0.90, 0.2, 0.03])
        ]
        XCTAssertEqual(VisionOCR.sortReadingOrder(lines).map(\.text), ["left", "right", "second"])
    }

    func testParagraphReconstructionAndHyphenation() {
        let lines = [
            OCRLine(text: "A care-", confidence: 1, bbox: [0.1, 0.90, 0.4, 0.03]),
            OCRLine(text: "fully joined line.", confidence: 1, bbox: [0.1, 0.86, 0.4, 0.03]),
            OCRLine(text: "New paragraph.", confidence: 1, bbox: [0.1, 0.76, 0.4, 0.03])
        ]
        XCTAssertEqual(VisionOCR.reconstructText(lines), "A carefully joined line.\n\nNew paragraph.")
    }

    func testIndentedKindleLineStartsParagraph() {
        let lines = [
            OCRLine(text: "First paragraph begins.", confidence: 1, bbox: [0.07, 0.90, 0.4, 0.03]),
            OCRLine(text: "It continues here.", confidence: 1, bbox: [0.04, 0.86, 0.4, 0.03]),
            OCRLine(text: "Second paragraph begins.", confidence: 1, bbox: [0.07, 0.82, 0.4, 0.03])
        ]
        XCTAssertEqual(VisionOCR.reconstructText(lines),
                       "First paragraph begins. It continues here.\n\nSecond paragraph begins.")
    }
}

import AppKit
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

    func testDetectsEnglishAndJapaneseText() {
        XCTAssertEqual(VisionOCR.detectLanguage(in: "This is an English sentence."), "en")
        XCTAssertEqual(VisionOCR.detectLanguage(in: "これは日本語の文章です。"), "ja")
        XCTAssertEqual(
            VisionOCR.detectLanguage(in: "override", requestedLanguage: "ja-JP"), "ja")
        XCTAssertEqual(
            VisionOCR.detectLanguage(in: "override", requestedLanguage: "fr-FR"), "fr")
    }

    func testDetectsOtherSupportedLanguages() {
        XCTAssertEqual(
            VisionOCR.detectLanguage(in: "Esta es una oración escrita completamente en español."),
            "es")
        XCTAssertEqual(
            VisionOCR.detectLanguage(in: "Ceci est une phrase entièrement écrite en français."),
            "fr")
        XCTAssertEqual(VisionOCR.detectLanguage(in: "这是一个用于测试语言识别的中文句子。"), "zh")
        XCTAssertEqual(VisionOCR.detectLanguage(in: "이것은 언어 감지를 확인하는 한국어 문장입니다."), "ko")
    }

    func testChineseHorizontalLinesAreJoinedWithoutSpaces() {
        let lines = [
            OCRLine(text: "这是中文", confidence: 1, bbox: [0.1, 0.90, 0.4, 0.03]),
            OCRLine(text: "句子。", confidence: 1, bbox: [0.1, 0.86, 0.4, 0.03])
        ]
        XCTAssertEqual(
            VisionOCR.reconstructText(lines, language: "zh"),
            "这是中文句子。")
    }

    func testJapaneseHorizontalLinesAreJoinedWithoutSpaces() {
        let lines = [
            OCRLine(text: "これは日本語の", confidence: 1, bbox: [0.1, 0.90, 0.4, 0.03]),
            OCRLine(text: "文章です。", confidence: 1, bbox: [0.1, 0.86, 0.4, 0.03])
        ]
        XCTAssertEqual(
            VisionOCR.reconstructText(lines, language: "ja"),
            "これは日本語の文章です。")
    }

    func testJapaneseVerticalColumnsUseRightToLeftOrder() {
        let lines = [
            OCRLine(text: "後の列。", confidence: 1, bbox: [0.45, 0.40, 0.03, 0.48]),
            OCRLine(text: "最初の列。", confidence: 1, bbox: [0.75, 0.40, 0.03, 0.48])
        ]
        XCTAssertEqual(VisionOCR.detectLayout(lines), "vertical")
        XCTAssertEqual(
            VisionOCR.reconstructText(lines, language: "ja", layout: "vertical"),
            "最初の列。後の列。")
    }

    func testVerticalJapaneseOutputNormalizationPreservesParagraphs() {
        XCTAssertEqual(
            VerticalJapaneseOCR.normalize("一行目\n二行目\n\n次の段落\r\nです\n"),
            "一行目二行目\n\n次の段落です")
    }

    func testSparseJapaneseVisionResultAttemptsVerticalFallback() {
        XCTAssertTrue(VerticalJapaneseOCR.shouldAttempt(
            visionText: "う", detectedLanguage: "ja", layout: "horizontal",
            requestedLanguage: "auto"))
        XCTAssertFalse(VerticalJapaneseOCR.shouldAttempt(
            visionText: "This horizontal English page has enough recognized text.",
            detectedLanguage: "en", layout: "horizontal", requestedLanguage: "auto"))
        XCTAssertFalse(VerticalJapaneseOCR.shouldAttempt(
            visionText: "う", detectedLanguage: "ja", layout: "horizontal",
            requestedLanguage: "en-US"))
    }

    func testVerticalFallbackMustBeSubstantiallyBetter() {
        XCTAssertTrue(VerticalJapaneseOCR.preferFallback(
            visionText: "う", fallbackText: "これは縦書き日本語の十分に長い本文です。次の文もあります。"))
        XCTAssertFalse(VerticalJapaneseOCR.preferFallback(
            visionText: "う", fallbackText: "短い文。"))
    }

    func testVisionRecognizesGeneratedJapanesePageInAutoMode() throws {
        let image = NSImage(size: NSSize(width: 1200, height: 260))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        ("これは日本語の文章です。次の文です。" as NSString).draw(
            at: NSPoint(x: 40, y: 90),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 64),
                .foregroundColor: NSColor.black
            ])
        image.unlockFocus()

        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return XCTFail("Could not render the Japanese OCR fixture")
        }
        let result = try VisionOCR.recognize(
            image: cgImage, language: "auto", accurate: true)
        XCTAssertEqual(result.detectedLanguage, "ja")
        XCTAssertTrue(result.text.contains("日本語"), result.text)
    }
}

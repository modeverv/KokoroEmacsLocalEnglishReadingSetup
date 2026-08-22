import Foundation
import CoreGraphics
import NaturalLanguage
import Vision

struct OCRLine: Codable, Equatable, Sendable {
    let text: String
    let confidence: Double
    /// Vision-normalized [x, y, width, height], origin at lower-left.
    let bbox: [Double]

    var x: Double { bbox[0] }
    var y: Double { bbox[1] }
    var width: Double { bbox[2] }
    var height: Double { bbox[3] }
}

struct OCRResult: Sendable {
    let text: String
    let lines: [OCRLine]
    let detectedLanguage: String
    let layout: String
    let engine: String
    let elapsedMilliseconds: Int
}

enum VisionOCR {
    /// Prefer Kokoro-supported languages, then common macOS speech fallbacks.
    /// The list is intersected with the languages supported by the running OS.
    static let preferredAutomaticRecognitionLanguages = [
        "en-US", "ja-JP", "zh-Hans", "zh-Hant", "es-ES", "fr-FR",
        "it-IT", "pt-BR", "de-DE", "ko-KR", "ru-RU", "uk-UA",
        "ar-SA", "th-TH", "vi-VT", "tr-TR", "id-ID", "nl-NL",
        "pl-PL", "sv-SE", "da-DK", "no-NO", "cs-CZ", "ro-RO", "ms-MY"
    ]

    static func automaticRecognitionLanguages(for request: VNRecognizeTextRequest) -> [String] {
        let supported = (try? request.supportedRecognitionLanguages()) ?? ["en-US", "ja-JP"]
        let candidates = preferredAutomaticRecognitionLanguages.filter(supported.contains)
        return candidates.isEmpty ? supported : candidates
    }

    static func detectLanguage(in text: String, requestedLanguage: String = "auto") -> String {
        let requested = requestedLanguage.lowercased()
        if requested != "auto" {
            if requested == "j" || requested.hasPrefix("ja") { return "ja" }
            if requested == "a" || requested == "b" || requested.hasPrefix("en") { return "en" }
            if requested.hasPrefix("zh") || requested.hasPrefix("yue") { return "zh" }
            if requested.hasPrefix("nb") || requested.hasPrefix("nn") { return "no" }
            if let primary = requested.split(separator: "-").first, !primary.isEmpty {
                return String(primary)
            }
        }

        let scalars = text.unicodeScalars
        let kanaCount = scalars.reduce(into: 0) { count, scalar in
            let value = scalar.value
            if (0x3040...0x30ff).contains(value) {
                count += 1
            }
        }
        let letterCount = scalars.reduce(into: 0) { count, scalar in
            if CharacterSet.letters.contains(scalar) { count += 1 }
        }
        if kanaCount >= 2 && kanaCount * 5 >= max(letterCount, 1) {
            return "ja"
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let rawLanguage = recognizer.dominantLanguage?.rawValue.lowercased() else {
            return "en"
        }
        if rawLanguage.hasPrefix("zh") || rawLanguage.hasPrefix("yue") { return "zh" }
        if rawLanguage.hasPrefix("ja") { return "ja" }
        if rawLanguage.hasPrefix("nb") || rawLanguage.hasPrefix("nn") { return "no" }
        return rawLanguage.split(separator: "-").first.map(String.init) ?? "en"
    }

    static func detectLayout(_ lines: [OCRLine]) -> String {
        guard !lines.isEmpty else { return "horizontal" }
        let widths = lines.map(\.width).sorted()
        let heights = lines.map(\.height).sorted()
        let medianWidth = widths[widths.count / 2]
        let medianHeight = heights[heights.count / 2]
        return medianHeight > medianWidth * 1.35 ? "vertical" : "horizontal"
    }

    static func sortReadingOrder(_ lines: [OCRLine], layout: String = "horizontal") -> [OCRLine] {
        lines.sorted {
            if layout == "vertical" {
                let delta = abs(($0.x + $0.width / 2) - ($1.x + $1.width / 2))
                if delta < max($0.width, $1.width) * 0.45 {
                    return ($0.y + $0.height / 2) > ($1.y + $1.height / 2)
                }
                return ($0.x + $0.width / 2) > ($1.x + $1.width / 2)
            } else {
                let delta = abs(($0.y + $0.height / 2) - ($1.y + $1.height / 2))
                if delta < max($0.height, $1.height) * 0.45 { return $0.x < $1.x }
                return ($0.y + $0.height / 2) > ($1.y + $1.height / 2)
            }
        }
    }

    static func reconstructText(
        _ input: [OCRLine],
        language: String = "en",
        layout: String = "horizontal"
    ) -> String {
        let lines = sortReadingOrder(input, layout: layout)
        guard !lines.isEmpty else { return "" }
        let unspacedCJK = language == "ja" || language == "zh"
        if layout == "vertical" {
            let separator = unspacedCJK ? "" : " "
            return lines.map(\.text).joined(separator: separator)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let heights = lines.map(\.height).sorted()
        let medianHeight = heights[heights.count / 2]
        let xPositions = lines.map(\.x).sorted()
        let leftEdge = xPositions[max(0, xPositions.count / 4)]
        let indentThreshold = leftEdge + medianHeight * 0.6
        var paragraphs: [String] = []
        var current = lines[0].text
        for index in 1..<lines.count {
            let previous = lines[index - 1]
            let line = lines[index]
            let verticalGap = previous.y - (line.y + line.height)
            let beginsIndentedParagraph = line.x > indentThreshold && previous.x <= indentThreshold
            if verticalGap > medianHeight * 0.85 || beginsIndentedParagraph {
                paragraphs.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = line.text
            } else if language == "en" && current.hasSuffix("-") && line.text.first?.isLowercase == true {
                current.removeLast()
                current += line.text
            } else {
                current += (unspacedCJK ? "" : " ") + line.text
            }
        }
        paragraphs.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        return paragraphs.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    static func recognize(image: CGImage, language: String, accurate: Bool) throws -> OCRResult {
        let started = ContinuousClock.now
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = accurate ? .accurate : .fast
        if language.lowercased() == "auto" {
            request.recognitionLanguages = automaticRecognitionLanguages(for: request)
            request.automaticallyDetectsLanguage = true
        } else {
            request.recognitionLanguages = [language]
        }
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        do { try handler.perform([request]) }
        catch { throw BridgeFailure(code: "OCR_FAILED", message: "Vision OCR failed: \(error.localizedDescription)") }
        let lines = (request.results ?? []).compactMap { observation -> OCRLine? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            return OCRLine(text: candidate.string,
                           confidence: Double(candidate.confidence),
                           bbox: [box.origin.x, box.origin.y, box.size.width, box.size.height])
        }
        let rawText = lines.map(\.text).joined(separator: " ")
        let visionLanguage = detectLanguage(in: rawText, requestedLanguage: language)
        let visionLayout = ["ja", "zh"].contains(visionLanguage)
            ? detectLayout(lines) : "horizontal"
        let ordered = sortReadingOrder(lines, layout: visionLayout)
        let visionText = reconstructText(ordered, language: visionLanguage, layout: visionLayout)
        var text = visionText
        var resultLines = ordered
        var detectedLanguage = visionLanguage
        var layout = visionLayout
        var engine = "vision"

        if VerticalJapaneseOCR.shouldAttempt(
            visionText: visionText,
            detectedLanguage: visionLanguage,
            layout: visionLayout,
            requestedLanguage: language
        ), let verticalText = VerticalJapaneseOCR.recognize(image: image),
           VerticalJapaneseOCR.preferFallback(
            visionText: visionText, fallbackText: verticalText) {
            text = verticalText
            resultLines = [OCRLine(text: verticalText, confidence: 0.6, bbox: [0, 0, 1, 1])]
            detectedLanguage = "ja"
            layout = "vertical"
            engine = "tesseract-jpn-vert"
        }
        guard !text.isEmpty else {
            throw BridgeFailure(code: "NO_TEXT", message: "Vision recognized no text in the configured crop")
        }
        let duration = started.duration(to: .now)
        let milliseconds = Int(duration.components.seconds * 1000) + Int(duration.components.attoseconds / 1_000_000_000_000_000)
        return OCRResult(text: text, lines: resultLines, detectedLanguage: detectedLanguage,
                         layout: layout, engine: engine, elapsedMilliseconds: milliseconds)
    }
}

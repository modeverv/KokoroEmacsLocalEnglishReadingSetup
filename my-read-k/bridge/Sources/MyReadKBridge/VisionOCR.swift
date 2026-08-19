import Foundation
import CoreGraphics
import Vision

struct OCRLine: Codable, Equatable, Sendable {
    let text: String
    let confidence: Double
    /// Vision-normalized [x, y, width, height], origin at lower-left.
    let bbox: [Double]

    var x: Double { bbox[0] }
    var y: Double { bbox[1] }
    var height: Double { bbox[3] }
}

struct OCRResult: Sendable {
    let text: String
    let lines: [OCRLine]
    let elapsedMilliseconds: Int
}

enum VisionOCR {
    static func sortReadingOrder(_ lines: [OCRLine]) -> [OCRLine] {
        lines.sorted {
            let delta = abs(($0.y + $0.height / 2) - ($1.y + $1.height / 2))
            if delta < max($0.height, $1.height) * 0.45 { return $0.x < $1.x }
            return ($0.y + $0.height / 2) > ($1.y + $1.height / 2)
        }
    }

    static func reconstructText(_ input: [OCRLine]) -> String {
        let lines = sortReadingOrder(input)
        guard !lines.isEmpty else { return "" }
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
            } else if current.hasSuffix("-") && line.text.first?.isLowercase == true {
                current.removeLast()
                current += line.text
            } else {
                current += " " + line.text
            }
        }
        paragraphs.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        return paragraphs.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    static func recognize(image: CGImage, language: String, accurate: Bool) throws -> OCRResult {
        let started = ContinuousClock.now
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = accurate ? .accurate : .fast
        request.recognitionLanguages = [language]
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
        let ordered = sortReadingOrder(lines)
        let text = reconstructText(ordered)
        guard !text.isEmpty else {
            throw BridgeFailure(code: "NO_TEXT", message: "Vision recognized no English text in the configured crop")
        }
        let duration = started.duration(to: .now)
        let milliseconds = Int(duration.components.seconds * 1000) + Int(duration.components.attoseconds / 1_000_000_000_000_000)
        return OCRResult(text: text, lines: ordered, elapsedMilliseconds: milliseconds)
    }
}

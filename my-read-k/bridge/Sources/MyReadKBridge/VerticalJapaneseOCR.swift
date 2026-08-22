import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum VerticalJapaneseOCR {
    static let minimumUsefulJapaneseCharacters = 12

    static func japaneseCharacterCount(in text: String) -> Int {
        text.unicodeScalars.reduce(into: 0) { count, scalar in
            let value = scalar.value
            if (0x3040...0x30ff).contains(value)
                || (0x3400...0x4dbf).contains(value)
                || (0x4e00...0x9fff).contains(value) {
                count += 1
            }
        }
    }

    static func shouldAttempt(
        visionText: String,
        detectedLanguage: String,
        layout: String,
        requestedLanguage: String
    ) -> Bool {
        let requested = requestedLanguage.lowercased()
        let allowsJapanese = requested == "auto" || requested == "j" || requested.hasPrefix("ja")
        guard allowsJapanese else { return false }
        return layout == "vertical"
            || detectedLanguage == "ja" && japaneseCharacterCount(in: visionText) < minimumUsefulJapaneseCharacters
            || requested == "auto" && visionText.trimmingCharacters(in: .whitespacesAndNewlines).count < minimumUsefulJapaneseCharacters
    }

    static func preferFallback(visionText: String, fallbackText: String) -> Bool {
        let fallbackCount = japaneseCharacterCount(in: fallbackText)
        let visionCount = japaneseCharacterCount(in: visionText)
        return fallbackCount >= minimumUsefulJapaneseCharacters
            && fallbackCount >= max(visionCount * 2, minimumUsefulJapaneseCharacters)
    }

    static func normalize(_ output: String) -> String {
        let canonical = output.replacingOccurrences(of: "\r\n", with: "\n")
        let paragraphs = canonical.components(separatedBy: "\n\n")
        return paragraphs.compactMap { paragraph -> String? in
            let joined = paragraph.split(separator: "\n", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return joined.isEmpty ? nil : joined
        }.joined(separator: "\n\n")
    }

    static func recognize(image: CGImage) -> String? {
        guard let executable = tesseractExecutable(),
              let tessdata = tessdataDirectory(),
              FileManager.default.fileExists(
                atPath: tessdata.appendingPathComponent("jpn_vert.traineddata").path)
        else { return nil }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("my-read-k-vertical-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: temporaryDirectory, withIntermediateDirectories: false)
        } catch {
            return nil
        }
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let inputURL = temporaryDirectory.appendingPathComponent("input.png")
        guard writePNG(image, to: inputURL) else { return nil }

        let standardOutput = Pipe()
        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = temporaryDirectory
        process.arguments = ["input.png", "stdout", "-l", "jpn_vert", "--psm", "5"]
        process.standardOutput = standardOutput
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["TESSDATA_PREFIX"] = tessdata.path
        process.environment = environment

        do {
            try process.run()
            let data = standardOutput.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let output = String(data: data, encoding: .utf8)
            else { return nil }
            let text = normalize(output)
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
    }

    private static func tesseractExecutable() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        let candidates = [
            environment["MY_READ_K_TESSERACT"],
            "/opt/homebrew/bin/tesseract",
            "/usr/local/bin/tesseract"
        ].compactMap { $0 }
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            .map { URL(fileURLWithPath: $0) }
    }

    private static func tessdataDirectory() -> URL? {
        if let override = ProcessInfo.processInfo.environment["MY_READ_K_TESSDATA"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/my-read-k/tessdata", isDirectory: true)
    }

    private static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }
}

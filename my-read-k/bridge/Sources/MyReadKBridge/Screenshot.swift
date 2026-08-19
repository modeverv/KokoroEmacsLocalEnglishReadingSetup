import Foundation
import CoreGraphics
import CryptoKit
import ImageIO

struct NormalizedCrop: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(x: Double, y: Double, width: Double, height: Double) throws {
        guard x >= 0, y >= 0, width > 0, height > 0,
              x + width <= 1, y + height <= 1 else {
            throw BridgeFailure(code: "INVALID_CROP", message: "Crop must be a positive normalized top-left rectangle within 0...1")
        }
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    static func from(_ params: [String: JSONValue]) throws -> NormalizedCrop {
        try NormalizedCrop(
            x: params.double("x", default: 0),
            y: params.double("y", default: 0),
            width: params.double("width", default: 1),
            height: params.double("height", default: 1))
    }

    func pixelRect(imageWidth: Int, imageHeight: Int) -> CGRect {
        CGRect(x: Double(imageWidth) * x,
               y: Double(imageHeight) * y,
               width: Double(imageWidth) * width,
               height: Double(imageHeight) * height).integral
    }
}

struct ScreenshotImage: Sendable {
    let image: CGImage
    let pngData: Data

    init(pngData: Data) throws {
        guard let source = CGImageSourceCreateWithData(pngData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw BridgeFailure(code: "SCREENSHOT_FAILED", message: "Cannot decode screenshot PNG")
        }
        self.image = image
        self.pngData = pngData
    }

    func cropped(to crop: NormalizedCrop) throws -> CGImage {
        let rect = crop.pixelRect(imageWidth: image.width, imageHeight: image.height)
        guard let result = image.cropping(to: rect) else {
            throw BridgeFailure(code: "INVALID_CROP", message: "Crop produced an empty image")
        }
        return result
    }

    var fingerprint: String {
        SHA256.hash(data: pngData).map { String(format: "%02x", $0) }.joined()
    }
}

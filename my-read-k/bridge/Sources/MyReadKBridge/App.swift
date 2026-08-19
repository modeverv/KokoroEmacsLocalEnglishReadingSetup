import Foundation

final class BridgeRuntime {
    private var target: ChromeTarget?
    private var client: CDPClient?

    func handle(_ request: BridgeRequest) async -> BridgeResponse {
        do {
            let result: [String: JSONValue]
            switch request.command {
            case "hello":
                result = [
                    "protocolVersion": .number(1),
                    "bridgeVersion": .string("0.1.0"),
                    "capabilities": .array(["capture", "ocr", "next", "prev", "status"].map(JSONValue.string))
                ]
            case "attach": result = try await attach(params: request.params)
            case "capture": result = try await capture(params: request.params)
            case "next": result = try await navigate(.next, params: request.params)
            case "prev": result = try await navigate(.previous, params: request.params)
            case "status": result = status()
            default:
                throw BridgeFailure(code: "INVALID_REQUEST", message: "Unknown command: \(request.command)")
            }
            return .success(id: request.id, generation: request.generation, result: result)
        } catch let error as BridgeFailure {
            return .failure(id: request.id, generation: request.generation, code: error.code, message: error.message)
        } catch {
            return .failure(id: request.id, generation: request.generation, code: "INTERNAL_ERROR", message: error.localizedDescription)
        }
    }

    private func attach(params: [String: JSONValue]) async throws -> [String: JSONValue] {
        let host = params.string("cdpHost", default: "127.0.0.1")!
        let port = params.int("cdpPort", default: 9222)
        let pattern = params.string("urlPattern", default: "read.amazon")!
        let selected = try await ChromeTarget.discover(host: host, port: port, urlPattern: pattern)
        guard let string = selected.webSocketDebuggerUrl, let url = URL(string: string) else {
            throw BridgeFailure(code: "NO_KINDLE_TARGET", message: "Matching target has no debugger WebSocket URL")
        }
        target = selected
        client = CDPClient(webSocketURL: url)
        return ["targetId": .string(selected.id), "title": .string(selected.title), "url": .string(selected.url)]
    }

    private func capture(params: [String: JSONValue], settledImage: ScreenshotImage? = nil) async throws -> [String: JSONValue] {
        guard let client else { throw BridgeFailure(code: "TARGET_DISCONNECTED", message: "Attach to a Kindle target first") }
        let captureParams = params.object("capture") ?? params
        let crop = try NormalizedCrop.from(captureParams.object("crop") ?? [:])
        let language = captureParams.string("language", default: "en-US")!
        let accurate = captureParams.string("recognition", default: "accurate") != "fast"
        let screenshot: ScreenshotImage
        if let settledImage {
            screenshot = settledImage
        } else {
            screenshot = try ScreenshotImage(pngData: await client.captureScreenshot())
        }
        let cropped = try screenshot.cropped(to: crop)
        let ocr = try VisionOCR.recognize(image: cropped, language: language, accurate: accurate)
        return [
            "fingerprint": .string(screenshot.fingerprint),
            "imageWidth": .number(Double(screenshot.image.width)),
            "imageHeight": .number(Double(screenshot.image.height)),
            "ocrMs": .number(Double(ocr.elapsedMilliseconds)),
            "text": .string(ocr.text),
            "lines": .array(ocr.lines.map { line in
                .object(["text": .string(line.text),
                         "confidence": .number(line.confidence),
                         "bbox": .array(line.bbox.map(JSONValue.number))])
            })
        ]
    }

    private func navigate(_ direction: PageDirection, params: [String: JSONValue]) async throws -> [String: JSONValue] {
        guard let client else { throw BridgeFailure(code: "TARGET_DISCONNECTED", message: "Attach to a Kindle target first") }
        let before = try ScreenshotImage(pngData: await client.captureScreenshot())
        try await client.dispatchArrow(direction: direction)
        try await Task.sleep(for: .milliseconds(400))
        let keyboardProbe = try ScreenshotImage(pngData: await client.captureScreenshot())
        let input: String
        if keyboardProbe.fingerprint == before.fingerprint {
            try await client.clickPageEdge(direction: direction)
            input = "mouse"
        } else {
            input = "keyboard"
        }
        let options = SettleOptions.from(params.object("settle") ?? [:])
        let settled = try await PageSettler.wait(client: client, before: before.fingerprint, options: options)
        var result = try await capture(params: params, settledImage: settled)
        result["navigation"] = .string(direction == .next ? "next" : "prev")
        result["input"] = .string(input)
        return result
    }

    private func status() -> [String: JSONValue] {
        guard let target else { return ["connected": .bool(false)] }
        return [
            "connected": .bool(client != nil),
            "target": .object(["title": .string(target.title), "url": .string(target.url)])
        ]
    }
}

@main
enum Main {
    static func main() async {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let runtime = BridgeRuntime()
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty else { continue }
            let response: BridgeResponse
            do {
                let request = try decoder.decode(BridgeRequest.self, from: Data(line.utf8))
                response = await runtime.handle(request)
            } catch {
                response = .failure(id: 0, generation: 0, code: "INVALID_REQUEST", message: error.localizedDescription)
            }
            do {
                let data = try encoder.encode(response)
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data([0x0A]))
            } catch {
                FileHandle.standardError.write(Data("response encoding failed: \(error)\n".utf8))
            }
        }
    }
}

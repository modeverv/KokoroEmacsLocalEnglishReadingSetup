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
                    "capabilities": .array([
                        "capture", "ocr", "next", "prev", "prefetchNext",
                        "advanceNext", "advancePrev", "status"
                    ].map(JSONValue.string))
                ]
            case "attach": result = try await attach(params: request.params)
            case "capture": result = try await capture(params: request.params)
            case "next": result = try await navigate(.next, params: request.params)
            case "prev": result = try await navigate(.previous, params: request.params)
            case "prefetchNext": result = try await prefetchNext(params: request.params)
            case "advanceNext": result = try await advance(.next, params: request.params)
            case "advancePrev": result = try await advance(.previous, params: request.params)
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
        let crop = try captureCrop(params)
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
            "fingerprint": .string(try screenshot.contentFingerprint(crop: crop)),
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

    private func captureCrop(_ params: [String: JSONValue]) throws -> NormalizedCrop {
        let captureParams = params.object("capture") ?? params
        return try NormalizedCrop.from(captureParams.object("crop") ?? [:])
    }

    private func turnAndSettle(
        _ direction: PageDirection,
        before: ScreenshotImage,
        crop: NormalizedCrop,
        options: SettleOptions
    ) async throws -> (image: ScreenshotImage, input: String) {
        guard let client else { throw BridgeFailure(code: "TARGET_DISCONNECTED", message: "Attach to a Kindle target first") }
        try await client.dispatchArrow(direction: direction)
        try await Task.sleep(for: .milliseconds(400))
        let keyboardProbe = try ScreenshotImage(pngData: await client.captureScreenshot())
        let input: String
        let beforeFingerprint = try before.contentFingerprint(crop: crop)
        if try keyboardProbe.contentFingerprint(crop: crop) == beforeFingerprint {
            try await client.clickPageEdge(direction: direction)
            input = "mouse"
        } else {
            input = "keyboard"
        }
        let settled = try await PageSettler.wait(
            client: client, before: beforeFingerprint, crop: crop, options: options)
        return (settled, input)
    }

    private func navigate(_ direction: PageDirection, params: [String: JSONValue]) async throws -> [String: JSONValue] {
        guard let client else { throw BridgeFailure(code: "TARGET_DISCONNECTED", message: "Attach to a Kindle target first") }
        let before = try ScreenshotImage(pngData: await client.captureScreenshot())
        let crop = try captureCrop(params)
        let options = SettleOptions.from(params.object("settle") ?? [:])
        let turn = try await turnAndSettle(direction, before: before, crop: crop, options: options)
        let settled = turn.image
        var result = try await capture(params: params, settledImage: settled)
        result["navigation"] = .string(direction == .next ? "next" : "prev")
        result["input"] = .string(turn.input)
        return result
    }

    private func prefetchNext(params: [String: JSONValue]) async throws -> [String: JSONValue] {
        guard let client else { throw BridgeFailure(code: "TARGET_DISCONNECTED", message: "Attach to a Kindle target first") }
        let source = try ScreenshotImage(pngData: await client.captureScreenshot())
        let crop = try captureCrop(params)
        let sourceFingerprint = try source.contentFingerprint(crop: crop)
        let options = SettleOptions.from(params.object("settle") ?? [:])
        let requestedCount = min(max(params.int("prefetchCount", default: 1), 1), 2)
        var current = source
        var pages: [[String: JSONValue]] = []
        var inputs: [JSONValue] = []
        var successfulTurns = 0

        do {
            for _ in 0..<requestedCount {
                let nextTurn: (image: ScreenshotImage, input: String)
                do {
                    nextTurn = try await turnAndSettle(
                        .next, before: current, crop: crop, options: options)
                } catch let failure as BridgeFailure
                    where failure.code == "PAGE_DID_NOT_CHANGE" && !pages.isEmpty {
                    break
                }
                successfulTurns += 1
                current = nextTurn.image
                inputs.append(.string(nextTurn.input))
                do {
                    pages.append(try await capture(params: params, settledImage: current))
                } catch let failure as BridgeFailure
                    where failure.code == "NO_TEXT" && !pages.isEmpty {
                    // Keep the contiguous pages already captured. A blank or
                    // illustration page farther ahead must not discard page 1.
                    break
                }
            }
        } catch {
            for _ in 0..<successfulTurns {
                if let restored = try? await turnAndSettle(
                    .previous, before: current, crop: crop, options: options) {
                    current = restored.image
                }
            }
            throw error
        }

        var restoreInputs: [JSONValue] = []
        for _ in 0..<successfulTurns {
            let restore = try await turnAndSettle(
                .previous, before: current, crop: crop, options: options)
            current = restore.image
            restoreInputs.append(.string(restore.input))
        }
        guard try current.contentFingerprint(crop: crop) == sourceFingerprint else {
            throw BridgeFailure(
                code: "PREFETCH_RESTORE_FAILED",
                message: "Prefetch finished, but Chrome did not return to the source page")
        }

        guard var result = pages.first else {
            throw BridgeFailure(code: "PAGE_DID_NOT_CHANGE", message: "No next page was available to prefetch")
        }
        result["pages"] = .array(pages.map(JSONValue.object))
        result["prefetchSourceFingerprint"] = .string(sourceFingerprint)
        result["navigation"] = .string("prefetchNext")
        result["input"] = .array(inputs)
        result["restoreInput"] = .array(restoreInputs)
        return result
    }

    private func advance(_ direction: PageDirection, params: [String: JSONValue]) async throws -> [String: JSONValue] {
        guard let client else { throw BridgeFailure(code: "TARGET_DISCONNECTED", message: "Attach to a Kindle target first") }
        let source = try ScreenshotImage(pngData: await client.captureScreenshot())
        let crop = try captureCrop(params)
        let options = SettleOptions.from(params.object("settle") ?? [:])
        let turn = try await turnAndSettle(direction, before: source, crop: crop, options: options)
        let navigation = direction == .next ? "advanceNext" : "advancePrev"
        return [
            "fingerprint": .string(try turn.image.contentFingerprint(crop: crop)),
            "navigation": .string(navigation),
            "input": .string(turn.input)
        ]
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

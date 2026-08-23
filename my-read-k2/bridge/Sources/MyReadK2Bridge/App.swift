import Foundation

final class BridgeRuntime {
    private let client = KindleAppClient()
    private var attached = false
    private var targetTitle = "Kindle.app"

    func handle(_ request: BridgeRequest) -> BridgeResponse {
        do {
            let result: [String: JSONValue]
            switch request.command {
            case "hello":
                result = [
                    "protocolVersion": .number(1),
                    "bridgeVersion": .string("0.1.0"),
                    "backend": .string("kindle-app-accessibility"),
                    "capabilities": .array([
                        "capture", "next", "prev", "prefetchNext",
                        "advanceNext", "advancePrev", "status"
                    ].map(JSONValue.string))
                ]
            case "attach": result = try attach(params: request.params)
            case "capture": result = try capture()
            case "next": result = try navigate(.next, params: request.params)
            case "prev": result = try navigate(.previous, params: request.params)
            case "prefetchNext": result = try prefetchNext(params: request.params)
            case "advanceNext": result = try advance(.next, params: request.params)
            case "advancePrev": result = try advance(.previous, params: request.params)
            case "status": result = status()
            default:
                throw BridgeFailure(code: "INVALID_REQUEST",
                                    message: "Unknown command: \(request.command)")
            }
            return .success(id: request.id, generation: request.generation, result: result)
        } catch let error as BridgeFailure {
            return .failure(id: request.id, generation: request.generation,
                            code: error.code, message: error.message)
        } catch {
            return .failure(id: request.id, generation: request.generation,
                            code: "INTERNAL_ERROR", message: error.localizedDescription)
        }
    }

    private func attach(params: [String: JSONValue]) throws -> [String: JSONValue] {
        var result = try client.attach()
        targetTitle = KindleBookTitle.resolve(
            override: params.string("bookTitle"),
            detected: result["title"]?.string)
        result["title"] = .string(targetTitle)
        attached = true
        return result
    }

    private func pageResult(_ page: KindlePage) -> [String: JSONValue] {
        [
            "fingerprint": .string(page.fingerprint),
            "language": .string("en"),
            "text": .string(page.text)
        ]
    }

    private func capture() throws -> [String: JSONValue] {
        guard attached else {
            throw BridgeFailure(code: "TARGET_DISCONNECTED", message: "Attach to Kindle.app first.")
        }
        return pageResult(try client.capturePage())
    }

    private func navigationOptions(_ params: [String: JSONValue])
        -> (poll: Int, stable: Int, timeout: Int) {
        let settle = params.object("settle") ?? [:]
        return (settle.int("pollMs", default: 100),
                settle.int("stableSamples", default: 2),
                settle.int("timeoutMs", default: 4000))
    }

    private func navigate(_ direction: PageDirection,
                          params: [String: JSONValue]) throws -> [String: JSONValue] {
        let options = navigationOptions(params)
        let page = try client.turn(direction, pollMilliseconds: options.poll,
                                   stableSamples: options.stable,
                                   timeoutMilliseconds: options.timeout)
        var result = pageResult(page)
        result["navigation"] = .string(direction == .next ? "next" : "prev")
        result["input"] = .string("accessibility-keyboard")
        return result
    }

    private func advance(_ direction: PageDirection,
                         params: [String: JSONValue]) throws -> [String: JSONValue] {
        let options = navigationOptions(params)
        let page = try client.turn(direction, pollMilliseconds: options.poll,
                                   stableSamples: options.stable,
                                   timeoutMilliseconds: options.timeout)
        return [
            "fingerprint": .string(page.fingerprint),
            "navigation": .string(direction == .next ? "advanceNext" : "advancePrev"),
            "input": .string("accessibility-keyboard")
        ]
    }

    private func prefetchNext(params: [String: JSONValue]) throws -> [String: JSONValue] {
        let source = try client.capturePage()
        let options = navigationOptions(params)
        let count = min(max(params.int("prefetchCount", default: 1), 1), 2)
        var pages: [[String: JSONValue]] = []
        var successfulTurns = 0

        do {
            for _ in 0..<count {
                do {
                    let page = try client.turn(.next, pollMilliseconds: options.poll,
                                               stableSamples: options.stable,
                                               timeoutMilliseconds: options.timeout)
                    successfulTurns += 1
                    pages.append(pageResult(page))
                } catch let failure as BridgeFailure
                    where failure.code == "PAGE_DID_NOT_CHANGE" && !pages.isEmpty {
                    break
                }
            }
        } catch {
            for _ in 0..<successfulTurns {
                _ = try? client.turn(.previous, pollMilliseconds: options.poll,
                                     stableSamples: options.stable,
                                     timeoutMilliseconds: options.timeout)
            }
            throw error
        }

        for _ in 0..<successfulTurns {
            _ = try client.turn(.previous, pollMilliseconds: options.poll,
                                stableSamples: options.stable,
                                timeoutMilliseconds: options.timeout)
        }
        guard try client.capturePage().fingerprint == source.fingerprint else {
            throw BridgeFailure(
                code: "PREFETCH_RESTORE_FAILED",
                message: "Prefetch did not restore the original Kindle.app page.")
        }
        guard var result = pages.first else {
            throw BridgeFailure(code: "PAGE_DID_NOT_CHANGE",
                                message: "No next Kindle.app page was available.")
        }
        result["pages"] = .array(pages.map(JSONValue.object))
        result["prefetchSourceFingerprint"] = .string(source.fingerprint)
        result["navigation"] = .string("prefetchNext")
        result["input"] = .array(Array(repeating: .string("accessibility-keyboard"),
                                        count: successfulTurns))
        result["restoreInput"] = .array(Array(repeating: .string("accessibility-keyboard"),
                                               count: successfulTurns))
        return result
    }

    private func status() -> [String: JSONValue] {
        [
            "connected": .bool(attached),
            "target": .object([
                "title": .string(targetTitle),
                "url": .string("kindle-app://reader")
            ])
        ]
    }
}

@main
enum Main {
    static func main() {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let runtime = BridgeRuntime()
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty else { continue }
            let response: BridgeResponse
            do {
                let request = try decoder.decode(BridgeRequest.self, from: Data(line.utf8))
                response = runtime.handle(request)
            } catch {
                response = .failure(id: 0, generation: 0, code: "INVALID_REQUEST",
                                    message: error.localizedDescription)
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

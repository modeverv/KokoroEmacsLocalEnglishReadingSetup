import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class CDPClient: @unchecked Sendable {
    private let socket: URLSessionWebSocketTask
    private var nextID = 0

    init(webSocketURL: URL) {
        let task = URLSession.shared.webSocketTask(with: webSocketURL)
        // CDP returns PNG screenshots as base64 inside one JSON message. Dense
        // text pages can exceed URLSessionWebSocketTask's small default limit.
        task.maximumMessageSize = 16 * 1024 * 1024
        socket = task
        socket.resume()
    }

    deinit { socket.cancel(with: .goingAway, reason: nil) }

    func call(method: String, params: [String: JSONValue] = [:]) async throws -> [String: JSONValue] {
        nextID += 1
        let id = nextID
        let payload: JSONValue = .object([
            "id": .number(Double(id)),
            "method": .string(method),
            "params": .object(params)
        ])
        let data = try JSONEncoder().encode(payload)
        guard let text = String(data: data, encoding: .utf8) else {
            throw BridgeFailure(code: "CDP_PROTOCOL_ERROR", message: "Cannot encode CDP request")
        }
        do {
            try await socket.send(.string(text))
            while true {
                let message = try await socket.receive()
                let responseData: Data
                switch message {
                case .string(let value): responseData = Data(value.utf8)
                case .data(let value): responseData = value
                @unknown default: continue
                }
                let decoded = try JSONDecoder().decode(JSONValue.self, from: responseData)
                guard let object = decoded.object,
                      Int(object["id"]?.number ?? -1) == id else { continue }
                if let error = object["error"]?.object {
                    let message = error["message"]?.string ?? "Unknown CDP error"
                    throw BridgeFailure(code: "CDP_PROTOCOL_ERROR", message: message)
                }
                return object["result"]?.object ?? [:]
            }
        } catch let error as BridgeFailure {
            throw error
        } catch {
            throw BridgeFailure(code: "TARGET_DISCONNECTED", message: "Chrome target disconnected: \(error.localizedDescription)")
        }
    }

    func captureScreenshot() async throws -> Data {
        let result = try await call(method: "Page.captureScreenshot", params: [
            "format": .string("png"),
            "fromSurface": .bool(true),
            "captureBeyondViewport": .bool(false)
        ])
        guard let encoded = result["data"]?.string,
              let data = Data(base64Encoded: encoded) else {
            throw BridgeFailure(code: "SCREENSHOT_FAILED", message: "CDP returned no screenshot data")
        }
        return data
    }

    func dispatchArrow(direction: PageDirection) async throws {
        let key = direction == .next ? "ArrowRight" : "ArrowLeft"
        let virtualKey = direction == .next ? 39 : 37
        for type in ["rawKeyDown", "keyUp"] {
            _ = try await call(method: "Input.dispatchKeyEvent", params: [
                "type": .string(type),
                "key": .string(key),
                "code": .string(key),
                "windowsVirtualKeyCode": .number(Double(virtualKey)),
                "nativeVirtualKeyCode": .number(Double(virtualKey))
            ])
        }
    }

    func clickPageEdge(direction: PageDirection) async throws {
        let metrics = try await call(method: "Page.getLayoutMetrics")
        guard let viewport = metrics["cssVisualViewport"]?.object,
              let width = viewport["clientWidth"]?.number,
              let height = viewport["clientHeight"]?.number else {
            throw BridgeFailure(code: "CDP_PROTOCOL_ERROR", message: "Chrome returned no visual viewport metrics")
        }
        let x = width * (direction == .next ? 0.92 : 0.08)
        let y = height * 0.5
        for type in ["mousePressed", "mouseReleased"] {
            _ = try await call(method: "Input.dispatchMouseEvent", params: [
                "type": .string(type),
                "x": .number(x),
                "y": .number(y),
                "button": .string("left"),
                "clickCount": .number(1)
            ])
        }
    }
}

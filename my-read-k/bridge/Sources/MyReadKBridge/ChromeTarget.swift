import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct ChromeTarget: Codable, Equatable, Sendable {
    let id: String
    let type: String
    let title: String
    let url: String
    let webSocketDebuggerUrl: String?

    enum CodingKeys: String, CodingKey {
        case id, type, title, url, webSocketDebuggerUrl
    }

    static func select(from targets: [ChromeTarget], urlPattern: String) -> ChromeTarget? {
        targets.first {
            $0.type == "page" &&
            $0.url.localizedCaseInsensitiveContains(urlPattern) &&
            $0.webSocketDebuggerUrl != nil
        }
    }

    static func discover(host: String, port: Int, urlPattern: String) async throws -> ChromeTarget {
        guard let url = URL(string: "http://\(host):\(port)/json/list") else {
            throw BridgeFailure(code: "CDP_UNAVAILABLE", message: "Invalid CDP host or port")
        }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 3
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw BridgeFailure(code: "CDP_UNAVAILABLE", message: "Chrome debugging endpoint returned an error")
            }
            let targets = try JSONDecoder().decode([ChromeTarget].self, from: data)
            guard let target = select(from: targets, urlPattern: urlPattern) else {
                throw BridgeFailure(code: "NO_KINDLE_TARGET", message: "No matching Kindle Web Reader target found")
            }
            return target
        } catch let error as BridgeFailure {
            throw error
        } catch {
            throw BridgeFailure(code: "CDP_UNAVAILABLE", message: "Cannot reach Chrome debugging endpoint: \(error.localizedDescription)")
        }
    }
}

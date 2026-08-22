import AppKit
import ApplicationServices
import CryptoKit
import Foundation

enum PageDirection {
    case next
    case previous

    var keyCode: CGKeyCode { self == .next ? 124 : 123 }
}

struct KindlePage: Equatable, Sendable {
    let text: String
    let identifier: String
    let start: Int?
    let end: Int?

    var fingerprint: String {
        if let start, let end { return "kindle-position:\(start)-\(end)" }
        let digest = SHA256.hash(data: Data((identifier + "\n" + text).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func positions(from identifier: String) -> (start: Int?, end: Int?) {
        guard identifier.hasPrefix("pageDetails:"),
              let data = String(identifier.dropFirst("pageDetails:".count)).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return (nil, nil) }

        func short(_ key: String) -> Int? {
            (json[key] as? [String: Any])?["short"] as? Int
        }
        return (short("start"), short("end"))
    }
}

final class KindleAppClient {
    static let bundleIdentifier = "com.amazon.Lassen"

    private(set) var application: NSRunningApplication?
    private var appElement: AXUIElement?

    func attach() throws -> [String: JSONValue] {
        guard let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.bundleIdentifier).first
        else {
            throw BridgeFailure(
                code: "NO_KINDLE_APP",
                message: "Kindle.app is not running. Open an English book in Kindle first.")
        }
        guard AXIsProcessTrusted() else {
            throw BridgeFailure(
                code: "ACCESSIBILITY_PERMISSION_REQUIRED",
                message: "Emacs (or the launching terminal) needs macOS Accessibility permission to read Kindle.app.")
        }
        application = running
        appElement = AXUIElementCreateApplication(running.processIdentifier)
        _ = try capturePage()
        return [
            "targetId": .string(String(running.processIdentifier)),
            "title": .string("Kindle.app"),
            "url": .string("kindle-app://reader")
        ]
    }

    func capturePage() throws -> KindlePage {
        guard let appElement else {
            throw BridgeFailure(code: "TARGET_DISCONNECTED", message: "Attach to Kindle.app first.")
        }
        guard let pageElement = findPageElement(in: appElement, depth: 0) else {
            throw BridgeFailure(
                code: "NO_PAGE_TEXT",
                message: "No open Kindle page was found. Open an English book and try again.")
        }
        let identifier = stringAttribute(kAXIdentifierAttribute, of: pageElement) ?? ""
        guard let rawText = stringAttribute(kAXValueAttribute, of: pageElement) else {
            throw BridgeFailure(code: "NO_PAGE_TEXT", message: "Kindle exposed no page text.")
        }
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw BridgeFailure(code: "NO_PAGE_TEXT", message: "The current Kindle page is empty.")
        }
        let positions = KindlePage.positions(from: identifier)
        return KindlePage(text: text, identifier: identifier,
                          start: positions.start, end: positions.end)
    }

    func turn(_ direction: PageDirection, pollMilliseconds: Int,
              stableSamples: Int, timeoutMilliseconds: Int) throws -> KindlePage {
        guard let application else {
            throw BridgeFailure(code: "TARGET_DISCONNECTED", message: "Attach to Kindle.app first.")
        }
        let before = try capturePage()
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source,
                                 virtualKey: direction.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source,
                               virtualKey: direction.keyCode, keyDown: false)
        else {
            throw BridgeFailure(code: "INPUT_FAILED", message: "Could not create a Kindle page-turn event.")
        }
        down.postToPid(application.processIdentifier)
        Thread.sleep(forTimeInterval: 0.02)
        up.postToPid(application.processIdentifier)

        let poll = max(pollMilliseconds, 25)
        let timeout = max(timeoutMilliseconds, poll)
        let requiredStableSamples = max(stableSamples, 1)
        var elapsed = 0
        var lastChangedPage: KindlePage?
        var stableCount = 0
        while elapsed <= timeout {
            Thread.sleep(forTimeInterval: Double(poll) / 1000.0)
            elapsed += poll
            guard let page = try? capturePage(), page.fingerprint != before.fingerprint else {
                continue
            }
            if page.fingerprint == lastChangedPage?.fingerprint {
                stableCount += 1
            } else {
                lastChangedPage = page
                stableCount = 1
            }
            if stableCount >= requiredStableSamples {
                return page
            }
        }
        throw BridgeFailure(
            code: "PAGE_DID_NOT_CHANGE",
            message: "Kindle.app did not change pages after the arrow-key event.")
    }

    private func findPageElement(in element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth <= 10 else { return nil }
        if let identifier = stringAttribute(kAXIdentifierAttribute, of: element),
           identifier.hasPrefix("pageDetails:") {
            return element
        }
        for child in elementsAttribute(kAXChildrenAttribute, of: element) {
            if let found = findPageElement(in: child, depth: depth + 1) { return found }
        }
        return nil
    }

    private func stringAttribute(_ attribute: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    private func elementsAttribute(_ attribute: String, of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let elements = value as? [AXUIElement]
        else { return [] }
        return elements
    }
}

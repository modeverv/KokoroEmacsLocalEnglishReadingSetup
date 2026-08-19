import Foundation

enum PageDirection: Sendable { case next, previous }

enum SettleEvaluation: Equatable, Sendable { case stable, didNotChange, timeout }

struct SettleOptions: Sendable {
    let pollMilliseconds: Int
    let stableSamples: Int
    let timeoutMilliseconds: Int

    static func from(_ params: [String: JSONValue]) -> SettleOptions {
        SettleOptions(
            pollMilliseconds: max(50, params.int("pollMs", default: 100)),
            stableSamples: max(2, params.int("stableSamples", default: 2)),
            timeoutMilliseconds: max(500, params.int("timeoutMs", default: 4000)))
    }
}

enum PageSettler {
    static func evaluate(before: String, samples: [String], stableSamples: Int) -> SettleEvaluation {
        var changed = false
        var previous: String?
        var run = 0
        for fingerprint in samples {
            if fingerprint != before { changed = true }
            if fingerprint == previous { run += 1 } else { run = 1; previous = fingerprint }
            if changed && run >= stableSamples { return .stable }
        }
        return changed ? .timeout : .didNotChange
    }

    static func wait(
        client: CDPClient,
        before: String,
        crop: NormalizedCrop,
        options: SettleOptions
    ) async throws -> ScreenshotImage {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(options.timeoutMilliseconds))
        var changed = false
        var previous: String?
        var run = 0
        while clock.now < deadline {
            try await Task.sleep(for: .milliseconds(options.pollMilliseconds))
            let image = try ScreenshotImage(pngData: await client.captureScreenshot())
            let fingerprint = try image.contentFingerprint(crop: crop)
            if fingerprint != before { changed = true }
            if fingerprint == previous { run += 1 } else { previous = fingerprint; run = 1 }
            if changed && run >= options.stableSamples { return image }
        }
        if !changed {
            throw BridgeFailure(code: "PAGE_DID_NOT_CHANGE", message: "Kindle page did not change before timeout")
        }
        throw BridgeFailure(code: "PAGE_SETTLE_TIMEOUT", message: "Kindle page did not become stable before timeout")
    }
}

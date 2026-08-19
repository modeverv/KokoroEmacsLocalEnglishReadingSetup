import XCTest
@testable import MyReadKBridge

final class ProtocolTests: XCTestCase {
    func testRequestDecodingAndGeneration() throws {
        let data = Data(#"{"id":12,"command":"capture","generation":41,"params":{"language":"en-US"}}"#.utf8)
        let request = try JSONDecoder().decode(BridgeRequest.self, from: data)
        XCTAssertEqual(request.id, 12)
        XCTAssertEqual(request.command, "capture")
        XCTAssertEqual(request.generation, 41)
        XCTAssertEqual(request.params["language"], .string("en-US"))
    }

    func testErrorEncoding() throws {
        let response = BridgeResponse.failure(id: 3, generation: 9,
                                              code: "NO_TEXT", message: "Nothing recognized")
        let decoded = try JSONDecoder().decode(BridgeResponse.self,
                                               from: JSONEncoder().encode(response))
        XCTAssertEqual(decoded, response)
    }
}

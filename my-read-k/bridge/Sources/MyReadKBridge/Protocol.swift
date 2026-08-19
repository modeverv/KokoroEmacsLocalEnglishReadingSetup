import Foundation

enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value") }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var string: String? { if case .string(let value) = self { value } else { nil } }
    var number: Double? { if case .number(let value) = self { value } else { nil } }
    var object: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
}

struct BridgeRequest: Codable, Equatable, Sendable {
    let id: Int
    let command: String
    let generation: Int
    let params: [String: JSONValue]
}

struct BridgeErrorBody: Codable, Equatable, Sendable {
    let code: String
    let message: String
}

struct BridgeResponse: Codable, Equatable, Sendable {
    let id: Int
    let ok: Bool
    let generation: Int
    let result: [String: JSONValue]?
    let error: BridgeErrorBody?

    static func success(id: Int, generation: Int, result: [String: JSONValue]) -> Self {
        Self(id: id, ok: true, generation: generation, result: result, error: nil)
    }

    static func failure(id: Int, generation: Int, code: String, message: String) -> Self {
        Self(id: id, ok: false, generation: generation, result: nil,
             error: BridgeErrorBody(code: code, message: message))
    }
}

struct BridgeFailure: Error, LocalizedError, Sendable {
    let code: String
    let message: String
    var errorDescription: String? { message }
}

extension Dictionary where Key == String, Value == JSONValue {
    func string(_ key: String, default fallback: String? = nil) -> String? {
        self[key]?.string ?? fallback
    }

    func int(_ key: String, default fallback: Int) -> Int {
        self[key]?.number.map(Int.init) ?? fallback
    }

    func double(_ key: String, default fallback: Double) -> Double {
        self[key]?.number ?? fallback
    }

    func object(_ key: String) -> [String: JSONValue]? { self[key]?.object }
}

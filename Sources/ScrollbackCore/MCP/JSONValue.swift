import Foundation

/// A minimal, Codable representation of arbitrary JSON. Used for two things on the MCP
/// surface: the tool INPUT SCHEMAS the daemon hands the (dumb) proxy to relay as
/// `tools/list`, and the tool-call ARGUMENTS a client sends (untyped until dispatched).
/// Keeping it here means the daemon owns the contract and the proxy stays thin.
public indirect enum JSONValue: Codable, Sendable, Equatable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    // MARK: - Typed accessors (nil on type mismatch — the dispatcher validates)

    public var stringValue: String? { if case .string(let value) = self { return value } else { return nil } }
    public var boolValue: Bool? { if case .bool(let value) = self { return value } else { return nil } }
    public var arrayValue: [JSONValue]? { if case .array(let value) = self { return value } else { return nil } }
    public var objectValue: [String: JSONValue]? { if case .object(let value) = self { return value } else { return nil } }

    /// Integer view of a numeric value (JSON has no int type). Nil if non-numeric or
    /// not integral, so `limit: 3.5` is rejected rather than silently truncated.
    public var intValue: Int? {
        guard case .number(let value) = self, value.rounded() == value else { return nil }
        return Int(value)
    }

    /// `[String]` view of a string array (drops non-string elements).
    public var stringArrayValue: [String]? { arrayValue?.compactMap { $0.stringValue } }

    public subscript(key: String) -> JSONValue? { objectValue?[key] }
}

public extension JSONValue {
    /// Sugar for building tool schemas.
    static func object(_ pairs: KeyValuePairs<String, JSONValue>) -> JSONValue {
        .object(Dictionary(pairs.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first }))
    }
}

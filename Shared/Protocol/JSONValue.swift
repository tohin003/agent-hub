import Foundation

/// A loosely typed JSON value. The wire envelope carries params, results and event payloads as `JSONValue`, and each
/// side converts them to and from typed `Codable` structs with `decode(_:)` and `JSONValue(encoding:)`.
nonisolated public enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
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

    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var doubleValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        if case .number(let value) = self { return Int(value) }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// Re-encodes this value and decodes it as `T`.
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let data = try WireCoding.encoder.encode(self)
        return try WireCoding.decoder.decode(T.self, from: data)
    }

    /// Encodes any `Encodable` value into a `JSONValue`.
    public init<T: Encodable>(encoding value: T) throws {
        let data = try WireCoding.encoder.encode(value)
        self = try WireCoding.decoder.decode(JSONValue.self, from: data)
    }

    /// Converts a Foundation object produced by `JSONSerialization` into a `JSONValue`.
    public init(foundation object: Any?) {
        switch object {
        case nil, is NSNull: self = .null
        case let value as Bool where type(of: value) == Bool.self: self = .bool(value)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                self = .bool(value.boolValue)
            } else {
                self = .number(value.doubleValue)
            }
        case let value as String: self = .string(value)
        case let value as [Any]: self = .array(value.map { JSONValue(foundation: $0) })
        case let value as [String: Any]: self = .object(value.mapValues { JSONValue(foundation: $0) })
        default: self = .string(String(describing: object!))
        }
    }

    /// Compact single-line JSON text, used when a tool input is shown verbatim.
    public var compactText: String {
        guard let data = try? WireCoding.encoder.encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Pretty-printed JSON text with sorted keys.
    public var prettyText: String {
        guard let data = try? WireCoding.prettyEncoder.encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// The JSON coders both sides use, so dates and keys match on the wire.
nonisolated public enum WireCoding {
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }()

    public static let prettyEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()
}

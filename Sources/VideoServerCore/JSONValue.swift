import Foundation

/// 汎用の JSON 値表現。形の決まっていない要求を読んだり、
/// 応答をその場で組み立てたりするのに使う。
public enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Int.self) { self = .int(v); return }
        if let v = try? c.decode(Double.self) { self = .double(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([JSONValue].self) { self = .array(v); return }
        if let v = try? c.decode([String: JSONValue].self) { self = .object(v); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "未知の JSON 値")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    // MARK: 取り出し用

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }

    /// 数値は int と double のどちらで来るか決まらない
    /// (JSON には区別が無く、復号時も値次第で分かれる) ため、両方を受ける。
    public var intValue: Int? {
        switch self {
        case .int(let v): return v
        case .double(let v): return Int(v)
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .double(let v): return v
        case .int(let v): return Double(v)
        default: return nil
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }
}

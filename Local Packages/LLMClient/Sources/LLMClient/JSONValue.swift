import Foundation

// MARK: - JSON Value

/// Type-safe JSON value for flexible encoding/decoding of LLM API payloads.
/// Preferred over `AnyCodable` for stronger typing and pattern-matching support.
public enum JSONValue: Codable, Sendable, Hashable {
  case string(String)
  case int(Int)
  case double(Double)
  case bool(Bool)
  case null
  case array([JSONValue])
  case object([String: JSONValue])

  public var stringValue: String? {
    if case .string(let s) = self { return s }
    return nil
  }

  public var intValue: Int? {
    if case .int(let i) = self { return i }
    return nil
  }

  public var boolValue: Bool? {
    if case .bool(let b) = self { return b }
    return nil
  }

  public var doubleValue: Double? {
    if case .double(let d) = self { return d }
    return nil
  }

  public var arrayValue: [JSONValue]? {
    if case .array(let a) = self { return a }
    return nil
  }

  public var objectValue: [String: JSONValue]? {
    if case .object(let o) = self { return o }
    return nil
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let s): try container.encode(s)
    case .int(let i): try container.encode(i)
    case .double(let d): try container.encode(d)
    case .bool(let b): try container.encode(b)
    case .null: try container.encodeNil()
    case .array(let a): try container.encode(a)
    case .object(let o): try container.encode(o)
    }
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let b = try? container.decode(Bool.self) {
      self = .bool(b)
    } else if let i = try? container.decode(Int.self) {
      self = .int(i)
    } else if let d = try? container.decode(Double.self) {
      self = .double(d)
    } else if let s = try? container.decode(String.self) {
      self = .string(s)
    } else if let a = try? container.decode([JSONValue].self) {
      self = .array(a)
    } else if let o = try? container.decode([String: JSONValue].self) {
      self = .object(o)
    } else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Cannot decode JSONValue"
      )
    }
  }
}

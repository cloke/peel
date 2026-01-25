//
//  JSONRPC.swift
//  MCPCore
//
//  Core JSON-RPC 2.0 types for MCP communication.
//

import Foundation

// MARK: - JSON-RPC Request

/// A JSON-RPC 2.0 request object
public struct JSONRPCRequest: Codable, Sendable {
  public let jsonrpc: String
  public let id: JSONRPCId?
  public let method: String
  public let params: JSONRPCParams?

  public init(
    id: JSONRPCId? = nil,
    method: String,
    params: JSONRPCParams? = nil
  ) {
    self.jsonrpc = "2.0"
    self.id = id
    self.method = method
    self.params = params
  }
}

// MARK: - JSON-RPC Response

/// A JSON-RPC 2.0 response object
public struct JSONRPCResponse: Codable, Sendable {
  public let jsonrpc: String
  public let id: JSONRPCId?
  public let result: AnyCodable?
  public let error: JSONRPCError?

  public init(id: JSONRPCId?, result: AnyCodable) {
    self.jsonrpc = "2.0"
    self.id = id
    self.result = result
    self.error = nil
  }

  public init(id: JSONRPCId?, error: JSONRPCError) {
    self.jsonrpc = "2.0"
    self.id = id
    self.result = nil
    self.error = error
  }
}

// MARK: - JSON-RPC Error

/// A JSON-RPC 2.0 error object
public struct JSONRPCError: Codable, Sendable {
  public let code: Int
  public let message: String
  public let data: AnyCodable?

  public init(code: Int, message: String, data: AnyCodable? = nil) {
    self.code = code
    self.message = message
    self.data = data
  }

  // Standard JSON-RPC error codes
  public static let parseError = JSONRPCError(code: -32700, message: "Parse error")
  public static let invalidRequest = JSONRPCError(code: -32600, message: "Invalid Request")
  public static let methodNotFound = JSONRPCError(code: -32601, message: "Method not found")
  public static let invalidParams = JSONRPCError(code: -32602, message: "Invalid params")
  public static let internalError = JSONRPCError(code: -32603, message: "Internal error")

  public static func invalidParams(_ message: String) -> JSONRPCError {
    JSONRPCError(code: -32602, message: message)
  }

  public static func internalError(_ message: String) -> JSONRPCError {
    JSONRPCError(code: -32603, message: message)
  }
}

// MARK: - JSON-RPC ID

/// JSON-RPC request/response ID (can be string, number, or null)
public enum JSONRPCId: Codable, Sendable, Hashable {
  case string(String)
  case number(Int)

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let intValue = try? container.decode(Int.self) {
      self = .number(intValue)
    } else if let stringValue = try? container.decode(String.self) {
      self = .string(stringValue)
    } else {
      throw DecodingError.typeMismatch(
        JSONRPCId.self,
        DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected string or number")
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value):
      try container.encode(value)
    case .number(let value):
      try container.encode(value)
    }
  }

  /// Convert from Any type (for compatibility with existing code)
  public init?(any: Any?) {
    guard let value = any else { return nil }
    if let intValue = value as? Int {
      self = .number(intValue)
    } else if let stringValue = value as? String {
      self = .string(stringValue)
    } else if let doubleValue = value as? Double {
      self = .number(Int(doubleValue))
    } else {
      return nil
    }
  }

  /// Convert to Any type (for compatibility with existing code)
  public var anyValue: Any {
    switch self {
    case .string(let value): return value
    case .number(let value): return value
    }
  }
}

// MARK: - JSON-RPC Params

/// JSON-RPC params (can be array or object)
public enum JSONRPCParams: Codable, Sendable {
  case array([AnyCodable])
  case object([String: AnyCodable])

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let array = try? container.decode([AnyCodable].self) {
      self = .array(array)
    } else if let object = try? container.decode([String: AnyCodable].self) {
      self = .object(object)
    } else {
      throw DecodingError.typeMismatch(
        JSONRPCParams.self,
        DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected array or object")
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .array(let value):
      try container.encode(value)
    case .object(let value):
      try container.encode(value)
    }
  }

  /// Get as dictionary (for compatibility)
  public var dictionary: [String: Any]? {
    switch self {
    case .object(let dict):
      return dict.mapValues { $0.value }
    case .array:
      return nil
    }
  }
}

// MARK: - AnyCodable

/// Type-erased Codable wrapper for arbitrary JSON values
public struct AnyCodable: Codable, Sendable, Hashable {
  public let value: Any

  public init(_ value: Any) {
    self.value = value
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()

    if container.decodeNil() {
      self.value = NSNull()
    } else if let bool = try? container.decode(Bool.self) {
      self.value = bool
    } else if let int = try? container.decode(Int.self) {
      self.value = int
    } else if let double = try? container.decode(Double.self) {
      self.value = double
    } else if let string = try? container.decode(String.self) {
      self.value = string
    } else if let array = try? container.decode([AnyCodable].self) {
      self.value = array.map { $0.value }
    } else if let dictionary = try? container.decode([String: AnyCodable].self) {
      self.value = dictionary.mapValues { $0.value }
    } else {
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unable to decode value")
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()

    switch value {
    case is NSNull:
      try container.encodeNil()
    case let bool as Bool:
      try container.encode(bool)
    case let int as Int:
      try container.encode(int)
    case let double as Double:
      try container.encode(double)
    case let string as String:
      try container.encode(string)
    case let array as [Any]:
      try container.encode(array.map { AnyCodable($0) })
    case let dictionary as [String: Any]:
      try container.encode(dictionary.mapValues { AnyCodable($0) })
    default:
      throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: encoder.codingPath, debugDescription: "Unable to encode value"))
    }
  }

  public static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
    // Simple equality for common types
    switch (lhs.value, rhs.value) {
    case (is NSNull, is NSNull):
      return true
    case let (l as Bool, r as Bool):
      return l == r
    case let (l as Int, r as Int):
      return l == r
    case let (l as Double, r as Double):
      return l == r
    case let (l as String, r as String):
      return l == r
    default:
      return false
    }
  }

  public func hash(into hasher: inout Hasher) {
    switch value {
    case is NSNull:
      hasher.combine(0)
    case let bool as Bool:
      hasher.combine(bool)
    case let int as Int:
      hasher.combine(int)
    case let double as Double:
      hasher.combine(double)
    case let string as String:
      hasher.combine(string)
    default:
      hasher.combine(1)
    }
  }
}

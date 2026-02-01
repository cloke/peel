//
//  MCPToolHandlerHelpers.swift
//  MCPServerKit
//
//  Helper extensions for tool handlers.
//

import Foundation
import MCPCore

// MARK: - Response Builder Convenience

extension MCPToolHandling {
  /// Create a successful MCP-compliant tool result response
  public func makeResult(id: Any?, result: [String: Any]) -> Data {
    JSONRPCResponseBuilder.makeToolResult(id: id, result: result)
  }

  /// Create an error RPC response
  public func makeError(id: Any?, code: Int, message: String, data: [String: Any]? = nil) -> Data {
    JSONRPCResponseBuilder.makeError(id: id, code: code, message: message, data: data)
  }

  /// Create an error RPC response without data
  public func makeError(id: Any?, code: Int, message: String) -> Data {
    JSONRPCResponseBuilder.makeError(id: id, code: code, message: message)
  }
}

// MARK: - Common Error Responses

extension MCPToolHandling {
  /// Return error for handler not configured
  public func notConfiguredError(id: Any?) -> (Int, Data) {
    (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: "Handler not configured"))
  }

  /// Return error for missing required parameter
  public func missingParamError(id: Any?, param: String) -> (Int, Data) {
    (400, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.invalidParams, message: "Missing \(param)"))
  }

  /// Return error for invalid parameter value
  public func invalidParamError(id: Any?, param: String, reason: String? = nil) -> (Int, Data) {
    let message = reason ?? "Invalid \(param)"
    return (400, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.invalidParams, message: message))
  }

  /// Return error for resource not found
  public func notFoundError(id: Any?, what: String) -> (Int, Data) {
    (404, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.notFound, message: "\(what) not found"))
  }

  /// Return error for internal failure
  public func internalError(id: Any?, message: String) -> (Int, Data) {
    (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: message))
  }
}

// MARK: - Parameter Extraction

/// Error type that wraps an HTTP response tuple
public struct MCPParamError: Error {
  public let code: Int
  public let data: Data

  public var response: (Int, Data) { (code, data) }

  public init(_ response: (Int, Data)) {
    self.code = response.0
    self.data = response.1
  }
}

extension MCPToolHandling {
  /// Result type for parameter extraction
  public typealias ParamResult<T> = Result<T, MCPParamError>

  /// Extract a required string parameter, trimmed and non-empty
  public func requireString(_ key: String, from arguments: [String: Any], id: Any?) -> ParamResult<String> {
    guard let value = (arguments[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !value.isEmpty else {
      return .failure(MCPParamError(missingParamError(id: id, param: key)))
    }
    return .success(value)
  }

  /// Extract an optional string parameter
  public func optionalString(_ key: String, from arguments: [String: Any], default defaultValue: String? = nil) -> String? {
    guard let value = (arguments[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !value.isEmpty else {
      return defaultValue
    }
    return value
  }

  /// Extract a required integer parameter
  public func requireInt(_ key: String, from arguments: [String: Any], id: Any?) -> ParamResult<Int> {
    guard let value = arguments[key] as? Int else {
      return .failure(MCPParamError(missingParamError(id: id, param: key)))
    }
    return .success(value)
  }

  /// Extract an optional integer parameter
  public func optionalInt(_ key: String, from arguments: [String: Any], default defaultValue: Int? = nil) -> Int? {
    arguments[key] as? Int ?? defaultValue
  }

  /// Extract a required boolean parameter
  public func requireBool(_ key: String, from arguments: [String: Any], id: Any?) -> ParamResult<Bool> {
    guard let value = arguments[key] as? Bool else {
      return .failure(MCPParamError(missingParamError(id: id, param: key)))
    }
    return .success(value)
  }

  /// Extract an optional boolean parameter
  public func optionalBool(_ key: String, from arguments: [String: Any], default defaultValue: Bool) -> Bool {
    arguments[key] as? Bool ?? defaultValue
  }
}

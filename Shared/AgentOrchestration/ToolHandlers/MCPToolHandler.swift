//
//  MCPToolHandler.swift
//  KitchenSync
//
//  Created as part of #121: Split MCPServerService by tool category.
//

import Foundation
import MCPCore

// MARK: - Tool Handler Protocol

/// Protocol for tool handlers extracted from MCPServerService.
/// Each handler manages a category of MCP tools.
@MainActor
public protocol MCPToolHandler {
  /// The service delegate for shared functionality
  var delegate: MCPToolHandlerDelegate? { get set }

  /// Tool names this handler supports
  var supportedTools: Set<String> { get }

  /// Tool definitions for all tools this handler supports.
  /// Used by MCPServerService to aggregate the full tool list.
  var toolDefinitions: [MCPToolDefinition] { get }

  /// Handle a tool call
  /// - Parameters:
  ///   - name: The tool name
  ///   - id: The RPC request ID
  ///   - arguments: The tool arguments
  /// - Returns: Tuple of (HTTP status code, response data)
  func handle(name: String, id: Any?, arguments: [String: Any]) async -> (Int, Data)
}

// MARK: - Handler Delegate Protocol

/// Delegate protocol providing shared MCPServerService functionality to handlers.
@MainActor
public protocol MCPToolHandlerDelegate: AnyObject {
  // MARK: - UI State Management

  /// Record that a UI action was handled
  func recordUIActionHandled(_ controlId: String)

  /// Record that a UI action was requested
  func recordUIActionRequested(_ controlId: String)

  /// Record that a UI action needs the app in foreground
  func recordUIActionForegroundNeeded(_ controlId: String)

  /// Get available view IDs
  func availableViewIds() -> [String]

  /// Get available tool control IDs
  func availableToolControlIds() -> [String]

  /// Get available control IDs for a view
  func availableControlIds(for viewId: String?) -> [String]

  /// Get control values for a view
  func controlValues(for viewId: String?) -> [String: Any]

  /// Get current tool/view ID
  func currentToolId() -> String?

  /// Set current tool/view ID
  func setCurrentToolId(_ viewId: String)

  /// Worktree name map from defaults
  func worktreeNameMapFromDefaults() -> [String: String]

  // MARK: - Service Properties Access

  /// Local RAG repo path
  var localRagRepoPath: String { get set }

  /// Local RAG query string
  var localRagQuery: String { get set }

  /// Local RAG search mode
  var localRagSearchMode: MCPServerService.RAGSearchMode { get set }

  /// Local RAG search limit
  var localRagSearchLimit: Int { get set }

  /// Last UI action
  var lastUIAction: UIAction? { get set }
}

// MARK: - Async Task Helper

/// Shared helper for handler async/task scaffolding.
public enum AsyncHandler {
  @discardableResult
  @MainActor
  public static func launch(
    operation: @escaping () async throws -> Void,
    onCancelled: (@MainActor () async -> Void)? = nil,
    onError: (@MainActor (Error) async -> Void)? = nil
  ) -> Task<Void, Never> {
    Task { @MainActor in
      do {
        try await operation()
      } catch is CancellationError {
        if let onCancelled {
          await onCancelled()
        }
      } catch {
        if let onError {
          await onError(error)
        }
      }
    }
  }
}

// MARK: - Response Builder Convenience

/// Extension providing convenient response builders using MCPCore
extension MCPToolHandler {
  /// Default empty tool definitions — handlers should override this.
  public var toolDefinitions: [MCPToolDefinition] { [] }

  /// Create a successful MCP-compliant tool result response
  /// Uses the content array format required by the MCP specification
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

/// Extension providing common error response helpers to reduce boilerplate
extension MCPToolHandler {
  /// Return error for handler not configured (missing delegate)
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

  /// Return error when a service/feature is not active (user can fix by enabling it)
  public func serviceNotActiveError(id: Any?, service: String, hint: String? = nil) -> (Int, Data) {
    let message = hint ?? "\(service) is not active. Enable it first to use this tool."
    return (200, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.serviceNotActive, message: message))
  }
}

// MARK: - Parameter Extraction Helpers

/// Error type that wraps an HTTP response tuple for use with Result
public struct ParamError: Error {
  public let code: Int
  public let data: Data
  
  public var response: (Int, Data) { (code, data) }
  
  public init(_ response: (Int, Data)) {
    self.code = response.0
    self.data = response.1
  }
}

public enum ToolArgType: String {
  case string
  case int
  case double
  case bool
  case uuid
  case array
  case object
}

public struct ToolArgSchemaField {
  public let key: String
  public let type: ToolArgType
  public let required: Bool
  public let defaultValue: Any?
  public let trimString: Bool
  public let allowEmptyString: Bool

  public init(
    key: String,
    type: ToolArgType,
    required: Bool = false,
    defaultValue: Any? = nil,
    trimString: Bool = true,
    allowEmptyString: Bool = false
  ) {
    self.key = key
    self.type = type
    self.required = required
    self.defaultValue = defaultValue
    self.trimString = trimString
    self.allowEmptyString = allowEmptyString
  }

  public static func required(
    _ key: String,
    _ type: ToolArgType,
    trimString: Bool = true,
    allowEmptyString: Bool = false
  ) -> ToolArgSchemaField {
    ToolArgSchemaField(
      key: key,
      type: type,
      required: true,
      trimString: trimString,
      allowEmptyString: allowEmptyString
    )
  }

  public static func optional(
    _ key: String,
    _ type: ToolArgType,
    default defaultValue: Any? = nil,
    trimString: Bool = true,
    allowEmptyString: Bool = false
  ) -> ToolArgSchemaField {
    ToolArgSchemaField(
      key: key,
      type: type,
      required: false,
      defaultValue: defaultValue,
      trimString: trimString,
      allowEmptyString: allowEmptyString
    )
  }
}

public struct ToolArgValues {
  private let values: [String: Any]

  public init(values: [String: Any]) {
    self.values = values
  }

  public func string(_ key: String) -> String? {
    values[key] as? String
  }

  public func int(_ key: String) -> Int? {
    values[key] as? Int
  }

  public func double(_ key: String) -> Double? {
    values[key] as? Double
  }

  public func bool(_ key: String) -> Bool? {
    values[key] as? Bool
  }

  public func uuid(_ key: String) -> UUID? {
    values[key] as? UUID
  }

  public func object(_ key: String) -> [String: Any]? {
    values[key] as? [String: Any]
  }

  public func array<T>(_ key: String, as _: T.Type = T.self) -> [T]? {
    values[key] as? [T]
  }
}

/// Extension providing parameter extraction with automatic error handling
extension MCPToolHandler {
  /// Result type for parameter extraction - either the value or an error response
  public typealias ParamResult<T> = Result<T, ParamError>

  public func parseArguments(
    _ arguments: [String: Any],
    schema: [ToolArgSchemaField],
    id: Any?
  ) -> ParamResult<ToolArgValues> {
    var parsed: [String: Any] = [:]

    for field in schema {
      if let rawValue = arguments[field.key] {
        switch field.type {
        case .string:
          guard let stringValue = rawValue as? String else {
            return .failure(ParamError(argumentTypeError(id: id, field: field, value: rawValue)))
          }
          let normalized = field.trimString
            ? stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            : stringValue
          guard field.allowEmptyString || !normalized.isEmpty else {
            return .failure(ParamError(argumentValueError(id: id, field: field, reason: "String cannot be empty")))
          }
          parsed[field.key] = normalized
        case .int:
          guard let intValue = rawValue as? Int else {
            return .failure(ParamError(argumentTypeError(id: id, field: field, value: rawValue)))
          }
          parsed[field.key] = intValue
        case .double:
          if let doubleValue = rawValue as? Double {
            parsed[field.key] = doubleValue
          } else if let intValue = rawValue as? Int {
            parsed[field.key] = Double(intValue)
          } else {
            return .failure(ParamError(argumentTypeError(id: id, field: field, value: rawValue)))
          }
        case .bool:
          guard let boolValue = rawValue as? Bool else {
            return .failure(ParamError(argumentTypeError(id: id, field: field, value: rawValue)))
          }
          parsed[field.key] = boolValue
        case .uuid:
          guard let stringValue = rawValue as? String,
                let uuidValue = UUID(uuidString: stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return .failure(ParamError(argumentValueError(id: id, field: field, reason: "Invalid UUID format")))
          }
          parsed[field.key] = uuidValue
        case .array:
          guard let arrayValue = rawValue as? [Any] else {
            return .failure(ParamError(argumentTypeError(id: id, field: field, value: rawValue)))
          }
          parsed[field.key] = arrayValue
        case .object:
          guard let objectValue = rawValue as? [String: Any] else {
            return .failure(ParamError(argumentTypeError(id: id, field: field, value: rawValue)))
          }
          parsed[field.key] = objectValue
        }
      } else if let defaultValue = field.defaultValue {
        parsed[field.key] = defaultValue
      } else if field.required {
        return .failure(ParamError(missingRequiredArgumentError(id: id, field: field)))
      }
    }

    return .success(ToolArgValues(values: parsed))
  }

  /// Extract a required string parameter, trimmed and non-empty
  public func requireString(_ key: String, from arguments: [String: Any], id: Any?) -> ParamResult<String> {
    guard let value = (arguments[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !value.isEmpty else {
      return .failure(ParamError(missingParamError(id: id, param: key)))
    }
    return .success(value)
  }

  /// Extract an optional string parameter, trimmed (returns nil if missing or empty)
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
      return .failure(ParamError(missingParamError(id: id, param: key)))
    }
    return .success(value)
  }

  /// Extract an optional integer parameter
  public func optionalInt(_ key: String, from arguments: [String: Any], default defaultValue: Int? = nil) -> Int? {
    (arguments[key] as? Int) ?? defaultValue
  }

  /// Extract a required UUID parameter (from string)
  public func requireUUID(_ key: String, from arguments: [String: Any], id: Any?) -> ParamResult<UUID> {
    guard let stringValue = (arguments[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !stringValue.isEmpty else {
      return .failure(ParamError(missingParamError(id: id, param: key)))
    }
    guard let uuid = UUID(uuidString: stringValue) else {
      return .failure(ParamError(invalidParamError(id: id, param: key, reason: "Invalid UUID format")))
    }
    return .success(uuid)
  }

  /// Extract an optional UUID parameter
  public func optionalUUID(_ key: String, from arguments: [String: Any]) -> UUID? {
    guard let stringValue = arguments[key] as? String else { return nil }
    return UUID(uuidString: stringValue)
  }

  /// Extract a required boolean parameter
  public func requireBool(_ key: String, from arguments: [String: Any], id: Any?) -> ParamResult<Bool> {
    guard let value = arguments[key] as? Bool else {
      return .failure(ParamError(missingParamError(id: id, param: key)))
    }
    return .success(value)
  }

  /// Extract an optional boolean parameter
  public func optionalBool(_ key: String, from arguments: [String: Any], default defaultValue: Bool) -> Bool {
    (arguments[key] as? Bool) ?? defaultValue
  }

  /// Extract a required array parameter
  public func requireArray<T>(_ key: String, from arguments: [String: Any], id: Any?) -> ParamResult<[T]> {
    guard let value = arguments[key] as? [T], !value.isEmpty else {
      return .failure(ParamError(missingParamError(id: id, param: key)))
    }
    return .success(value)
  }

  private func missingRequiredArgumentError(id: Any?, field: ToolArgSchemaField) -> (Int, Data) {
    (
      400,
      makeError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.invalidParams,
        message: "Invalid params",
        data: [
          "parameter": field.key,
          "error": "Missing required parameter",
          "expectedType": field.type.rawValue
        ]
      )
    )
  }

  private func argumentTypeError(id: Any?, field: ToolArgSchemaField, value: Any) -> (Int, Data) {
    (
      400,
      makeError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.invalidParams,
        message: "Invalid params",
        data: [
          "parameter": field.key,
          "error": "Type mismatch",
          "expectedType": field.type.rawValue,
          "receivedType": argumentTypeName(value)
        ]
      )
    )
  }

  private func argumentValueError(id: Any?, field: ToolArgSchemaField, reason: String) -> (Int, Data) {
    (
      400,
      makeError(
        id: id,
        code: JSONRPCResponseBuilder.ErrorCode.invalidParams,
        message: "Invalid params",
        data: [
          "parameter": field.key,
          "error": reason,
          "expectedType": field.type.rawValue
        ]
      )
    )
  }

  private func argumentTypeName(_ value: Any) -> String {
    switch value {
    case is String: "string"
    case is Int: "int"
    case is Double: "double"
    case is Bool: "bool"
    case is UUID: "uuid"
    case is [Any]: "array"
    case is [String: Any]: "object"
    default: String(describing: type(of: value))
    }
  }
}
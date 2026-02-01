//
//  MCPServer.swift
//  MCPServerKit
//
//  JSON-RPC 2.0 HTTP server for MCP.
//

import Foundation
import MCPCore
import Network
import OSLog

/// MCP JSON-RPC server that handles HTTP requests.
@MainActor
public final class MCPServer {
  private let logger = Logger(subsystem: "com.mcpserverkit", category: "MCPServer")
  private let listenerQueue = DispatchQueue(label: "MCPServer.Listener")
  private var listener: NWListener?
  private var connections: [UUID: NWConnection] = [:]
  private var connectionStates: [UUID: ConnectionState] = [:]

  public let registry: MCPToolRegistry
  public let config: MCPServerConfigProviding

  public private(set) var isRunning: Bool = false
  public private(set) var port: Int
  public private(set) var lanModeEnabled: Bool
  public var lastError: String?

  /// Callback for custom method handling (initialize, tools/call dispatch, etc.)
  public var onRequest: ((String, Any?, [String: Any]?) async -> (Int, Data)?)?

  private struct ConnectionState {
    var buffer = Data()
  }

  public init(
    port: Int = 8765,
    lanModeEnabled: Bool = false,
    config: MCPServerConfigProviding? = nil,
    registry: MCPToolRegistry = MCPToolRegistry()
  ) {
    self.port = port
    self.lanModeEnabled = lanModeEnabled
    self.config = config ?? MCPUserDefaultsConfig()
    self.registry = registry
  }

  // MARK: - Server Lifecycle

  public func start() {
    guard !isRunning else { return }

    do {
      let params = NWParameters.tcp
      params.allowLocalEndpointReuse = true
      let listener = try NWListener(using: params, on: NWEndpoint.Port(integerLiteral: UInt16(port)))

      listener.stateUpdateHandler = { [weak self] state in
        Task { @MainActor in
          switch state {
          case .ready:
            self?.isRunning = true
            self?.lastError = nil
            self?.logger.info("MCP server listening on port \(self?.port ?? 0)")
          case .failed(let error):
            self?.isRunning = false
            self?.lastError = error.localizedDescription
            self?.logger.error("MCP server failed: \(error.localizedDescription)")
          case .cancelled:
            self?.isRunning = false
          default:
            break
          }
        }
      }

      listener.newConnectionHandler = { [weak self] connection in
        Task { @MainActor in
          self?.handleNewConnection(connection)
        }
      }

      listener.start(queue: listenerQueue)
      self.listener = listener
    } catch {
      lastError = error.localizedDescription
      logger.error("Failed to start MCP server: \(error.localizedDescription)")
    }
  }

  public func stop() {
    listener?.cancel()
    listener = nil
    isRunning = false

    for (id, connection) in connections {
      connection.cancel()
      connections[id] = nil
      connectionStates[id] = nil
    }
  }

  public func restart() {
    stop()
    start()
  }

  public func setPort(_ newPort: Int) {
    port = newPort
    if isRunning {
      restart()
    }
  }

  public func setLanMode(_ enabled: Bool) {
    lanModeEnabled = enabled
    if isRunning {
      restart()
    }
  }

  // MARK: - Connection Handling

  private func handleNewConnection(_ connection: NWConnection) {
    let id = UUID()
    connections[id] = connection
    connectionStates[id] = ConnectionState()

    // Check LAN mode
    if !lanModeEnabled && !isLocalConnection(connection) {
      logger.warning("Rejected non-local connection (LAN mode disabled)")
      connection.cancel()
      connections[id] = nil
      connectionStates[id] = nil
      return
    }

    connection.stateUpdateHandler = { [weak self] state in
      Task { @MainActor in
        if case .failed = state {
          self?.closeConnection(id)
        }
      }
    }

    connection.start(queue: listenerQueue)
    receive(on: connection, id: id)
  }

  private func receive(on connection: NWConnection, id: UUID) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
      Task { @MainActor in
        guard let self else { return }
        if let data, !data.isEmpty {
          self.connectionStates[id]?.buffer.append(data)
          self.processBuffer(for: id, connection: connection)
        }

        if isComplete || error != nil {
          self.closeConnection(id)
        } else {
          self.receive(on: connection, id: id)
        }
      }
    }
  }

  private func processBuffer(for id: UUID, connection: NWConnection) {
    guard var state = connectionStates[id] else { return }
    if let request = parseRequest(from: &state.buffer) {
      connectionStates[id] = state
      handleRequest(request, on: connection)
    } else {
      connectionStates[id] = state
    }
  }

  private func closeConnection(_ id: UUID) {
    connections[id]?.cancel()
    connections[id] = nil
    connectionStates[id] = nil
  }

  private func isLocalConnection(_ connection: NWConnection) -> Bool {
    switch connection.endpoint {
    case .hostPort(let host, _):
      switch host {
      case .ipv4(let address):
        return address == IPv4Address("127.0.0.1")
      case .ipv6(let address):
        return address == IPv6Address("::1")
      case .name(let name, _):
        return name == "localhost"
      default:
        return false
      }
    default:
      return false
    }
  }

  // MARK: - HTTP Parsing

  private struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
  }

  private func parseRequest(from buffer: inout Data) -> HTTPRequest? {
    let delimiter = Data("\r\n\r\n".utf8)
    guard let headerRange = buffer.range(of: delimiter) else { return nil }

    let headerData = buffer.subdata(in: buffer.startIndex..<headerRange.lowerBound)
    guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }

    let lines = headerText.split(separator: "\r\n")
    guard let requestLine = lines.first else { return nil }

    let requestParts = requestLine.split(separator: " ")
    guard requestParts.count >= 2 else { return nil }

    let method = String(requestParts[0])
    let path = String(requestParts[1])

    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      if let separatorIndex = line.firstIndex(of: ":") {
        let key = line[..<separatorIndex].trimmingCharacters(in: .whitespaces)
        let value = line[line.index(after: separatorIndex)...].trimmingCharacters(in: .whitespaces)
        headers[key.lowercased()] = value
      }
    }

    let contentLength = Int(headers["content-length"] ?? "0") ?? 0
    let bodyStart = headerRange.upperBound
    let totalLength = bodyStart + contentLength
    guard buffer.count >= totalLength else { return nil }

    let body = buffer.subdata(in: bodyStart..<totalLength)
    buffer.removeSubrange(0..<totalLength)

    return HTTPRequest(method: method, path: path, headers: headers, body: body)
  }

  private func handleRequest(_ request: HTTPRequest, on connection: NWConnection) {
    guard request.method.uppercased() == "POST", request.path == "/rpc" else {
      sendHTTPResponse(status: 404, body: Data("{\"error\":\"Not Found\"}".utf8), on: connection)
      return
    }

    Task {
      let (_, responseBody) = await handleRPC(body: request.body)
      sendHTTPResponse(status: 200, body: responseBody, on: connection)
    }
  }

  private func sendHTTPResponse(status: Int, body: Data, on connection: NWConnection) {
    let statusText: String
    switch status {
    case 200: statusText = "OK"
    case 400: statusText = "Bad Request"
    case 404: statusText = "Not Found"
    case 500: statusText = "Internal Server Error"
    default: statusText = "Unknown"
    }

    var response = "HTTP/1.1 \(status) \(statusText)\r\n"
    response += "Content-Type: application/json\r\n"
    response += "Content-Length: \(body.count)\r\n"
    response += "Connection: keep-alive\r\n"
    response += "\r\n"

    var responseData = Data(response.utf8)
    responseData.append(body)

    connection.send(content: responseData, completion: .contentProcessed { _ in })
  }

  // MARK: - JSON-RPC Handling

  private func handleRPC(body: Data) async -> (Int, Data) {
    do {
      let json = try JSONSerialization.jsonObject(with: body, options: [])
      guard let dict = json as? [String: Any] else {
        return (400, JSONRPCResponseBuilder.makeError(id: nil, code: -32600, message: "Invalid Request"))
      }

      let method = dict["method"] as? String ?? ""
      let id = dict["id"]
      let params = dict["params"] as? [String: Any]

      // Let host app handle custom methods first
      if let customHandler = onRequest,
         let result = await customHandler(method, id, params) {
        return result
      }

      // Built-in methods
      switch method {
      case "initialize", "mcp/initialize":
        let result: [String: Any] = [
          "protocolVersion": "2024-11-05",
          "serverInfo": ["name": "MCPServerKit", "version": "1.0"],
          "capabilities": ["tools": [:]]
        ]
        return (200, JSONRPCResponseBuilder.makeResult(id: id, result: result))

      case "initialized", "notifications/initialized":
        return (200, Data())

      case "notifications/cancelled", "cancelled",
           "notifications/progress", "progress",
           "notifications/message", "message",
           "$/cancelRequest", "$/progress":
        return (200, Data())

      case "tools/list":
        return (200, JSONRPCResponseBuilder.makeResult(id: id, result: ["tools": registry.toolList()]))

      case "tools/call":
        return await handleToolCall(id: id, params: params)

      default:
        if id == nil {
          return (200, Data())
        }
        return (400, JSONRPCResponseBuilder.makeError(id: id, code: -32601, message: "Method not found"))
      }
    } catch {
      return (500, JSONRPCResponseBuilder.makeError(id: nil, code: -32603, message: error.localizedDescription))
    }
  }

  private func handleToolCall(id: Any?, params: [String: Any]?) async -> (Int, Data) {
    guard let params, let name = params["name"] as? String else {
      return (400, JSONRPCResponseBuilder.makeError(id: id, code: -32602, message: "Invalid params"))
    }

    guard registry.definition(named: name) != nil else {
      return (400, JSONRPCResponseBuilder.makeError(id: id, code: -32601, message: "Unknown tool"))
    }

    guard registry.isToolEnabled(name) else {
      return (400, JSONRPCResponseBuilder.makeError(id: id, code: -32010, message: "Tool disabled"))
    }

    let arguments = params["arguments"] as? [String: Any] ?? [:]

    if let handler = registry.handler(for: name) {
      return await handler.handle(name: name, id: id, arguments: arguments)
    }

    return (400, JSONRPCResponseBuilder.makeError(id: id, code: -32601, message: "No handler for tool"))
  }
}

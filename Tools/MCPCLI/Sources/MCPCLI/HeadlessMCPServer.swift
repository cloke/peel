import Foundation
import Network

final class HeadlessMCPServer: @unchecked Sendable {
  private let config: MCPHeadlessConfig
  private var listener: NWListener?
  private let queue = DispatchQueue(label: "mcpcli.server", qos: .userInitiated)

  init(config: MCPHeadlessConfig) {
    self.config = config
  }

  @discardableResult
  func start() -> Bool {
    let params = NWParameters.tcp
    params.allowLocalEndpointReuse = true
    guard let port = NWEndpoint.Port(rawValue: UInt16(config.port)) else {
      fputs("Error: invalid port \(config.port)\n", stderr)
      return false
    }
    do {
      let listener = try NWListener(using: params, on: port)
      listener.stateUpdateHandler = { [weak self] state in
        switch state {
        case .ready:
          print("MCPCLI MCP server listening on port \(self?.config.port ?? 0)")
        case .failed(let error):
          fputs("Listener failed: \(error)\n", stderr)
          exit(EXIT_FAILURE)
        default:
          break
        }
      }
      listener.newConnectionHandler = { [weak self] connection in
        self?.handleConnection(connection)
      }
      listener.start(queue: queue)
      self.listener = listener
      return true
    } catch {
      fputs("Error creating listener: \(error)\n", stderr)
      return false
    }
  }

  func waitForever() async {
    await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in
      RunLoop.main.run()
    }
  }

  // MARK: - Connection handling

  private func handleConnection(_ connection: NWConnection) {
    connection.stateUpdateHandler = { state in
      if case .failed(let error) = state {
        print("Connection failed: \(error)")
      }
    }
    connection.start(queue: queue)
    receiveData(from: connection, buffer: Data())
  }

  private func receiveData(from connection: NWConnection, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
      guard let self else { return }
      if let error {
        print("Receive error: \(error)")
        return
      }
      var accumulated = buffer
      if let data { accumulated.append(data) }

      // Try to extract a complete HTTP request from the buffer
      let processed = self.processBuffer(accumulated, connection: connection)
      if !isComplete {
        self.receiveData(from: connection, buffer: processed)
      }
    }
  }

  /// Processes the buffer, sends responses for complete requests, returns leftover bytes.
  private func processBuffer(_ buffer: Data, connection: NWConnection) -> Data {
    var remaining = buffer
    while true {
      guard let (request, rest) = extractHTTPRequest(from: remaining) else { break }
      remaining = rest
      handleRequest(request, connection: connection)
    }
    return remaining
  }

  // MARK: - HTTP framing

  private struct HTTPRequest {
    let method: String
    let path: String
    let body: Data
  }

  /// Extracts one HTTP request from buffer. Returns (request, leftoverData) or nil if incomplete.
  private func extractHTTPRequest(from buffer: Data) -> (HTTPRequest, Data)? {
    guard let headerEnd = findHeaderEnd(in: buffer) else { return nil }
    let headerData = buffer.prefix(headerEnd)
    guard let headerString = String(data: headerData, encoding: .utf8) else { return nil }

    let headerLines = headerString.components(separatedBy: "\r\n")
    guard let requestLine = headerLines.first else { return nil }
    let parts = requestLine.components(separatedBy: " ")
    guard parts.count >= 2 else { return nil }
    let method = parts[0]
    let path = parts[1]

    var contentLength = 0
    for line in headerLines.dropFirst() {
      let lower = line.lowercased()
      if lower.hasPrefix("content-length:") {
        let val = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
        contentLength = Int(val) ?? 0
      }
    }

    let bodyStart = headerEnd + 4 // skip \r\n\r\n
    guard buffer.count >= bodyStart + contentLength else { return nil }
    let body = buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
    let leftover = buffer.subdata(in: (bodyStart + contentLength)..<buffer.count)
    return (HTTPRequest(method: method, path: path, body: body), leftover)
  }

  private func findHeaderEnd(in data: Data) -> Int? {
    let separator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A] // \r\n\r\n
    guard data.count >= 4 else { return nil }
    for i in 0...(data.count - 4) {
      if data[i] == separator[0] && data[i+1] == separator[1] &&
         data[i+2] == separator[2] && data[i+3] == separator[3] {
        return i
      }
    }
    return nil
  }

  // MARK: - JSON-RPC dispatch

  private func handleRequest(_ req: HTTPRequest, connection: NWConnection) {
    // OPTIONS pre-flight
    if req.method == "OPTIONS" {
      sendHTTPResponse(status: 200, body: Data(), connection: connection)
      return
    }

    guard let json = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any] else {
      sendJSONRPCError(id: nil, code: -32700, message: "Parse error", connection: connection)
      return
    }

    let idValue = json["id"]
    let method = json["method"] as? String ?? ""

    print("[\(Date())] method=\(method)")

    switch method {
    case "initialize", "mcp/initialize":
      let result: [String: Any] = [
        "protocolVersion": "2024-11-05",
        "serverInfo": ["name": "MCPCLI Headless Server", "version": "1.0"],
        "capabilities": ["tools": [:] as [String: Any]]
      ]
      sendJSONRPCResult(id: idValue, result: result, connection: connection)

    case "initialized", "notifications/initialized":
      sendHTTPResponse(status: 200, body: Data(), connection: connection)

    case "tools/list":
      let tools: [[String: Any]]
      if let allowed = config.allowedTools {
        tools = allowed.map { name in
          ["name": name, "description": "", "inputSchema": ["type": "object", "properties": [:] as [String: Any]]]
        }
      } else {
        tools = []
      }
      sendJSONRPCResult(id: idValue, result: ["tools": tools], connection: connection)

    default:
      sendJSONRPCError(id: idValue, code: -32601, message: "Method not found", connection: connection)
    }
  }

  // MARK: - Response helpers

  private func sendJSONRPCResult(id: Any?, result: [String: Any], connection: NWConnection) {
    var response: [String: Any] = ["jsonrpc": "2.0", "result": result]
    if let id { response["id"] = id }
    guard let body = try? JSONSerialization.data(withJSONObject: response) else { return }
    sendHTTPResponse(status: 200, body: body, connection: connection)
  }

  private func sendJSONRPCError(id: Any?, code: Int, message: String, connection: NWConnection) {
    var response: [String: Any] = [
      "jsonrpc": "2.0",
      "error": ["code": code, "message": message]
    ]
    if let id { response["id"] = id }
    guard let body = try? JSONSerialization.data(withJSONObject: response) else { return }
    sendHTTPResponse(status: 200, body: body, connection: connection)
  }

  private func sendHTTPResponse(status: Int, body: Data, connection: NWConnection) {
    let headers = "HTTP/1.1 \(status) OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: keep-alive\r\n\r\n"
    var responseData = headers.data(using: .utf8) ?? Data()
    responseData.append(body)
    connection.send(content: responseData, completion: .contentProcessed { error in
      if let error { print("Send error: \(error)") }
    })
  }
}

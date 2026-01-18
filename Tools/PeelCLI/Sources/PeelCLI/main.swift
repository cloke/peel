import Foundation

struct CLIOptions {
  var port: Int = 8765
  var command: String?
  var prompt: String?
  var templateId: String?
  var templateName: String?
  var workingDirectory: String?
  var enableReviewLoop: Bool?
}

enum CLIError: LocalizedError {
  case message(String)

  var errorDescription: String? {
    switch self {
    case .message(let message):
      return message
    }
  }
}

@main
struct PeelCLI {
  static func main() async {
    do {
      let options = try parseArguments()
      try await run(options: options)
    } catch {
      writeError(error.localizedDescription)
      exit(EXIT_FAILURE)
    }
  }
}

private func parseArguments() throws -> CLIOptions {
  var options = CLIOptions()
  var iterator = ProcessInfo.processInfo.arguments.dropFirst().makeIterator()

  while let arg = iterator.next() {
    switch arg {
    case "--port":
      guard let value = iterator.next(), let port = Int(value) else {
        throw CLIError.message("--port requires an integer value")
      }
      options.port = port
    case "--prompt":
      options.prompt = iterator.next()
    case "--template-id":
      options.templateId = iterator.next()
    case "--template-name":
      options.templateName = iterator.next()
    case "--working-directory":
      options.workingDirectory = iterator.next()
    case "--enable-review-loop":
      options.enableReviewLoop = true
    case "--disable-review-loop":
      options.enableReviewLoop = false
    case "-h", "--help":
      print(usageText())
      exit(EXIT_SUCCESS)
    default:
      if options.command == nil {
        options.command = arg
      } else {
        throw CLIError.message("Unexpected argument: \(arg)")
      }
    }
  }

  return options
}

private func run(options: CLIOptions) async throws {
  guard let command = options.command else {
    throw CLIError.message(usageText())
  }

  switch command {
  case "tools-list":
    try await printRPCResult(method: "tools/list", params: nil, port: options.port)
  case "templates-list":
    try await printRPCResult(method: "tools/call", params: [
      "name": "templates.list",
      "arguments": [:]
    ], port: options.port)
  case "chains-run":
    guard let prompt = options.prompt, !prompt.isEmpty else {
      throw CLIError.message("chains-run requires --prompt")
    }

    var arguments: [String: Any] = ["prompt": prompt]
    if let templateId = options.templateId { arguments["templateId"] = templateId }
    if let templateName = options.templateName { arguments["templateName"] = templateName }
    if let workingDirectory = options.workingDirectory { arguments["workingDirectory"] = workingDirectory }
    if let enableReviewLoop = options.enableReviewLoop { arguments["enableReviewLoop"] = enableReviewLoop }

    try await printRPCResult(method: "tools/call", params: [
      "name": "chains.run",
      "arguments": arguments
    ], port: options.port)
  case "server-stop":
    try await printRPCResult(method: "tools/call", params: [
      "name": "server.stop",
      "arguments": [:]
    ], port: options.port)
  case "app-quit":
    try await printRPCResult(method: "tools/call", params: [
      "name": "app.quit",
      "arguments": [:]
    ], port: options.port)
  default:
    throw CLIError.message("Unknown command: \(command)\n\n\(usageText())")
  }
}

private func printRPCResult(method: String, params: [String: Any]?, port: Int) async throws {
  let client = MCPClient(port: port)
  let response = try await client.call(method: method, params: params)

  let data = try JSONSerialization.data(withJSONObject: response, options: [.prettyPrinted])
  if let text = String(data: data, encoding: .utf8) {
    print(text)
  } else {
    print(response)
  }
}

private func usageText() -> String {
  """
  Peel MCP CLI

  Usage:
    peel-mcp [--port <port>] <command> [options]

  Commands:
    tools-list
    templates-list
    chains-run --prompt <text> [--template-id <uuid> | --template-name <name>] [--working-directory <path>] [--enable-review-loop|--disable-review-loop]
    server-stop
    app-quit
  """
}

private func writeError(_ message: String) {
  if let data = (message + "\n").data(using: .utf8) {
    FileHandle.standardError.write(data)
  }
}

struct MCPClient {
  let port: Int
  private let session: URLSession

  init(port: Int) {
    self.port = port
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 600
    config.timeoutIntervalForResource = 600
    self.session = URLSession(configuration: config)
  }

  func call(method: String, params: [String: Any]?) async throws -> [String: Any] {
    var body: [String: Any] = [
      "jsonrpc": "2.0",
      "id": Int(Date().timeIntervalSince1970),
      "method": method
    ]

    if let params {
      body["params"] = params
    }

    let requestData = try JSONSerialization.data(withJSONObject: body, options: [])
    guard let url = URL(string: "http://127.0.0.1:\(port)/rpc") else {
      throw CLIError.message("Invalid MCP URL")
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = requestData
    request.timeoutInterval = 600

    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw CLIError.message("No HTTP response")
    }

    guard (200...299).contains(http.statusCode) else {
      let errorText = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
      throw CLIError.message(errorText)
    }

    let json = try JSONSerialization.jsonObject(with: data, options: [])
    guard let dict = json as? [String: Any] else {
      throw CLIError.message("Invalid response JSON")
    }

    return dict
  }
}

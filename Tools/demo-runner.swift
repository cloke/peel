#!/usr/bin/env swift
import Foundation

struct DemoScript: Decodable {
  let id: String
  let title: String
  let description: String
  let preconditions: [String]
  let continueToken: String
  let steps: [Step]
}

struct Step: Decodable {
  let type: String
  let command: String?
  let tool: String?
  let arguments: JSONValue?
  let path: String?
  let message: String?
  let template: String?
  let inputs: [String]?
}

enum JSONValue: Decodable {
  case object([String: JSONValue])
  case array([JSONValue])
  case string(String)
  case number(Double)
  case bool(Bool)
  case null

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let object = try? container.decode([String: JSONValue].self) {
      self = .object(object)
    } else if let array = try? container.decode([JSONValue].self) {
      self = .array(array)
    } else if let bool = try? container.decode(Bool.self) {
      self = .bool(bool)
    } else if let number = try? container.decode(Double.self) {
      self = .number(number)
    } else if let string = try? container.decode(String.self) {
      self = .string(string)
    } else {
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
    }
  }

  func toAny() -> Any {
    switch self {
    case .object(let dict):
      return dict.mapValues { $0.toAny() }
    case .array(let values):
      return values.map { $0.toAny() }
    case .string(let value):
      return value
    case .number(let value):
      return value
    case .bool(let value):
      return value
    case .null:
      return NSNull()
    }
  }
}

struct RunnerConfig {
  let scriptPath: String
  let port: Int
  let auto: Bool
}

enum RunnerError: Error {
  case usage
  case missingScript
  case invalidURL
  case requestFailed
}

func printUsage() {
  print("""
Usage:
  ./Tools/demo-runner.swift <script.json> [--port 8765] [--auto]
""")
}

func parseArgs() throws -> RunnerConfig {
  var args = CommandLine.arguments.dropFirst()
  var port = 8765
  var auto = false
  var scriptPath: String?

  while let arg = args.first {
    args = args.dropFirst()
    switch arg {
    case "--help", "-h":
      throw RunnerError.usage
    case "--port":
      guard let value = args.first, let parsed = Int(value) else {
        throw RunnerError.usage
      }
      port = parsed
      args = args.dropFirst()
    case "--auto":
      auto = true
    default:
      if scriptPath == nil {
        scriptPath = arg
      } else {
        throw RunnerError.usage
      }
    }
  }

  guard let scriptPath else {
    throw RunnerError.missingScript
  }

  return RunnerConfig(scriptPath: scriptPath, port: port, auto: auto)
}

func loadScript(path: String) throws -> DemoScript {
  let url = URL(fileURLWithPath: path)
  let data = try Data(contentsOf: url)
  let decoder = JSONDecoder()
  return try decoder.decode(DemoScript.self, from: data)
}

func runShell(_ command: String, environment: [String: String]) throws {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/bin/zsh")
  process.arguments = ["-lc", command]
  process.environment = ProcessInfo.processInfo.environment.merging(environment) { current, _ in current }
  process.standardInput = FileHandle.standardInput
  process.standardOutput = FileHandle.standardOutput
  process.standardError = FileHandle.standardError
  try process.run()
  process.waitUntilExit()
  if process.terminationStatus != 0 {
    throw RunnerError.requestFailed
  }
}

func callMCP(tool: String, arguments: JSONValue?, port: Int) throws -> Any {
  guard let url = URL(string: "http://127.0.0.1:\(port)/rpc") else {
    throw RunnerError.invalidURL
  }

  let payload: [String: Any] = [
    "jsonrpc": "2.0",
    "id": 1,
    "method": "tools/call",
    "params": [
      "name": tool,
      "arguments": arguments?.toAny() ?? [:]
    ]
  ]

  let data = try JSONSerialization.data(withJSONObject: payload, options: [])

  var request = URLRequest(url: url)
  request.httpMethod = "POST"
  request.setValue("application/json", forHTTPHeaderField: "Content-Type")
  request.httpBody = data

  let semaphore = DispatchSemaphore(value: 0)
  var resultData: Data?
  var resultError: Error?

  URLSession.shared.dataTask(with: request) { data, _, error in
    resultData = data
    resultError = error
    semaphore.signal()
  }.resume()

  _ = semaphore.wait(timeout: .now() + 60)

  if let error = resultError {
    throw error
  }

  guard let resultData else {
    throw RunnerError.requestFailed
  }

  return try JSONSerialization.jsonObject(with: resultData, options: [])
}

func prettyPrint(_ value: Any) {
  if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
     let string = String(data: data, encoding: .utf8) {
    print(string)
  } else {
    print(value)
  }
}

func pause(message: String?, continueToken: String, auto: Bool) {
  guard !auto else { return }
  let prompt = message ?? "Type \(continueToken) to continue."
  print("\n⏸️  \(prompt)")
  while true {
    if let line = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines),
       line.lowercased() == continueToken.lowercased() {
      break
    }
    print("Type \(continueToken) to continue.")
  }
}

func run(script: DemoScript, config: RunnerConfig) throws {
  print("\n🎬 Demo: \(script.title)")
  print(script.description)
  if !script.preconditions.isEmpty {
    print("\nPreconditions:")
    script.preconditions.forEach { print("- \($0)") }
  }

  for (index, step) in script.steps.enumerated() {
    print("\n➡️  Step \(index + 1): \(step.type)")
    switch step.type {
    case "app.launch":
      guard let command = step.command else { throw RunnerError.requestFailed }
      try runShell(command, environment: ["MCP_PORT": "\(config.port)"])
    case "app.activate":
      _ = try callMCP(tool: "app.activate", arguments: nil, port: config.port)
    case "mcp.call":
      guard let tool = step.tool else { throw RunnerError.requestFailed }
      let response = try callMCP(tool: tool, arguments: step.arguments, port: config.port)
      prettyPrint(response)
    case "ui.navigate":
      guard let viewId = step.path else { throw RunnerError.requestFailed }
      let response = try callMCP(tool: "ui.navigate", arguments: .object(["viewId": .string(viewId)]), port: config.port)
      prettyPrint(response)
    case "ui.tap":
      guard let controlId = step.path else { throw RunnerError.requestFailed }
      let response = try callMCP(tool: "ui.tap", arguments: .object(["controlId": .string(controlId)]), port: config.port)
      prettyPrint(response)
    case "ui.setText":
      guard let controlId = step.path, let value = step.message else { throw RunnerError.requestFailed }
      let response = try callMCP(
        tool: "ui.setText",
        arguments: .object(["controlId": .string(controlId), "value": .string(value)]),
        port: config.port
      )
      prettyPrint(response)
    case "ui.toggle":
      guard let controlId = step.path else { throw RunnerError.requestFailed }
      let onValue = step.message?.lowercased() == "true"
      let response = try callMCP(
        tool: "ui.toggle",
        arguments: .object(["controlId": .string(controlId), "on": .bool(onValue)]),
        port: config.port
      )
      prettyPrint(response)
    case "ui.select":
      guard let controlId = step.path, let value = step.message else { throw RunnerError.requestFailed }
      let response = try callMCP(
        tool: "ui.select",
        arguments: .object(["controlId": .string(controlId), "value": .string(value)]),
        port: config.port
      )
      prettyPrint(response)
    case "ui.snapshot":
      let response = try callMCP(tool: "ui.snapshot", arguments: nil, port: config.port)
      prettyPrint(response)
    case "prompt.compose":
      if let template = step.template {
        print("Prompt template:\n\(template)")
      }
      if let inputs = step.inputs, !inputs.isEmpty {
        print("Inputs:")
        inputs.forEach { print("- \($0)") }
      }
    case "pause":
      pause(message: step.message, continueToken: script.continueToken, auto: config.auto)
    default:
      print("Unknown step type: \(step.type)")
    }
  }

  print("\n✅ Demo completed.")
}

let config: RunnerConfig

do {
  config = try parseArgs()
} catch RunnerError.usage {
  printUsage()
  exit(0)
} catch {
  printUsage()
  exit(1)
}

do {
  let script = try loadScript(path: config.scriptPath)
  try run(script: script, config: config)
} catch {
  print("Error: \(error)")
  exit(1)
}

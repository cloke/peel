import Foundation

func printUsage() {
  print("""
  Usage: mcp-server --config <path> [--port <port>]

  Options:
    --config <path>   Path to JSON config file (required)
    --port <port>     Override port from config file
    -h, --help        Show this help message

  Example:
    mcp-server --config config.json
    mcp-server --config config.json --port 9000
  """)
}

let args = CommandLine.arguments
var configPath: String?
var portOverride: Int?

var argIndex = 1
while argIndex < args.count {
  switch args[argIndex] {
  case "-h", "--help":
    printUsage()
    exit(EXIT_SUCCESS)
  case "--config":
    argIndex += 1
    guard argIndex < args.count else {
      fputs("Error: --config requires a path argument\n", stderr)
      exit(EXIT_FAILURE)
    }
    configPath = args[argIndex]
  case "--port":
    argIndex += 1
    guard argIndex < args.count, let p = Int(args[argIndex]) else {
      fputs("Error: --port requires an integer argument\n", stderr)
      exit(EXIT_FAILURE)
    }
    portOverride = p
  default:
    fputs("Unknown argument: \(args[argIndex])\n", stderr)
    printUsage()
    exit(EXIT_FAILURE)
  }
  argIndex += 1
}

guard let configPath else {
  fputs("Error: --config <path> is required\n", stderr)
  printUsage()
  exit(EXIT_FAILURE)
}

var config: MCPHeadlessConfig
do {
  config = try MCPHeadlessConfig.load(from: configPath)
} catch {
  fputs("Error loading config from \(configPath): \(error)\n", stderr)
  exit(EXIT_FAILURE)
}

if let portOverride { config.port = portOverride }

print("MCPCLI headless MCP server starting on port \(config.port)")
if let root = config.repoRoot { print("  repoRoot: \(root)") }
if let tools = config.allowedTools { print("  allowedTools: \(tools.joined(separator: ", "))") }
if let store = config.dataStorePath { print("  dataStorePath: \(store)") }
print("  logLevel: \(config.logLevel)")

let server = HeadlessMCPServer(config: config)
guard server.start() else {
  fputs("Failed to start server on port \(config.port)\n", stderr)
  exit(EXIT_FAILURE)
}

// Keep the process alive (dispatchMain() is called inside waitForever)
let sema = DispatchSemaphore(value: 0)
Task {
  await server.waitForever()
  sema.signal()
}
sema.wait()

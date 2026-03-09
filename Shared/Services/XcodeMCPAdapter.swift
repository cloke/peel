import Foundation
import OSLog

/// Error types for Xcode MCP operations
enum XcodeMCPError: LocalizedError {
    case xcodeNotRunning
    case mcpbridgeNotFound
    case communicationFailed(String)
    case invalidResponse(String)
    case timeout
    case xcodeProcessError(Int32)
    
    var errorDescription: String? {
        switch self {
        case .xcodeNotRunning:
            return "Xcode is not running. Please open Xcode and try again."
        case .mcpbridgeNotFound:
            return "mcpbridge not found. Ensure Xcode 26.3+ is installed."
        case .communicationFailed(let reason):
            return "Failed to communicate with Xcode MCP: \(reason)"
        case .invalidResponse(let reason):
            return "Invalid response from Xcode MCP: \(reason)"
        case .timeout:
            return "Xcode MCP request timed out. Xcode may be busy."
        case .xcodeProcessError(let code):
            return "Xcode process error: \(code)"
        }
    }
}

/// Represents an MCP tool discovered from Xcode
struct XcodeMCPTool: Codable {
  let name: String
  let description: String
}


/// Manages communication with Xcode's mcpbridge via STDIO
/// This actor handles the entire lifecycle of mcpbridge subprocess and JSON-RPC communication
actor XcodeMCPAdapter {
    private static let logger = Logger(subsystem: "com.peel.xcode-mcp", category: "adapter")
    
    // MARK: - Properties
    
    private var mcpProcess: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var requestID: Int = 1
    
    // Configuration
    private let timeout: TimeInterval
    private let debugEnabled: Bool
    
    // MARK: - Initialization
    
    init(timeout: TimeInterval = 10.0, debugEnabled: Bool = false) {
        self.timeout = timeout
        self.debugEnabled = debugEnabled
    }
    
    // MARK: - Public Methods
    
    /// Start the mcpbridge subprocess
    /// - Throws: XcodeMCPError if unable to start mcpbridge
    nonisolated func start() async throws {
        try await MainActor.run {
            Self.logger.info("Starting XcodeMCPAdapter")
            
            // Verify mcpbridge exists
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["xcrun", "mcpbridge", "--help"]
            
            let testPipe = Pipe()
            process.standardOutput = testPipe
            process.standardError = testPipe
            
            do {
                try process.run()
                process.waitUntilExit()
                
                guard process.terminationStatus == 0 else {
                    throw XcodeMCPError.mcpbridgeNotFound
                }
                
                Self.logger.debug("mcpbridge found and accessible")
            } catch {
                throw XcodeMCPError.mcpbridgeNotFound
            }
        }
    }
    
  /// List all available Xcode MCP tools
  /// - Returns: Array of XcodeMCPTool structures
  func listTools() async throws -> [XcodeMCPTool] {
      let request: [String: Any] = [
          "jsonrpc": "2.0",
          "id": 1,
          "method": "tools/list",
          "params": [:]
      ]
      
      let response = try await callMCP(request: request)
      
      // Parse tools from response
      if let result = response["result"] as? [String: Any],
         let toolArray = result["tools"] as? [[String: Any]] {
          return toolArray.compactMap { toolDict in
              guard let name = toolDict["name"] as? String,
                    let description = toolDict["description"] as? String else {
                  return nil
              }
              return XcodeMCPTool(
                  name: name,
                  description: description
              )
          }
      }
      
      throw XcodeMCPError.invalidResponse("Missing tools in response")
  }
    
  /// Call a specific Xcode MCP tool
  func callTool(
      method: String = "tools/call",
      toolName: String,
      arguments: [String: Any]
  ) async throws -> [String: Any] {
      var params: [String: Any] = [
          "name": toolName
      ]
      
      if !arguments.isEmpty {
          params["arguments"] = arguments
      }
      
      let currentId = requestID
      let request: [String: Any] = [
          "jsonrpc": "2.0",
          "id": currentId,
          "method": method,
          "params": params
      ]
      
      return try await callMCP(request: request)
  }
    
    /// Check if Xcode is currently running and accessible
    /// - Returns: true if Xcode is running, false otherwise
    nonisolated func isXcodeAvailable() -> Bool {
        let process = Process()
        process.launchPath = "/bin/sh"
        process.arguments = ["-c", "ps aux | grep -E '/Applications/Xcode.app.*MacOS/Xcode' | grep -v grep"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return !output.isEmpty
        } catch {
            Self.logger.warning("Failed to check if Xcode is running: \(error)")
            return false
        }
    }
    
  /// Gracefully shutdown the mcpbridge subprocess
  func shutdown() {
      Self.logger.info("Shutting down XcodeMCPAdapter")
      
      if let process = mcpProcess, process.isRunning {
          process.terminate()
          process.waitUntilExit()
      }
  }
    
    // MARK: - Private Methods
    
    /// Internal method to send JSON-RPC request to mcpbridge and receive response
    private func callMCP(request: [String: Any]) async throws -> [String: Any] {
        try await ensureProcessRunning()
        
        guard let inputPipe = inputPipe, let outputPipe = outputPipe else {
            throw XcodeMCPError.communicationFailed("Pipes not initialized")
        }
        
        // Serialize request to JSON
        let requestData = try JSONSerialization.data(withJSONObject: request)
        guard let requestJSON = String(data: requestData, encoding: .utf8) else {
            throw XcodeMCPError.invalidResponse("Failed to serialize request")
        }
        
        if debugEnabled {
            Self.logger.debug("Sending: \(requestJSON)")
        }
        
        // Write request to stdin
        guard let requestBytes = (requestJSON + "\n").data(using: .utf8) else {
            throw XcodeMCPError.invalidResponse("Failed to encode request")
        }
        
        inputPipe.fileHandleForWriting.write(requestBytes)
        
        // Read response from stdout with timeout
        let startTime = Date()
        var responseData = Data()
        
        while Date().timeIntervalSince(startTime) < timeout {
            let available = outputPipe.fileHandleForReading.availableData
            if !available.isEmpty {
                responseData.append(available)
                
                // Try to parse as JSON
                if let responseString = String(data: responseData, encoding: .utf8),
                   responseString.contains("\n") {
                    let lines = responseString.split(separator: "\n", omittingEmptySubsequences: true)
                    if let lastLine = lines.last,
                       let jsonData = lastLine.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                        
                        if debugEnabled {
                            Self.logger.debug("Received: \(String(describing: json))")
                        }
                        
                        return json
                    }
                }
            }
            
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
        
        throw XcodeMCPError.timeout
    }
    
    /// Ensure mcpbridge subprocess is running
    private func ensureProcessRunning() async throws {
        // Check if process needs to be started
        if let process = mcpProcess, process.isRunning {
            return
        }
        
        // Verify Xcode is running first
        guard isXcodeAvailable() else {
            throw XcodeMCPError.xcodeNotRunning
        }
        
        try startProcess()
    }
    
    /// Start the mcpbridge process
    private func startProcess() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["xcrun", "mcpbridge"]
        
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        
        try process.run()
        
        self.mcpProcess = process
        self.inputPipe = inputPipe
        self.outputPipe = outputPipe
        
        Self.logger.info("mcpbridge process started (PID: \(process.processIdentifier))")
    }
}

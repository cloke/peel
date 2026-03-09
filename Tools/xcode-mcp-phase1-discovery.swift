#!/usr/bin/env swift

import Foundation

/// Phase 1: Discover all available Xcode MCP tools
///
/// This script:
/// 1. Launches mcpbridge subprocess
/// 2. Queries tools/list
/// 3. Extracts tool information
/// 4. Saves to JSON catalog
/// 5. Generates documentation
///
/// Run: swift Tools/xcode-mcp-phase1-discovery.swift

let fileManager = FileManager.default
let decoder = JSONDecoder()
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

// Output paths
let tmpDir = "/Users/cloken/code/KitchenSink/tmp"
let toolsJSONPath = "\(tmpDir)/xcode-mcp-tools.json"
let referenceDocPath = "/Users/cloken/code/KitchenSink/Docs/reference/XCODE_MCP_TOOL_REFERENCE.md"

print("🔍 Phase 1: Xcode MCP Tool Discovery")
print(String(repeating: "=", count: 60))

// MARK: - Step 1: Check Xcode availability

print("\n✓ Step 1: Checking Xcode availability...")

let xcodeCheckProcess = Process()
xcodeCheckProcess.launchPath = "/bin/sh"
xcodeCheckProcess.arguments = ["-c", "xcodebuild -version"]

let xcodeCheckPipe = Pipe()
xcodeCheckProcess.standardOutput = xcodeCheckPipe

do {
    try xcodeCheckProcess.run()
    xcodeCheckProcess.waitUntilExit()
    
    if xcodeCheckProcess.terminationStatus != 0 {
        print("❌ Xcode not found or not configured")
        exit(1)
    }
    
    let versionData = xcodeCheckPipe.fileHandleForReading.readDataToEndOfFile()
    if let versionString = String(data: versionData, encoding: .utf8) {
        print("✓ Xcode version: \(versionString.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
} catch {
    print("❌ Error checking Xcode: \(error)")
    exit(1)
}

// MARK: - Step 2: Launch mcpbridge

print("\n✓ Step 2: Launching mcpbridge...")

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
process.arguments = ["xcrun", "mcpbridge"]

let inputPipe = Pipe()
let outputPipe = Pipe()

process.standardInput = inputPipe
process.standardOutput = outputPipe
process.standardError = FileHandle.nullDevice

do {
    try process.run()
    print("✓ mcpbridge launched (PID: \(process.processIdentifier))")
} catch {
    print("❌ Failed to launch mcpbridge: \(error)")
    exit(1)
}

// MARK: - Step 3: Query tools/list

print("\n✓ Step 3: Querying available tools...")

let toolsListRequest: [String: Any] = [
    "jsonrpc": "2.0",
    "id": 1,
    "method": "tools/list",
    "params": [:]
]

guard let requestData = try? JSONSerialization.data(withJSONObject: toolsListRequest),
      let requestJSON = String(data: requestData, encoding: .utf8) else {
    print("❌ Failed to create request")
    process.terminate()
    exit(1)
}

guard let requestBytes = (requestJSON + "\n").data(using: .utf8) else {
    print("❌ Failed to encode request")
    process.terminate()
    exit(1)
}

inputPipe.fileHandleForWriting.write(requestBytes)

// Read response with timeout
let startTime = Date()
var responseData = Data()
let timeout: TimeInterval = 10.0

while Date().timeIntervalSince(startTime) < timeout {
    let available = outputPipe.fileHandleForReading.availableData
    if !available.isEmpty {
        responseData.append(available)
        
        // Try to parse as JSON
        if let responseString = String(data: responseData, encoding: .utf8),
           responseString.contains("\n") {
            if let jsonData = responseString.data(using: .utf8),
               let jsonResponse = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                
                print("✓ Received tools list response")
                
                // MARK: - Step 4: Parse and organize tools
                
                print("\n✓ Step 4: Parsing tools...")
                
                var toolsByCategory: [String: [[String: Any]]] = [:]
                var totalTools = 0
                
                if let result = jsonResponse["result"] as? [String: Any],
                   let toolsArray = result["tools"] as? [[String: Any]] {
                    
                    totalTools = toolsArray.count
                    
                    for toolDict in toolsArray {
                        if let name = toolDict["name"] as? String {
                            let parts = name.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: true)
                            let category = parts.count > 1 ? String(parts[1]) : "other"
                            
                            if toolsByCategory[category] == nil {
                                toolsByCategory[category] = []
                            }
                            toolsByCategory[category]?.append(toolDict)
                        }
                    }
                }
                
                print("✓ Found \(totalTools) tools in \(toolsByCategory.count) categories")
                
                // MARK: - Step 5: Save to JSON
                
                print("\n✓ Step 5: Saving tool catalog...")
                
                let catalog: [String: Any] = [
                    "timestamp": ISO8601DateFormatter().string(from: Date()),
                    "xcodeVersion": "26.3+",
                    "toolCount": totalTools,
                    "categories": toolsByCategory,
                    "tools": toolsByCategory.values.flatMap { $0 }
                ]
                
                do {
                    let jsonData = try JSONSerialization.data(withJSONObject: catalog, options: [.prettyPrinted, .sortedKeys])
                    try jsonData.write(to: URL(fileURLWithPath: toolsJSONPath))
                    print("✓ Tool catalog saved: \(toolsJSONPath)")
                } catch {
                    print("❌ Failed to save catalog: \(error)")
                }
                
                // MARK: - Step 6: Generate documentation
                
                print("\n✓ Step 6: Generating documentation...")
                
                var documentation = """
                # Xcode MCP Tool Reference
                
                **Generated:** \(DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .medium))
                **Xcode Version:** 26.3+
                **Tool Count:** \(totalTools)
                
                ---
                
                ## Tool Categories
                
                """
                
                for (category, tools) in toolsByCategory.sorted(by: { $0.key < $1.key }) {
                    documentation += "\n### \(category.capitalized) (\(tools.count) tools)\n\n"
                    
                    for tool in tools.sorted(by: { ($0["name"] as? String) ?? "" < ($1["name"] as? String) ?? "" }) {
                        if let name = tool["name"] as? String,
                           let description = tool["description"] as? String {
                            documentation += "- **\(name)** — \(description)\n"
                        }
                    }
                }
                
                documentation += """
                
                ---
                
                ## Generated Catalog
                
                See `tmp/xcode-mcp-tools.json` for complete tool specifications including parameters and return types.
                """
                
                do {
                    try documentation.write(toFile: referenceDocPath, atomically: true, encoding: .utf8)
                    print("✓ Documentation generated: \(referenceDocPath)")
                } catch {
                    print("❌ Failed to generate documentation: \(error)")
                }
                
                // Success!
                print("\n" + String(repeating: "=", count: 60))
                print("✅ Phase 1 Discovery Complete!")
                print(String(repeating: "=", count: 60))
                print("\nResults:")
                print("  • Tools discovered: \(totalTools)")
                print("  • Categories: \(toolsByCategory.count)")
                print("  • Catalog: \(toolsJSONPath)")
                print("  • Documentation: \(referenceDocPath)")
                print("\nNext: Review catalog and documentation, then proceed to Phase 2")
                
                process.terminate()
                process.waitUntilExit()
                exit(0)
            }
        }
    }
    
    usleep(100_000) // 100ms
}

print("❌ Timeout waiting for response")
process.terminate()
exit(1)

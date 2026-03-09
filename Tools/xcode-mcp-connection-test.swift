#!/usr/bin/env swift

import Foundation

print("🧪 Testing Xcode MCP Connection...")

// Test 1: Basic mcpbridge execution
print("\n✓ Test 1: Launch mcpbridge and send tools/list request")

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
process.arguments = ["xcrun", "mcpbridge"]

let inputPipe = Pipe()
let outputPipe = Pipe()

process.standardInput = inputPipe
process.standardOutput = outputPipe
process.standardError = FileHandle.standardError

do {
    try process.run()
    print("  ✓ mcpbridge process started (PID: \(process.processIdentifier))")
    
    // Send tools/list request
    let request = """
    {"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}
    """
    
    guard let requestData = (request + "\n").data(using: .utf8) else {
        print("  ❌ Failed to encode request")
        process.terminate()
        exit(1)
    }
    
    print("  ✓ Sending: tools/list request")
    inputPipe.fileHandleForWriting.write(requestData)
    
    // Wait for response with timeout
    let startTime = Date()
    var responseData = Data()
    var toolCount = 0
    
    while Date().timeIntervalSince(startTime) < 5.0 && toolCount == 0 {
        let available = outputPipe.fileHandleForReading.availableData
        if !available.isEmpty {
            responseData.append(available)
            
            if let responseString = String(data: responseData, encoding: .utf8),
               let jsonData = responseString.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
               let result = json["result"] as? [String: Any],
               let tools = result["tools"] as? [[String: Any]] {
                
                toolCount = tools.count
                print("  ✓ Received response with \(toolCount) tools")
                
                // Print tool categories
                var categories: [String: Int] = [:]
                for tool in tools {
                    if let name = tool["name"] as? String {
                        let parts = name.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: true)
                        let category = parts.count > 1 ? String(parts[1]) : "other"
                        categories[category, default: 0] += 1
                    }
                }
                
                print("\n  Tool Categories:")
                for (category, count) in categories.sorted(by: { $0.key < $1.key }) {
                    print("    • \(category): \(count) tools")
                }
            }
        }
        usleep(100_000) // 100ms
    }
    
    if toolCount == 0 {
        print("  ❌ No tools received or timeout")
    } else {
        print("\n✅ SUCCESS: Xcode MCP is fully functional!")
        print("   \(toolCount) tools available")
    }
    
    process.terminate()
    process.waitUntilExit()
    
} catch {
    print("  ❌ Error: \(error)")
    exit(1)
}

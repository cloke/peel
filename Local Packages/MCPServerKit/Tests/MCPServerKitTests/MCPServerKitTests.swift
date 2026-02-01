import Testing
@testable import MCPServerKit

@Suite
struct MCPServerKitTests {
  @Test
  func toolRegistryRegistersDefinitions() async {
    await MainActor.run {
      let registry = MCPToolRegistry()
      let def = MCPToolDefinition(
        name: "test.tool",
        description: "A test tool",
        inputSchema: ["type": "object"],
        category: .state,
        isMutating: false
      )
      registry.register(def)
      
      #expect(registry.allDefinitions.count == 1)
      #expect(registry.definition(named: "test.tool") != nil)
      #expect(registry.definition(named: "unknown") == nil)
    }
  }
  
  @Test
  func toolRegistryBuildsToolList() async {
    await MainActor.run {
      let registry = MCPToolRegistry()
      registry.register(MCPToolDefinition(
        name: "test.tool",
        description: "Test",
        inputSchema: [:],
        category: .state,
        isMutating: false
      ))
      
      let list = registry.toolList()
      #expect(list.count == 1)
      #expect(list[0]["name"] as? String == "test.tool")
      #expect(list[0]["enabled"] as? Bool == true)
    }
  }
  
  @Test
  func toolRegistryPermissionCheck() async {
    await MainActor.run {
      let registry = MCPToolRegistry()
      registry.register(MCPToolDefinition(
        name: "blocked.tool",
        description: "Blocked",
        inputSchema: [:],
        category: .state,
        isMutating: false
      ))
      
      registry.setPermissionCheck { name in
        name != "blocked.tool"
      }
      
      #expect(registry.isToolEnabled("blocked.tool") == false)
      #expect(registry.isToolEnabled("other.tool") == true)
    }
  }
}

import Foundation

struct MCPHeadlessConfig: Codable {
  var port: Int = 8765
  var allowedTools: [String]? = nil
  var repoRoot: String? = nil
  var dataStorePath: String? = nil
  var logLevel: String = "info"

  static func load(from path: String) throws -> MCPHeadlessConfig {
    let url = URL(fileURLWithPath: path)
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(MCPHeadlessConfig.self, from: data)
  }

  func isToolAllowed(_ name: String) -> Bool {
    guard let list = allowedTools else { return true }
    return list.contains(name)
  }
}

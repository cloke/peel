import Foundation

public enum MCPTemplateLoaderError: Error {
  case notFound
  case unreadable
  case decodeError(Error)
}

public struct MCPTemplateLoader {
  public static func load(from url: URL) throws -> MCPTemplate {
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw MCPTemplateLoaderError.notFound
    }
    guard let data = try? Data(contentsOf: url) else {
      throw MCPTemplateLoaderError.unreadable
    }
    do {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      return try decoder.decode(MCPTemplate.self, from: data)
    } catch {
      throw MCPTemplateLoaderError.decodeError(error)
    }
  }

  public static func load(from jsonString: String) throws -> MCPTemplate {
    guard let data = jsonString.data(using: .utf8) else { throw MCPTemplateLoaderError.unreadable }
    do {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      return try decoder.decode(MCPTemplate.self, from: data)
    } catch {
      throw MCPTemplateLoaderError.decodeError(error)
    }
  }
}

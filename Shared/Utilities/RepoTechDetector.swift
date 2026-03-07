import Foundation

struct RepoTechDetector {
  static func detectTags(repoPath: String) -> Set<String> {
    var tags: Set<String> = []
    let fm = FileManager.default
    func exists(_ name: String) -> Bool {
      fm.fileExists(atPath: (repoPath as NSString).appendingPathComponent(name))
    }
    if isEmberRepo(repoPath: repoPath) {
      tags.insert("ember")
      tags.insert("javascript")
    }
    let entries = (try? fm.contentsOfDirectory(atPath: repoPath)) ?? []
    if exists("Package.swift") || entries.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) {
      tags.insert("swift")
    }
    if exists("tsconfig.json") {
      tags.insert("typescript")
      tags.insert("javascript")
    } else if exists("package.json") {
      tags.insert("javascript")
    }
    if exists("Cargo.toml") { tags.insert("rust") }
    if exists("go.mod") { tags.insert("go") }
    if exists("requirements.txt") || exists("pyproject.toml") || exists("setup.py") {
      tags.insert("python")
    }
    if exists("Gemfile") { tags.insert("ruby") }
    return tags
  }

  static func parseTags(_ value: String) -> Set<String> {
    let raw = value.lowercased()
    let separators = CharacterSet(charactersIn: ",;|#\n\t ")
    let parts = raw.components(separatedBy: separators).filter { !$0.isEmpty }
    return Set(parts)
  }

  private static func isEmberRepo(repoPath: String) -> Bool {
    let emberFiles = [
      "ember-cli-build.js",
      "ember-cli-build.cjs",
      "ember-cli-build.mjs",
      "config/environment.js",
      "app/app.js"
    ]
    for file in emberFiles {
      let path = (repoPath as NSString).appendingPathComponent(file)
      if FileManager.default.fileExists(atPath: path) {
        return true
      }
    }

    guard let package = loadPackageJSON(repoPath: repoPath) else {
      return false
    }

    if containsEmberDependency(in: package["dependencies"]) { return true }
    if containsEmberDependency(in: package["devDependencies"]) { return true }
    if containsEmberDependency(in: package["peerDependencies"]) { return true }

    let keywords = stringArray(from: package["keywords"]).map { $0.lowercased() }
    if keywords.contains(where: { $0.contains("ember") }) {
      return true
    }

    return false
  }

  private static func loadPackageJSON(repoPath: String) -> [String: Any]? {
    let path = (repoPath as NSString).appendingPathComponent("package.json")
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
      return nil
    }
    guard let json = try? JSONSerialization.jsonObject(with: data) else {
      return nil
    }
    return json as? [String: Any]
  }

  private static func containsEmberDependency(in value: Any?) -> Bool {
    guard let dict = value as? [String: Any] else {
      return false
    }
    for key in dict.keys {
      let lower = key.lowercased()
      if lower == "ember-cli" ||
          lower == "ember-source" ||
          lower == "ember-data" ||
          lower == "ember-cli-babel" ||
          lower.hasPrefix("@ember/") ||
          lower.hasPrefix("ember-") {
        return true
      }
    }
    return false
  }

  private static func stringArray(from value: Any?) -> [String] {
    if let array = value as? [String] {
      return array
    }
    if let array = value as? [Any] {
      return array.compactMap { $0 as? String }
    }
    return []
  }
}

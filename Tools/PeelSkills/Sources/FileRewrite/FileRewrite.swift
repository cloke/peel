import ArgumentParser
import Foundation

/// Reliable file writing that avoids shell escaping issues
@main
struct FileRewrite: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "file-rewrite",
    abstract: "Write content to files reliably",
    discussion: """
      Writes content to files without shell escaping issues.
      Useful when AI agents need to write multi-line content with special characters.
      
      Content sources (pick one):
        --stdin          Read content from standard input
        --file PATH      Copy content from another file
        --template NAME  Use a named template (plan, roadmap)
        inline content   Pass content as trailing arguments
      """
  )
  
  @Argument(help: "Path to write the file")
  var path: String
  
  @Flag(name: .long, help: "Read content from stdin")
  var stdin: Bool = false
  
  @Option(name: .long, help: "Copy content from source file")
  var file: String?
  
  @Option(name: .long, help: "Use template (plan, roadmap)")
  var template: String?
  
  @Option(name: .long, help: "Template variable KEY=VALUE", transform: { $0 })
  var `var`: [String] = []
  
  @Flag(name: .long, help: "Don't create backup file")
  var noBackup: Bool = false
  
  @Flag(name: .long, help: "Print content without writing")
  var dryRun: Bool = false
  
  @Flag(name: .shortAndLong, help: "Suppress output")
  var quiet: Bool = false
  
  @Flag(name: .long, help: "Output result as JSON")
  var json: Bool = false
  
  @Argument(help: "Inline content (if not using --stdin, --file, or --template)")
  var content: [String] = []
  
  mutating func run() throws {
    let contentString = try determineContent()
    try writeFile(content: contentString)
  }
  
  func determineContent() throws -> String {
    if stdin {
      return try readStdin()
    } else if let file = file {
      return try String(contentsOfFile: file, encoding: .utf8)
    } else if let template = template {
      return try renderTemplate(name: template)
    } else if !content.isEmpty {
      return content.joined(separator: " ")
    } else {
      throw ValidationError("No content source specified")
    }
  }
  
  func readStdin() throws -> String {
    var result = ""
    while let line = readLine(strippingNewline: false) {
      result += line
    }
    return result
  }
  
  func renderTemplate(name: String) throws -> String {
    let templates: [String: String] = [
      "plan": planTemplate(),
      "roadmap": roadmapTemplate()
    ]
    
    guard var template = templates[name] else {
      throw ValidationError("Unknown template: \(name). Available: \(templates.keys.joined(separator: ", "))")
    }
    
    // Parse variables
    var vars = defaultVars()
    for v in self.var {
      let parts = v.split(separator: "=", maxSplits: 1)
      if parts.count == 2 {
        vars[String(parts[0])] = String(parts[1])
      }
    }
    
    // Replace variables
    for (key, value) in vars {
      template = template.replacingOccurrences(of: "%{\(key)}", with: value)
    }
    
    return template
  }
  
  func defaultVars() -> [String: String] {
    let filename = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    let title = filename
      .replacingOccurrences(of: "-", with: " ")
      .replacingOccurrences(of: "_", with: " ")
      .capitalized
    
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    
    return [
      "title": title,
      "date": formatter.string(from: Date()),
      "phase": "1C"
    ]
  }
  
  func writeFile(content: String) throws {
    if dryRun {
      if json {
        let result: [String: Any] = ["path": path, "content": content, "dry_run": true]
        print(try JSONSerialization.data(withJSONObject: result, options: .prettyPrinted).string)
      } else {
        print("=== DRY RUN: Would write to \(path) ===\n")
        print(content)
      }
      return
    }
    
    let url = URL(fileURLWithPath: path)
    let fm = FileManager.default
    
    // Create directory
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    
    // Backup existing
    if !noBackup && fm.fileExists(atPath: path) {
      try fm.copyItem(atPath: path, toPath: path + ".bak")
    }
    
    // Write file
    try content.write(toFile: path, atomically: true, encoding: .utf8)
    
    // Report
    if json {
      let result: [String: Any] = [
        "success": true,
        "path": path,
        "bytes": content.utf8.count,
        "lines": content.components(separatedBy: "\n").count
      ]
      if let data = try? JSONSerialization.data(withJSONObject: result, options: .prettyPrinted),
         let str = String(data: data, encoding: .utf8) {
        print(str)
      }
    } else if !quiet {
      print("✓ Wrote \(content.utf8.count) bytes to \(path)")
    }
  }
  
  // MARK: - Templates
  
  func planTemplate() -> String {
    """
    ---
    title: %{title}
    status: draft
    phase: %{phase}
    tags:
      - peel
    updated: %{date}
    audience:
      - ai-agent
      - developer
    github_issues: []
    code_locations: []
    related_docs: []
    ---

    # %{title}

    ## Goal

    [Describe what this plan achieves]

    ## Implementation

    ### Completed

    | Feature | Details |
    |---------|---------|

    ### In Progress

    | Feature | Issue | Gap |
    |---------|-------|-----|

    ### Planned

    | Feature | Description |
    |---------|-------------|

    ## Code Locations

    [Where the implementation lives]

    ## Testing

    [How to verify the implementation]
    """
  }
  
  func roadmapTemplate() -> String {
    """
    ---
    title: %{title}
    status: active
    tags:
      - roadmap
      - peel
    updated: %{date}
    audience:
      - ai-agent
      - developer
    ---

    # %{title}

    ## Current State Summary

    ### ✅ Complete

    | Area | Details |
    |------|---------|

    ### 🟡 In Progress

    | Area | Open Issue | Gap |
    |------|------------|-----|

    ### 📋 Future

    | Feature | Phase | Notes |
    |---------|-------|-------|

    ---

    ## Active Work

    [Details on current phase items with issue links]

    ---

    ## References

    - [Related Plan](RELATED_PLAN.md)
    """
  }
}

extension Data {
  var string: String {
    String(data: self, encoding: .utf8) ?? ""
  }
}

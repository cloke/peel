//
//  ShellAdapter.swift
//  KitchenSync
//
//  Adapts bash commands to zsh syntax for AI agents.
//  Inspired by RichSwift's AI Terminal integration.
//

import Foundation

/// Transforms bash commands to be compatible with zsh.
///
/// AI agents often generate bash-flavored commands that fail in zsh environments.
/// This adapter automatically converts common bash patterns to their zsh equivalents.
public struct ShellAdapter: Sendable {
  
  // MARK: - Types
  
  /// Types of transformations applied to a command
  public enum TransformationType: String, Codable, CaseIterable, Sendable {
    case echoEscape       // echo -e "text\n" → echo "text\n"
    case commandSubstitution  // `date` → $(date)
    case readCommand      // read -p "Name:" var → read "var?Name:"
    case arrayExpansion   // ${arr[*]} → ${(j: :)arr}
    case heredoc          // $(cat <<EOF...EOF) → "escaped string"
    case declare          // declare -a → typeset -a
    case sourceCommand    // source file → . file (already valid, but normalize)
    case functionExport   // export -f func → Not supported in zsh (warn)
  }
  
  /// Result of adapting a command
  public struct AdaptationResult: Codable, Sendable {
    public let originalCommand: String
    public let adaptedCommand: String
    public let wasAdapted: Bool
    public let transformations: [TransformationType]
    public let warnings: [String]
    
    public init(
      originalCommand: String,
      adaptedCommand: String,
      wasAdapted: Bool,
      transformations: [TransformationType],
      warnings: [String] = []
    ) {
      self.originalCommand = originalCommand
      self.adaptedCommand = adaptedCommand
      self.wasAdapted = wasAdapted
      self.transformations = transformations
      self.warnings = warnings
    }
  }
  
  // MARK: - Public API
  
  public init() {}
  
  /// Adapt a bash command to zsh syntax
  public func adapt(_ command: String) -> AdaptationResult {
    var result = command
    var transformations: [TransformationType] = []
    var warnings: [String] = []
    
    // Apply transformations in order of priority
    // Heredocs first (most complex)
    let (heredocResult, hadHeredoc) = adaptHeredocs(result)
    if hadHeredoc {
      result = heredocResult
      transformations.append(.heredoc)
    }
    
    // Command substitution (backticks to $())
    let (subResult, hadSub) = adaptCommandSubstitution(result)
    if hadSub {
      result = subResult
      transformations.append(.commandSubstitution)
    }
    
    // Echo -e flag
    let (echoResult, hadEcho) = adaptEchoEscape(result)
    if hadEcho {
      result = echoResult
      transformations.append(.echoEscape)
    }
    
    // Read -p prompt
    let (readResult, hadRead) = adaptReadCommand(result)
    if hadRead {
      result = readResult
      transformations.append(.readCommand)
    }
    
    // Array expansion
    let (arrayResult, hadArray) = adaptArrayExpansion(result)
    if hadArray {
      result = arrayResult
      transformations.append(.arrayExpansion)
    }
    
    // Declare → typeset
    let (declareResult, hadDeclare) = adaptDeclare(result)
    if hadDeclare {
      result = declareResult
      transformations.append(.declare)
    }
    
    // Check for unsupported patterns
    if result.contains("export -f") {
      warnings.append("export -f (function export) is not supported in zsh")
      transformations.append(.functionExport)
    }
    
    return AdaptationResult(
      originalCommand: command,
      adaptedCommand: result,
      wasAdapted: result != command,
      transformations: transformations,
      warnings: warnings
    )
  }
  
  // MARK: - Transformations
  
  /// Convert `echo -e "text"` to `echo "text"` (zsh interprets escapes by default)
  private func adaptEchoEscape(_ command: String) -> (String, Bool) {
    // Match: echo -e "..." or echo -e '...' or echo -e $'...'
    let pattern = #"echo\s+-e\s+"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
      return (command, false)
    }
    
    let range = NSRange(command.startIndex..., in: command)
    if regex.firstMatch(in: command, range: range) != nil {
      // Remove -e flag
      let result = command.replacingOccurrences(
        of: #"echo\s+-e\s+"#,
        with: "echo ",
        options: .regularExpression
      )
      return (result, true)
    }
    return (command, false)
  }
  
  /// Convert backticks to $() command substitution
  private func adaptCommandSubstitution(_ command: String) -> (String, Bool) {
    var result = command
    var wasModified = false
    
    // Find backtick pairs (not inside single quotes)
    // This is a simplified implementation - a full parser would handle nesting
    var i = result.startIndex
    while i < result.endIndex {
      if result[i] == "`" {
        // Find matching closing backtick
        let start = i
        i = result.index(after: i)
        while i < result.endIndex && result[i] != "`" {
          i = result.index(after: i)
        }
        if i < result.endIndex {
          // Found matching backtick
          let end = i
          let inner = String(result[result.index(after: start)..<end])
          let replacement = "$(\(inner))"
          result = result.replacingCharacters(in: start...end, with: replacement)
          wasModified = true
          // Adjust index for the replacement
          i = result.index(start, offsetBy: replacement.count)
          continue
        }
      }
      if i < result.endIndex {
        i = result.index(after: i)
      }
    }
    
    return (result, wasModified)
  }
  
  /// Convert `read -p "prompt" var` to `read "var?prompt"`
  private func adaptReadCommand(_ command: String) -> (String, Bool) {
    // Match: read -p "prompt" variable or read -p 'prompt' variable
    let patterns = [
      #"read\s+-p\s+"([^"]+)"\s+(\w+)"#,  // double quotes
      #"read\s+-p\s+'([^']+)'\s+(\w+)"#   // single quotes
    ]
    
    for pattern in patterns {
      guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
        continue
      }
      
      let range = NSRange(command.startIndex..., in: command)
      if let match = regex.firstMatch(in: command, range: range) {
        // Extract prompt and variable
        guard let promptRange = Range(match.range(at: 1), in: command),
              let varRange = Range(match.range(at: 2), in: command) else {
          continue
        }
        
        let prompt = String(command[promptRange])
        let variable = String(command[varRange])
        
        // Zsh format: read "var?prompt"
        let zshRead = "read \"\(variable)?\(prompt)\""
        
        let fullRange = Range(match.range(at: 0), in: command)!
        let result = command.replacingCharacters(in: fullRange, with: zshRead)
        return (result, true)
      }
    }
    
    return (command, false)
  }
  
  /// Convert bash array expansion to zsh
  private func adaptArrayExpansion(_ command: String) -> (String, Bool) {
    // ${arr[*]} → ${(j: :)arr}  (join with spaces)
    // ${arr[@]} is generally compatible
    let pattern = #"\$\{(\w+)\[\*\]\}"#
    
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
      return (command, false)
    }
    
    var result = command
    var wasModified = false
    
    let range = NSRange(result.startIndex..., in: result)
    let matches = regex.matches(in: result, range: range)
    
    // Process in reverse to maintain index validity
    for match in matches.reversed() {
      guard let varRange = Range(match.range(at: 1), in: result),
            let fullRange = Range(match.range(at: 0), in: result) else {
        continue
      }
      
      let varName = String(result[varRange])
      let replacement = "${(j: :)\(varName)}"
      result.replaceSubrange(fullRange, with: replacement)
      wasModified = true
    }
    
    return (result, wasModified)
  }
  
  /// Convert heredocs to escaped strings
  /// This is the most complex transformation - heredocs inside $() are problematic
  private func adaptHeredocs(_ command: String) -> (String, Bool) {
    // Match: $(cat <<EOF ... EOF) or $(cat <<'EOF' ... EOF)
    // This is a simplified pattern - real heredocs are complex
    let heredocPattern = #"\$\(cat\s+<<-?'?(\w+)'?\s+([\s\S]*?)\n\1\)"#
    
    guard let regex = try? NSRegularExpression(pattern: heredocPattern, options: [.dotMatchesLineSeparators]) else {
      return (command, false)
    }
    
    var result = command
    var wasModified = false
    
    let range = NSRange(result.startIndex..., in: result)
    let matches = regex.matches(in: result, range: range)
    
    // Process in reverse to maintain index validity
    for match in matches.reversed() {
      guard let contentRange = Range(match.range(at: 2), in: result),
            let fullRange = Range(match.range(at: 0), in: result) else {
        continue
      }
      
      let content = String(result[contentRange])
      let escaped = escapeForQuotedString(content)
      let replacement = "\"\(escaped)\""
      result.replaceSubrange(fullRange, with: replacement)
      wasModified = true
    }
    
    return (result, wasModified)
  }
  
  /// Convert declare to typeset (zsh equivalent)
  private func adaptDeclare(_ command: String) -> (String, Bool) {
    // declare -a → typeset -a
    // declare -A → typeset -A
    // declare -i → typeset -i
    let pattern = #"\bdeclare\s+-"#
    
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
      return (command, false)
    }
    
    let range = NSRange(command.startIndex..., in: command)
    if regex.firstMatch(in: command, range: range) != nil {
      let result = command.replacingOccurrences(of: "declare ", with: "typeset ")
      return (result, true)
    }
    
    return (command, false)
  }
  
  // MARK: - Helpers
  
  /// Escape content for use in a double-quoted string
  private func escapeForQuotedString(_ content: String) -> String {
    var result = content
    // Escape backslashes first
    result = result.replacingOccurrences(of: "\\", with: "\\\\")
    // Escape double quotes
    result = result.replacingOccurrences(of: "\"", with: "\\\"")
    // Escape dollar signs (to prevent variable expansion)
    result = result.replacingOccurrences(of: "$", with: "\\$")
    // Escape backticks
    result = result.replacingOccurrences(of: "`", with: "\\`")
    // Convert newlines to \n (zsh interprets in double quotes)
    result = result.replacingOccurrences(of: "\n", with: "\\n")
    return result
  }
}

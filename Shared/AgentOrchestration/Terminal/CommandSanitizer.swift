//
//  CommandSanitizer.swift
//  KitchenSync
//
//  Analyzes shell commands for safety before execution.
//  Inspired by RichSwift's AI Terminal integration.
//

import Foundation

/// Analyzes shell commands for safety and potential risks.
///
/// AI agents may generate dangerous commands. This sanitizer classifies commands
/// by risk level and can block critical operations.
public struct CommandSanitizer: Sendable {
  
  // MARK: - Types
  
  /// Risk level for a command
  public enum RiskLevel: String, Codable, Comparable, Sendable {
    case safe     // No risk: ls, pwd, echo, cat (read-only)
    case low      // Minimal risk: curl, wget (network, but no local changes)
    case medium   // Moderate risk: sudo, rm file, chmod
    case high     // High risk: rm -rf dir, dd, mkfs
    case critical // Must block: rm -rf /, fork bombs, curl | sh
    
    public static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool {
      let order: [RiskLevel] = [.safe, .low, .medium, .high, .critical]
      return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }
  }
  
  /// Type of risk detected
  public enum RiskType: String, Codable, CaseIterable, Sendable {
    case destructiveDelete      // rm -rf, shred
    case systemModification     // dd, mkfs, fdisk
    case privilegeEscalation    // sudo, su, doas
    case networkExecution       // curl | sh, wget | bash
    case forkBomb               // :(){ :|:& };:
    case historyManipulation    // history -c, unset HISTFILE
    case credentialExposure     // printenv with secrets, cat ~/.ssh/
    case systemShutdown         // shutdown, reboot, halt
    case kernelModification     // insmod, modprobe, sysctl
    case firewallModification   // iptables, ufw, pfctl
    case networkRequest         // curl, wget, nc (informational)
    case fileModification       // rm, mv, chmod, chown
    case processManagement      // kill, pkill, killall
    case packageManagement      // brew, apt, npm install -g
  }
  
  /// Result of analyzing a command
  public struct AnalysisResult: Codable, Sendable {
    public let command: String
    public let riskLevel: RiskLevel
    public let risks: [DetectedRisk]
    public let shouldBlock: Bool
    public let warnings: [String]
    public let suggestions: [String]
    
    public init(
      command: String,
      riskLevel: RiskLevel,
      risks: [DetectedRisk],
      shouldBlock: Bool,
      warnings: [String],
      suggestions: [String]
    ) {
      self.command = command
      self.riskLevel = riskLevel
      self.risks = risks
      self.shouldBlock = shouldBlock
      self.warnings = warnings
      self.suggestions = suggestions
    }
  }
  
  /// A specific risk detected in a command
  public struct DetectedRisk: Codable, Sendable {
    public let type: RiskType
    public let level: RiskLevel
    public let description: String
    public let matchedPattern: String
    
    public init(type: RiskType, level: RiskLevel, description: String, matchedPattern: String) {
      self.type = type
      self.level = level
      self.description = description
      self.matchedPattern = matchedPattern
    }
  }
  
  // MARK: - Risk Patterns
  
  /// Pattern definition for risk detection
  private struct RiskPattern {
    let pattern: String
    let type: RiskType
    let level: RiskLevel
    let description: String
    let shouldBlock: Bool
  }
  
  /// All risk patterns, ordered by severity
  private let patterns: [RiskPattern] = [
    // CRITICAL - Must block
    RiskPattern(
      pattern: #"rm\s+(-[a-zA-Z]*r[a-zA-Z]*f|--recursive\s+--force|-[a-zA-Z]*f[a-zA-Z]*r)\s+/"#,
      type: .destructiveDelete,
      level: .critical,
      description: "Recursive force delete from root - will destroy system",
      shouldBlock: true
    ),
    RiskPattern(
      pattern: #"rm\s+(-[a-zA-Z]*r[a-zA-Z]*f|--recursive\s+--force)\s+/\*"#,
      type: .destructiveDelete,
      level: .critical,
      description: "Recursive force delete of root contents",
      shouldBlock: true
    ),
    RiskPattern(
      pattern: #":\(\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;\s*:"#,
      type: .forkBomb,
      level: .critical,
      description: "Fork bomb - will crash system",
      shouldBlock: true
    ),
    RiskPattern(
      pattern: #"curl\s+[^\|]+\|\s*(ba)?sh"#,
      type: .networkExecution,
      level: .critical,
      description: "Piping remote content to shell - extreme security risk",
      shouldBlock: true
    ),
    RiskPattern(
      pattern: #"wget\s+[^\|]+\|\s*(ba)?sh"#,
      type: .networkExecution,
      level: .critical,
      description: "Piping remote content to shell - extreme security risk",
      shouldBlock: true
    ),
    RiskPattern(
      pattern: #"dd\s+.*of=/dev/(sd[a-z]|nvme|disk|hd[a-z])"#,
      type: .systemModification,
      level: .critical,
      description: "Direct disk write - can destroy data",
      shouldBlock: true
    ),
    RiskPattern(
      pattern: #"mkfs\."#,
      type: .systemModification,
      level: .critical,
      description: "Filesystem creation - will erase disk",
      shouldBlock: true
    ),
    RiskPattern(
      pattern: #">\s*/dev/(sd[a-z]|nvme|disk)"#,
      type: .systemModification,
      level: .critical,
      description: "Direct write to disk device",
      shouldBlock: true
    ),
    
    // HIGH - Allow but warn strongly
    RiskPattern(
      pattern: #"rm\s+(-[a-zA-Z]*r[a-zA-Z]*f|--recursive\s+--force)\s+\S"#,
      type: .destructiveDelete,
      level: .high,
      description: "Recursive force delete - verify path carefully",
      shouldBlock: false
    ),
    RiskPattern(
      pattern: #"rm\s+-rf\s+\~"#,
      type: .destructiveDelete,
      level: .high,
      description: "Deleting from home directory recursively",
      shouldBlock: false
    ),
    RiskPattern(
      pattern: #"shred\s+"#,
      type: .destructiveDelete,
      level: .high,
      description: "Secure deletion - unrecoverable",
      shouldBlock: false
    ),
    RiskPattern(
      pattern: #"shutdown|reboot|halt|poweroff"#,
      type: .systemShutdown,
      level: .high,
      description: "System power control",
      shouldBlock: false
    ),
    RiskPattern(
      pattern: #"history\s+-c|unset\s+HISTFILE"#,
      type: .historyManipulation,
      level: .high,
      description: "Clearing command history - suspicious",
      shouldBlock: false
    ),
    
    // MEDIUM - Standard warnings
    RiskPattern(
      pattern: #"\bsudo\b"#,
      type: .privilegeEscalation,
      level: .medium,
      description: "Elevated privileges requested",
      shouldBlock: false
    ),
    RiskPattern(
      pattern: #"\bsu\s"#,
      type: .privilegeEscalation,
      level: .medium,
      description: "User switch requested",
      shouldBlock: false
    ),
    RiskPattern(
      pattern: #"\brm\s+(?!-[rf])"#,
      type: .fileModification,
      level: .medium,
      description: "File deletion",
      shouldBlock: false
    ),
    RiskPattern(
      pattern: #"chmod\s+[0-7]{3,4}\s"#,
      type: .fileModification,
      level: .medium,
      description: "Permission change",
      shouldBlock: false
    ),
    RiskPattern(
      pattern: #"chown\s"#,
      type: .fileModification,
      level: .medium,
      description: "Ownership change",
      shouldBlock: false
    ),
    RiskPattern(
      pattern: #"kill\s+-9|killall|pkill"#,
      type: .processManagement,
      level: .medium,
      description: "Process termination",
      shouldBlock: false
    ),
    RiskPattern(
      pattern: #"brew\s+install|apt(-get)?\s+install|npm\s+install\s+-g"#,
      type: .packageManagement,
      level: .medium,
      description: "Package installation",
      shouldBlock: false
    ),
    RiskPattern(
      pattern: #"iptables|ufw|pfctl"#,
      type: .firewallModification,
      level: .medium,
      description: "Firewall modification",
      shouldBlock: false
    ),
    
    // LOW - Informational
    RiskPattern(
      pattern: #"\bcurl\b"#,
      type: .networkRequest,
      level: .low,
      description: "Network request",
      shouldBlock: false
    ),
    RiskPattern(
      pattern: #"\bwget\b"#,
      type: .networkRequest,
      level: .low,
      description: "Network download",
      shouldBlock: false
    ),
    RiskPattern(
      pattern: #"\bnc\b|\bnetcat\b"#,
      type: .networkRequest,
      level: .low,
      description: "Network connection",
      shouldBlock: false
    ),
    RiskPattern(
      pattern: #"cat\s+.*\.(pem|key|crt)|cat\s+.*\.ssh/"#,
      type: .credentialExposure,
      level: .low,
      description: "Reading potential credentials",
      shouldBlock: false
    ),
  ]
  
  /// Safe commands that never trigger warnings
  private let safeCommands: Set<String> = [
    "ls", "pwd", "echo", "cat", "head", "tail", "grep", "find", "which",
    "whoami", "date", "cal", "wc", "sort", "uniq", "diff", "less", "more",
    "man", "help", "cd", "pushd", "popd", "dirs", "env", "printenv",
    "git status", "git log", "git diff", "git branch", "git remote",
    "npm list", "yarn list", "pip list", "brew list",
    "xcodebuild -showBuildSettings", "swift --version", "python --version"
  ]
  
  // MARK: - Public API
  
  public init() {}
  
  /// Analyze a command for safety
  public func analyze(_ command: String) -> AnalysisResult {
    let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
    
    // Check if command starts with a known safe command
    let baseCommand = extractBaseCommand(trimmed)
    if safeCommands.contains(baseCommand) || safeCommands.contains(where: { trimmed.hasPrefix($0) }) {
      return AnalysisResult(
        command: command,
        riskLevel: .safe,
        risks: [],
        shouldBlock: false,
        warnings: [],
        suggestions: []
      )
    }
    
    // Check all patterns
    var detectedRisks: [DetectedRisk] = []
    var shouldBlock = false
    var warnings: [String] = []
    var suggestions: [String] = []
    
    for riskPattern in patterns {
      guard let regex = try? NSRegularExpression(pattern: riskPattern.pattern, options: [.caseInsensitive]) else {
        continue
      }
      
      let range = NSRange(trimmed.startIndex..., in: trimmed)
      if let match = regex.firstMatch(in: trimmed, range: range) {
        let matchedRange = Range(match.range, in: trimmed)!
        let matchedText = String(trimmed[matchedRange])
        
        let risk = DetectedRisk(
          type: riskPattern.type,
          level: riskPattern.level,
          description: riskPattern.description,
          matchedPattern: matchedText
        )
        detectedRisks.append(risk)
        
        if riskPattern.shouldBlock {
          shouldBlock = true
        }
        
        warnings.append(riskPattern.description)
        
        // Add suggestions based on risk type
        if let suggestion = suggestionFor(riskPattern.type) {
          suggestions.append(suggestion)
        }
      }
    }
    
    // Determine overall risk level
    let riskLevel = detectedRisks.map(\.level).max() ?? .safe
    
    return AnalysisResult(
      command: command,
      riskLevel: riskLevel,
      risks: detectedRisks,
      shouldBlock: shouldBlock,
      warnings: Array(Set(warnings)), // Deduplicate
      suggestions: Array(Set(suggestions))
    )
  }
  
  /// Quick check if a command should be blocked
  public func shouldBlock(_ command: String) -> Bool {
    analyze(command).shouldBlock
  }
  
  // MARK: - Helpers
  
  /// Extract the base command (first word)
  private func extractBaseCommand(_ command: String) -> String {
    let words = command.split(separator: " ", maxSplits: 1)
    return words.first.map(String.init) ?? ""
  }
  
  /// Get suggestion for a risk type
  private func suggestionFor(_ type: RiskType) -> String? {
    switch type {
    case .destructiveDelete:
      return "Consider using -i flag for interactive deletion"
    case .networkExecution:
      return "Download the script first, review it, then execute"
    case .privilegeEscalation:
      return "Verify this command really needs elevated privileges"
    case .systemModification:
      return "Double-check the target device/path before proceeding"
    case .credentialExposure:
      return "Be careful not to expose credentials in logs"
    case .packageManagement:
      return "Review package dependencies before installing"
    default:
      return nil
    }
  }
}

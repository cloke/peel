import Foundation

/// ANSI terminal formatting utilities
enum Terminal {
  // MARK: - Colors

  static let reset = "\u{001B}[0m"
  static let bold = "\u{001B}[1m"
  static let dim = "\u{001B}[2m"
  static let italic = "\u{001B}[3m"
  static let underline = "\u{001B}[4m"

  // Foreground colors
  static let red = "\u{001B}[31m"
  static let green = "\u{001B}[32m"
  static let yellow = "\u{001B}[33m"
  static let blue = "\u{001B}[34m"
  static let magenta = "\u{001B}[35m"
  static let cyan = "\u{001B}[36m"
  static let white = "\u{001B}[37m"
  static let gray = "\u{001B}[90m"

  // Background colors
  static let bgBlue = "\u{001B}[44m"
  static let bgGray = "\u{001B}[100m"

  // MARK: - Output helpers

  static func printBanner() {
    print("""
    \(bold)\(cyan)
     ____            _
    |  _ \\ ___  ___| |
    | |_) / _ \\/ _ \\ |
    |  __/  __/  __/ |
    |_|   \\___|\\___|_|
    \(reset)
    \(dim)Interactive AI coding agent v0.1.0\(reset)
    """)
  }

  static func info(_ message: String) {
    print("\(dim)\(message)\(reset)")
  }

  static func error(_ message: String) {
    fputs("\(red)\(bold)Error:\(reset) \(message)\n", stderr)
  }

  static func warning(_ message: String) {
    print("\(yellow)\(bold)Warning:\(reset) \(message)")
  }

  static func success(_ message: String) {
    print("\(green)\(bold)✓\(reset) \(message)")
  }

  static func toolCall(_ name: String, _ args: String? = nil) {
    print("\(dim)─── \(cyan)\(bold)\(name)\(reset)\(dim) ───\(reset)")
    if let args {
      print("\(gray)\(args)\(reset)")
    }
  }

  static func toolResult(_ result: String, truncateAt: Int = 2000) {
    let display = result.count > truncateAt
      ? String(result.prefix(truncateAt)) + "\n\(dim)... (\(result.count - truncateAt) chars truncated)\(reset)"
      : result
    print(display)
    print("\(dim)───────────────────\(reset)")
  }

  static func prompt() -> String? {
    print("\n\(bold)\(blue)>\(reset) ", terminator: "")
    fflush(stdout)
    return readLine()
  }

  static func streamText(_ text: String) {
    print(text, terminator: "")
    fflush(stdout)
  }

  static func confirm(_ message: String) -> Bool {
    print("\(yellow)\(bold)?\(reset) \(message) \(dim)[y/N]\(reset) ", terminator: "")
    fflush(stdout)
    guard let response = readLine()?.lowercased() else { return false }
    return response == "y" || response == "yes"
  }

  /// Format a code block with syntax highlighting hint
  static func codeBlock(_ code: String, language: String? = nil) {
    let lang = language.map { " \(dim)(\($0))\(reset)" } ?? ""
    print("\(bgGray)\(white) Code\(lang) \(reset)")
    for line in code.split(separator: "\n", omittingEmptySubsequences: false) {
      print("  \(gray)│\(reset) \(line)")
    }
    print()
  }

  /// Spinner for long operations
  static func withSpinner<T>(_ message: String, _ operation: () async throws -> T) async rethrows -> T {
    let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    let spinnerTask = Task { @Sendable () -> Void in
      var i = 0
      while !Task.isCancelled {
        print("\r\(cyan)\(frames[i % frames.count])\(reset) \(dim)\(message)\(reset)", terminator: "")
        fflush(stdout)
        i += 1
        try? await Task.sleep(for: .milliseconds(80))
      }
    }
    defer {
      spinnerTask.cancel()
      print("\r\u{001B}[2K", terminator: "") // Clear line
      fflush(stdout)
    }
    return try await operation()
  }
}

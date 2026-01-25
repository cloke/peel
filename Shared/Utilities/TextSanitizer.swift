import Foundation

/// Shared text sanitization utilities to prevent NLEmbedding crashes and PII leakage.
///
/// Extracted from duplicated logic in:
/// - Shared/Services/LocalRAGEmbeddings.swift lines ~66-89 (sanitizeText for CoreNLP safety)
/// - Shared/Services/TranslationValidatorService.swift lines ~502-518 (sanitizeForPrompt for PII redaction)
enum TextSanitizer {
  
  /// Maximum text length to prevent CoreNLP crashes (matches LocalRAGEmbeddings behavior)
  private static let maxTextLength = 10_000
  
  /// Sanitizes text to prevent NLEmbedding/CoreNLP crashes from malformed input.
  ///
  /// Behavior (preserves exact logic from LocalRAGEmbeddings.swift):
  /// - Truncates to maxTextLength (10,000 chars)
  /// - Removes null bytes and control characters that crash CoreNLP
  /// - Keeps printable ASCII, extended Unicode, newlines, tabs, whitespace
  /// - Collapses excessive whitespace
  /// - Trims leading/trailing whitespace
  ///
  /// - Parameter text: Input text to sanitize
  /// - Returns: Sanitized text safe for NLEmbedding, or empty string if input is empty/whitespace-only
  static func sanitize(_ text: String) -> String {
    // Truncate overly long text
    var result = text.count > maxTextLength ? String(text.prefix(maxTextLength)) : text
    
    // Remove null bytes and other control characters that crash CoreNLP
    result = result.unicodeScalars
      .filter { scalar in
        // Keep printable characters, newlines, tabs, and standard whitespace
        scalar == "\n" || scalar == "\r" || scalar == "\t" ||
          scalar.properties.isWhitespace ||
          (scalar.value >= 0x20 && scalar.value < 0x7F) ||  // ASCII printable
          (scalar.value >= 0xA0 && !scalar.properties.isNoncharacterCodePoint)  // Extended printable
      }
      .map { Character($0) }
      .reduce(into: "") { $0.append($1) }
    
    // Collapse excessive whitespace
    result =
      result
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    
    return result
  }
  
  /// Sanitizes text by redacting PII (emails, SSNs, phone numbers, long numbers).
  ///
  /// Behavior (preserves exact logic from TranslationValidatorService.swift):
  /// - Replaces emails with "<email>"
  /// - Replaces SSNs with "<ssn>"
  /// - Replaces phone numbers with "<phone>"
  /// - Replaces 4+ digit numbers with "<number>"
  /// - Returns input unchanged if empty
  ///
  /// - Parameter text: Input text to redact
  /// - Returns: Text with PII redacted, or empty string if input is empty
  static func sanitizeForPrompt(_ text: String) -> String {
    if text.isEmpty { return text }
    var sanitized = text
    let patterns: [String] = [
      "[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}",
      "\\b\\d{3}[- .]?\\d{2}[- .]?\\d{4}\\b",
      "\\+?\\d[\\d\n\t().-]{7,}",
      "\\b\\d{4,}\\b"
    ]
    let replacements = ["<email>", "<ssn>", "<phone>", "<number>"]
    for (pattern, replacement) in zip(patterns, replacements) {
      if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
        let range = NSRange(sanitized.startIndex..., in: sanitized)
        sanitized = regex.stringByReplacingMatches(in: sanitized, range: range, withTemplate: replacement)
      }
    }
    return sanitized
  }
}

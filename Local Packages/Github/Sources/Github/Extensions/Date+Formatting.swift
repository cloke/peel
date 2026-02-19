import Foundation

extension Date {
    var relativeFormatted: String {
        DateFormatter.relativeGithub.string(from: self)
    }
}

extension String {
    var dateFromGithubFormat: Date? {
        DateFormatter.githubDate.date(from: self)
    }
}

// MARK: - ISO 8601 Parsing

/// Shared ISO 8601 date parser — handles both fractional-seconds and standard formats.
/// Use instead of creating one-off ISO8601DateFormatter instances in each view.
enum GithubDateParser {
  private static let fractionalFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()

  private static let fallbackFormatter = ISO8601DateFormatter()

  /// Parse an ISO 8601 date string, trying fractional seconds first.
  static func parse(_ value: String) -> Date? {
    fractionalFormatter.date(from: value) ?? fallbackFormatter.date(from: value)
  }

  /// Convenience for optional strings (returns nil if input is nil).
  static func parse(_ value: String?) -> Date? {
    guard let value else { return nil }
    return parse(value)
  }
}

// MARK: - Chart Helpers

/// Generate an array of week-start dates for the last N weeks, useful for chart X-axes.
func chartWeekStarts(calendar: Calendar = .current, weeks: Int = 12) -> [Date] {
  let now = Date()
  let currentWeekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now
  let start = calendar.date(byAdding: .weekOfYear, value: -(weeks - 1), to: currentWeekStart) ?? currentWeekStart
  return (0..<weeks).compactMap { calendar.date(byAdding: .weekOfYear, value: $0, to: start) }
}

private extension DateFormatter {
    static let relativeGithub: DateFormatter = {
        let formatter = DateFormatter()
        formatter.doesRelativeDateFormatting = true
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return formatter
    }()

    static let githubDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return formatter
    }()
}

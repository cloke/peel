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

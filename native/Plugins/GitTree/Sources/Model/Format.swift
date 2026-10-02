import Foundation

/// A hash as it reads in conversation: the first seven characters, everywhere
/// this plugin abbreviates one.
func shortHash(_ hash: String) -> String {
    String(hash.prefix(7))
}

/// Author dates as `2026-08-05 14:32` in local time: sortable at a glance, and
/// no relative time to keep ticking. Anything that isn't a date (the
/// working-tree row's empty one) passes through as is.
func formatDate(_ iso: String, timeZone: TimeZone = .current) -> String {
    guard let date = parseISODate(iso) else { return iso }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    func pad(_ value: Int?) -> String {
        let value = value ?? 0
        return value < 10 ? "0\(value)" : "\(value)"
    }
    return "\(parts.year ?? 0)-\(pad(parts.month))-\(pad(parts.day)) \(pad(parts.hour)):\(pad(parts.minute))"
}

/// `%aI` (strict ISO 8601 with an offset or Z), with or without fractional
/// seconds.
private func parseISODate(_ text: String) -> Date? {
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    if let date = plain.date(from: text) { return date }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: text)
}

/// The trailing path segment, which is what a repository is called in
/// conversation.
func baseName(_ path: String) -> String {
    path.split(separator: "/").last.map(String.init) ?? path
}

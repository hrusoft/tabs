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

/// A rename as git prints one in `--numstat` and `--stat` (its
/// `pprint_rename`): the parts both paths share kept outside braces, a
/// shared prefix up to a `/` and a shared suffix from one, so
/// `src/old/a.txt` → `src/new/a.txt` reads `src/{old => new}/a.txt`; with
/// nothing shared, `a => b`.
func renameLabel(_ old: String, _ new: String) -> String {
    let a = Array(old.utf8)
    let b = Array(new.utf8)
    let slash = UInt8(ascii: "/")
    var prefix = 0
    var index = 0
    while index < a.count, index < b.count, a[index] == b[index] {
        if a[index] == slash { prefix = index + 1 }
        index += 1
    }
    // From the ends (each string's terminator counts, as in git's C), back
    // at most into the prefix's own slash.
    func byte(_ bytes: [UInt8], _ at: Int) -> UInt8 { at < bytes.count ? bytes[at] : 0 }
    let floor = prefix - (prefix > 0 ? 1 : 0)
    var suffix = 0
    var endA = a.count
    var endB = b.count
    while floor <= endA, floor <= endB, byte(a, endA) == byte(b, endB) {
        if byte(a, endA) == slash { suffix = a.count - endA }
        endA -= 1
        endB -= 1
    }
    let middleA = max(a.count - prefix - suffix, 0)
    let middleB = max(b.count - prefix - suffix, 0)
    func text(_ bytes: ArraySlice<UInt8>) -> String { String(decoding: bytes, as: UTF8.self) }
    let middle = text(a[prefix..<prefix + middleA]) + " => " + text(b[prefix..<prefix + middleB])
    guard prefix + suffix > 0 else { return middle }
    return text(a[..<prefix]) + "{" + middle + "}" + text(a[(a.count - suffix)...])
}

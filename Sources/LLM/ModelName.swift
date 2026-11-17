import Foundation

/// How a Claude model id reads in the status line: "claude-haiku-4-5" becomes
/// "Haiku 4.5", the same short name Settings uses. An id that does not follow
/// that pattern (a custom or very old one) is shown exactly as it is, so the
/// status never hides which model is really in use.
enum ModelName {
    static func short(_ id: String) -> String {
        let prefix = "claude-"
        guard id.hasPrefix(prefix) else { return id }
        var parts = alias(id).dropFirst(prefix.count).split(separator: "-").map(String.init)
        guard let family = parts.first, !family.isEmpty, family.allSatisfy(\.isLetter) else { return id }
        let version = parts.dropFirst()
        guard !version.isEmpty, version.allSatisfy(isVersionNumber) else { return id }
        return family.capitalized + " " + version.joined(separator: ".")
    }

    /// The id without its trailing `-YYYYMMDD` snapshot date: the Models API lists
    /// older models by dated id ("claude-haiku-4-5-20251001") while people, and
    /// this app's saved settings, use the alias ("claude-haiku-4-5").
    static func alias(_ id: String) -> String {
        guard let dash = id.lastIndex(of: "-"), isSnapshotDate(String(id[id.index(after: dash)...])) else { return id }
        return String(id[..<dash])
    }

    /// Whether two ids name the same model: equal, or equal once the dates are dropped.
    static func sameModel(_ a: String, _ b: String) -> Bool {
        a == b || alias(a) == alias(b)
    }

    /// "Claude Haiku 5.5" as "Haiku 5.5", for the status line.
    static func withoutVendor(_ displayName: String) -> String {
        let prefix = "Claude "
        guard displayName.hasPrefix(prefix), displayName.count > prefix.count else { return displayName }
        return String(displayName.dropFirst(prefix.count))
    }

    private static func isSnapshotDate(_ part: String) -> Bool {
        part.count == 8 && part.allSatisfy(\.isNumber)
    }

    private static func isVersionNumber(_ part: String) -> Bool {
        (1...2).contains(part.count) && part.allSatisfy(\.isNumber)
    }
}

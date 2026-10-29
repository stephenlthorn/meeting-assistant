import Foundation

/// How a Claude model id reads in the status line: "claude-haiku-4-5" becomes
/// "Haiku 4.5", the same short name Settings uses. An id that does not follow
/// that pattern (a custom or very old one) is shown exactly as it is, so the
/// status never hides which model is really in use.
enum ModelName {
    static func short(_ id: String) -> String {
        let prefix = "claude-"
        guard id.hasPrefix(prefix) else { return id }
        var parts = id.dropFirst(prefix.count).split(separator: "-").map(String.init)
        if let last = parts.last, isSnapshotDate(last) { parts.removeLast() }
        guard let family = parts.first, !family.isEmpty, family.allSatisfy(\.isLetter) else { return id }
        let version = parts.dropFirst()
        guard !version.isEmpty, version.allSatisfy(isVersionNumber) else { return id }
        return family.capitalized + " " + version.joined(separator: ".")
    }

    private static func isSnapshotDate(_ part: String) -> Bool {
        part.count == 8 && part.allSatisfy(\.isNumber)
    }

    private static func isVersionNumber(_ part: String) -> Bool {
        (1...2).contains(part.count) && part.allSatisfy(\.isNumber)
    }
}

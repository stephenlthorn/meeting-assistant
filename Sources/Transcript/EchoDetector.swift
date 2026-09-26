import Foundation

/// Spots the microphone picking up the other side through the speakers: the
/// "You" text lines up, word for word, with something "Them" just said.
/// Scored as a local word alignment (match +1, mismatch or gap -1) so small
/// recognition differences still line up but a reply that merely shares
/// common words does not.
enum EchoDetector {
    static let minimumWords = 4
    private static let minimumAlignment = 0.7

    static func isLikelyEcho(_ candidate: String, of reference: String) -> Bool {
        let candidateWords = words(candidate)
        guard candidateWords.count >= minimumWords else { return false }
        let score = bestLocalAlignment(candidateWords, words(reference))
        return Double(score) / Double(candidateWords.count) >= minimumAlignment
    }

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") })
            .map(String.init)
    }

    private static func bestLocalAlignment(_ a: [String], _ b: [String]) -> Int {
        guard !b.isEmpty else { return 0 }
        var best = 0
        var previous = [Int](repeating: 0, count: b.count + 1)
        for word in a {
            var current = [Int](repeating: 0, count: b.count + 1)
            for j in 1...b.count {
                let diagonal = previous[j - 1] + (word == b[j - 1] ? 1 : -1)
                current[j] = max(0, diagonal, previous[j] - 1, current[j - 1] - 1)
                best = max(best, current[j])
            }
            previous = current
        }
        return best
    }
}

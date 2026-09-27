import Foundation

/// One recognizer update: the current text of utterance `utterance`, which
/// keeps changing until `isFinal`. Backends start a new utterance id after
/// each final result.
struct TranscriptSegment: Equatable {
    let utterance: Int
    let text: String
    let isFinal: Bool
}

/// The merged, speaker-labeled conversation. Turns are ordered by when they
/// started, and each (speaker, utterance) updates in place until it is final.
/// Final turns at the front are rendered once into `committed`, so updates and
/// `tail` cost the same at minute one and minute ninety.
struct Transcript {
    struct Turn: Equatable {
        let speaker: Speaker
        let utterance: Int
        var text: String
        var isFinal: Bool
        var isEcho: Bool
        var updatedAt: Date

        var isVisible: Bool { !text.isEmpty && !isEcho }
    }

    private struct TurnKey: Hashable {
        let speaker: Speaker
        let utterance: Int
    }

    static let echoWindow: TimeInterval = 10
    private static let echoLookback = 40

    private var turns: [Turn] = []
    private var openTurns: [TurnKey: Int] = [:]
    private var committedCount = 0
    private var committed = RenderedLines()

    var isEmpty: Bool { committed.count == 0 && pending.count == 0 }

    var text: String { committed.text + pending.text }

    /// The end of the transcript in at most `limit` characters, cut at a line
    /// break. A single line longer than `limit` keeps its speaker label and is
    /// cut at a word instead.
    func tail(maxCharacters limit: Int) -> String {
        let pending = self.pending
        guard committed.count + pending.count > limit else { return committed.text + pending.text }
        let window = lastCharacters(limit + 1, pending: pending)
        if let newline = window.firstIndex(of: "\n") {
            return String(window[window.index(after: newline)...])
        }
        let speaker = (pending.lastSpeaker ?? committed.lastSpeaker)?.rawValue ?? ""
        let prefix = "\(speaker): …"
        let body = window.suffix(max(0, limit - prefix.count))
        let wordStart = body.firstIndex(of: " ").map { body.index(after: $0) } ?? body.startIndex
        return prefix + body[wordStart...]
    }

    /// Applies one recognizer update. Returns the turn when this update
    /// finished a visible (non-echo) turn.
    @discardableResult
    mutating func apply(_ segment: TranscriptSegment, from speaker: Speaker, at time: Date) -> Turn? {
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = TurnKey(speaker: speaker, utterance: segment.utterance)
        let index: Int
        if let open = openTurns[key] {
            index = open
            turns[index].text = text
            turns[index].isFinal = segment.isFinal
            turns[index].updatedAt = time
        } else {
            guard !text.isEmpty else { return nil }
            turns.append(Turn(speaker: speaker, utterance: segment.utterance, text: text,
                              isFinal: segment.isFinal, isEcho: false, updatedAt: time))
            index = turns.count - 1
        }
        openTurns[key] = segment.isFinal ? nil : index
        refreshEchoFlags(at: time)
        commitFinishedTurns()
        let turn = turns[index]
        return segment.isFinal && turn.isVisible ? turn : nil
    }

    // MARK: - Rendering

    private var pending: RenderedLines {
        turns[committedCount...].reduce(into: RenderedLines(continuing: committed)) { $0.append($1) }
    }

    private func lastCharacters(_ count: Int, pending: RenderedLines) -> String {
        if pending.count >= count { return String(pending.text.suffix(count)) }
        return String(committed.text.suffix(count - pending.count)) + pending.text
    }

    private mutating func commitFinishedTurns() {
        while committedCount < turns.count, turns[committedCount].isFinal {
            committed.append(turns[committedCount])
            committedCount += 1
        }
    }

    // MARK: - Echo

    /// Uncommitted "You" turns are re-checked on every update, so an echo is
    /// caught whichever recognizer reports first.
    private mutating func refreshEchoFlags(at time: Date) {
        let recentThem = turns.suffix(Transcript.echoLookback)
            .filter { $0.speaker == .them && time.timeIntervalSince($0.updatedAt) <= Transcript.echoWindow }
            .map(\.text)
            .joined(separator: " ")
        for index in committedCount..<turns.count where turns[index].speaker == .you {
            turns[index].isEcho = EchoDetector.isLikelyEcho(turns[index].text, of: recentThem)
        }
    }
}

/// Turns rendered as "Speaker: text" lines, joining consecutive turns from the
/// same speaker onto one line. `continuing:` renders text that is appended
/// directly after an earlier rendering.
private struct RenderedLines {
    private(set) var text = ""
    private(set) var count = 0
    private(set) var lastSpeaker: Speaker?
    private var hasEarlierText = false

    init() {}

    init(continuing earlier: RenderedLines) {
        lastSpeaker = earlier.lastSpeaker
        hasEarlierText = earlier.count > 0 || earlier.hasEarlierText
    }

    mutating func append(_ turn: Transcript.Turn) {
        guard turn.isVisible else { return }
        let piece: String
        if lastSpeaker == turn.speaker {
            piece = " " + turn.text
        } else {
            let separator = (count > 0 || hasEarlierText) ? "\n" : ""
            piece = separator + "\(turn.speaker.rawValue): \(turn.text)"
        }
        text += piece
        count += piece.count
        lastSpeaker = turn.speaker
    }
}

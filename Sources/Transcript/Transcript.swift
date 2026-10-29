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
///
/// A long meeting stays bounded in two ways. Only the newest finished turns are
/// kept (`Limits`), and the prompt only ever needs the tail; `text` says when
/// earlier lines were trimmed. And a turn that never finishes (its recognizer
/// died mid-sentence) is frozen as it stands once enough later turns pile up
/// behind it, because everything behind an open turn is re-rendered on every update.
struct Transcript {
    /// How much of a long meeting is kept in memory.
    struct Limits: Equatable {
        /// Finished turns kept. A trim brings this down to three quarters, so
        /// the oldest turns are not re-rendered on every update.
        var maxTurns = 400
        /// The same bound in rendered characters, whichever is hit first.
        var maxCharacters = 200_000
        /// Turns allowed to wait behind one that is still open.
        var maxUncommitted = 60
    }

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
    static let trimmedMarker = "[earlier lines trimmed]"
    private static let echoLookback = 40

    private let limits: Limits
    private var turns: [Turn] = []
    /// Turns trimmed off the front so far. `openTurns` holds positions counted
    /// from the very first turn, so a trim never has to rewrite it.
    private var trimmedTurns = 0
    private var openTurns: [TurnKey: Int] = [:]
    private var committedCount = 0
    private var committed = RenderedLines()
    private var highestUtterances: [Speaker: Int] = [:]
    private(set) var hasTrimmedText = false

    init(limits: Limits = Limits()) {
        self.limits = limits
    }

    var isEmpty: Bool { !hasTrimmedText && committed.count == 0 && pending.count == 0 }

    /// The retained transcript, starting with a one-line marker once earlier
    /// lines have been trimmed.
    var text: String { text(trimmedNote: Self.trimmedMarker) }

    func text(trimmedNote: String) -> String {
        let body = committed.text + pending.text
        guard hasTrimmedText else { return body }
        return body.isEmpty ? trimmedNote : trimmedNote + "\n" + body
    }

    /// Turns held in memory, finished or not.
    var retainedTurnCount: Int { turns.count }

    /// Turns waiting behind one that is still open; each update renders them again.
    var uncommittedTurnCount: Int { turns.count - committedCount }

    var retainedCharacterCount: Int { committed.count + pending.count }

    /// The highest utterance number `speaker` has reported so far, if any.
    func highestUtterance(of speaker: Speaker) -> Int? {
        highestUtterances[speaker]
    }

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
            index = open - trimmedTurns
            turns[index].text = text
            turns[index].isFinal = segment.isFinal
            turns[index].updatedAt = time
        } else {
            guard !text.isEmpty else { return nil }
            turns.append(Turn(speaker: speaker, utterance: segment.utterance, text: text,
                              isFinal: segment.isFinal, isEcho: false, updatedAt: time))
            index = turns.count - 1
            highestUtterances[speaker] = max(highestUtterances[speaker] ?? segment.utterance, segment.utterance)
        }
        openTurns[key] = segment.isFinal ? nil : trimmedTurns + index
        refreshEchoFlags(updated: index)
        commitFinishedTurns()
        let turn = turns[index]
        trimCommittedTurns()
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
        while true {
            while committedCount < turns.count, turns[committedCount].isFinal {
                committed.append(turns[committedCount])
                committedCount += 1
            }
            guard uncommittedTurnCount > limits.maxUncommitted else { return }
            freezeOldestOpenTurn()
        }
    }

    /// Gives up waiting for the final of the oldest open turn: it keeps the text
    /// it has. An update that still arrives for it later is kept as a new turn.
    private mutating func freezeOldestOpenTurn() {
        let stale = turns[committedCount]
        turns[committedCount].isFinal = true
        openTurns[TurnKey(speaker: stale.speaker, utterance: stale.utterance)] = nil
    }

    /// Drops the oldest finished turns once a limit is passed, down to three
    /// quarters of it so this does not run on every update. Open turns are never
    /// among them: only the committed front is trimmed.
    private mutating func trimCommittedTurns() {
        guard committedCount > limits.maxTurns || committed.count > limits.maxCharacters else { return }
        let turnBudget = max(1, limits.maxTurns * 3 / 4)
        let characterBudget = limits.maxCharacters * 3 / 4
        var kept = 0
        var characters = 0
        for turn in turns[..<committedCount].reversed() {
            let cost = turn.isVisible ? turn.text.count + 1 : 0
            guard kept < turnBudget, kept == 0 || characters + cost <= characterBudget else { break }
            kept += 1
            characters += cost
        }
        let dropped = committedCount - kept
        guard dropped > 0 else { return }
        if turns[..<dropped].contains(where: \.isVisible) { hasTrimmedText = true }
        turns.removeFirst(dropped)
        trimmedTurns += dropped
        committedCount -= dropped
        committed = turns[..<committedCount].reduce(into: RenderedLines()) { $0.append($1) }
    }

    // MARK: - Echo

    /// A "You" turn is checked against what "Them" said around the time of its
    /// own latest update, and is re-checked while it is still being spoken (so an
    /// echo is caught whichever recognizer reports first). Once it is final the
    /// decision is frozen: words "Them" says afterwards must not make a genuine
    /// "You" line vanish, and time passing must not bring an echo back.
    private mutating func refreshEchoFlags(updated index: Int) {
        for candidate in committedCount..<turns.count
        where turns[candidate].speaker == .you && (candidate == index || !turns[candidate].isFinal) {
            turns[candidate].isEcho = isEcho(turns[candidate])
        }
    }

    private func isEcho(_ turn: Turn) -> Bool {
        let nearbyThem = turns.suffix(Transcript.echoLookback)
            .filter { $0.speaker == .them && abs(turn.updatedAt.timeIntervalSince($0.updatedAt)) <= Transcript.echoWindow }
            .map(\.text)
            .joined(separator: " ")
        return EchoDetector.isLikelyEcho(turn.text, of: nearbyThem)
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

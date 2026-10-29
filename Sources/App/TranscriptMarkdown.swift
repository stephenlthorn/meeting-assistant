import Foundation

/// How a call's transcript and summary look as Markdown files: a header with
/// the start time, then one timestamped line per turn. Times are local and
/// numeric, so a file name never contains a character a file system dislikes.
struct TranscriptMarkdown {
    var timeZone = TimeZone.current

    /// The file name without its extension, from the call's start time.
    func fileStem(started: Date) -> String {
        let t = parts(started)
        return String(format: "Meeting %04d-%02d-%02d %02d-%02d-%02d", t.year, t.month, t.day, t.hour, t.minute, t.second)
    }

    func header(started: Date) -> String {
        let t = parts(started)
        let when = String(format: "%04d-%02d-%02d %02d:%02d:%02d", t.year, t.month, t.day, t.hour, t.minute, t.second)
        return "# Meeting transcript\n\nStarted: \(when)\n\n"
    }

    /// One turn as a list item, so each stays on its own line when rendered.
    func line(for turn: Transcript.Turn) -> String {
        let t = parts(turn.startedAt)
        let clock = String(format: "%02d:%02d:%02d", t.hour, t.minute, t.second)
        let text = turn.text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return "- [\(clock)] \(turn.speaker.rawValue): \(text)\n"
    }

    /// A whole transcript from the turns in memory, for a save that has no
    /// session file behind it.
    func document(started: Date, turns: [Transcript.Turn], trimmedNote: String?) -> String {
        let note = trimmedNote.map { $0 + "\n\n" } ?? ""
        return header(started: started) + note + turns.map(line(for:)).joined()
    }

    func summaryDocument(summary: String, transcriptName: String?) -> String {
        let source = transcriptName.map { "Transcript: \($0)\n\n" } ?? ""
        return "# Meeting summary\n\n" + source + summary.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private struct Parts {
        let year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int
    }

    private func parts(_ date: Date) -> Parts {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return Parts(year: c.year ?? 0, month: c.month ?? 0, day: c.day ?? 0,
                     hour: c.hour ?? 0, minute: c.minute ?? 0, second: c.second ?? 0)
    }
}

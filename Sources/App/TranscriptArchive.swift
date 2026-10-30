import Foundation

/// One call's transcript as a Markdown file on this Mac. The file is rewritten
/// whole and atomically at each flush, but the lines already in it are read back
/// from disk rather than kept: only lines not yet written are held in memory,
/// so a three-hour call costs no more memory than a short one, and the live
/// transcript can trim old turns because they are already here.
///
/// The file is the committed lines (those that will not change) followed by a
/// snapshot of the turns still being spoken. The next flush keeps the committed
/// part and replaces the snapshot with whatever is current.
///
/// A folder that cannot be written must not cost unbounded memory: after a few
/// failed writes in a row (or a backlog past a limit) saving is paused, lines
/// spoken meanwhile are not kept, and the one problem shown says so. Writes keep
/// being tried, and when one works the file carries on with a note where the gap is.
@MainActor
final class TranscriptArchive {
    nonisolated static let defaultMaximumUnwrittenCharacters = 2_000_000
    nonisolated static let defaultFailuresBeforePausing = 5
    private static let missingNote = "[earlier lines were not found when this file was updated]\n\n"
    private static let pausedNote = "[lines spoken while saving was paused are not in this file]\n\n"

    /// Why saving stopped taking lines: the last error (if a write failed) and what that means.
    struct SavingPaused: LocalizedError {
        let cause: Error?

        var errorDescription: String? {
            let reason = cause.map { $0.localizedDescription.trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }
                ?? "Too much is waiting to be written"
            return "\(reason). Saving is paused; lines spoken until it works again are not kept."
        }
    }

    private(set) var url: URL
    private(set) var lastError: Error?
    /// Why the last summary could not be saved, kept apart from `lastError` so
    /// one does not hide the other.
    private(set) var lastSummaryError: Error?
    /// Lines are not being kept because writes keep failing.
    private(set) var isPaused = false

    private let files: TranscriptFileStoring
    private let format: TranscriptMarkdown
    private let header: Data
    private let maximumUnwrittenCharacters: Int
    private let failuresBeforePausing: Int
    /// Bytes of the file that are header plus committed lines.
    private var committedBytes = 0
    /// Committed lines the file does not have yet.
    private var unwritten = ""
    private var failedWrites = 0
    private var droppedWhilePaused = false
    /// Where, in the lines after the header, a summary of the call starts.
    private var summaryStart = 0

    /// Whether the transcript file exists, as far as this session knows.
    var hasFile: Bool { committedBytes > 0 }
    /// Characters held for a write that has not happened yet.
    var unwrittenCharacters: Int { unwritten.count }

    init(folder: URL, started: Date, files: TranscriptFileStoring, format: TranscriptMarkdown = TranscriptMarkdown(),
         maximumUnwrittenCharacters: Int = TranscriptArchive.defaultMaximumUnwrittenCharacters,
         failuresBeforePausing: Int = TranscriptArchive.defaultFailuresBeforePausing) {
        self.url = folder.appendingPathComponent(format.fileStem(started: started) + ".md")
        self.files = files
        self.format = format
        self.maximumUnwrittenCharacters = maximumUnwrittenCharacters
        self.failuresBeforePausing = failuresBeforePausing
        header = Data(format.header(started: started).utf8)
    }

    /// Committed turns, in transcript order, waiting for the next flush.
    func append(_ turns: [Transcript.Turn]) {
        for turn in turns {
            guard !isPaused else {
                droppedWhilePaused = true
                continue
            }
            guard unwritten.count < maximumUnwrittenCharacters else {
                pause(cause: nil)
                droppedWhilePaused = true
                continue
            }
            unwritten += format.line(for: turn)
        }
    }

    /// From here on a summary of the call leaves out everything written so far:
    /// the user cleared the transcript. The file itself keeps it all.
    func markCleared() {
        summaryStart = max(0, committedBytes - header.count) + unwritten.utf8.count
    }

    /// Writes the committed lines plus `snapshot` (the turns still in progress).
    /// Nothing is written for an empty transcript. A failed write keeps the
    /// lines for the next try.
    @discardableResult
    func flush(snapshot: [Transcript.Turn]) -> Bool {
        guard hasFile || !unwritten.isEmpty || !snapshot.isEmpty else { return true }
        if !hasFile { url = unusedURL(for: url) }
        var committed: Data
        do {
            committed = try earlierContents()
            committed.append(Data(unwritten.utf8))
            if droppedWhilePaused { committed.append(Data(Self.pausedNote.utf8)) }
            var document = committed
            document.append(Data(snapshot.map(format.line(for:)).joined().utf8))
            try files.replace(url, with: document)
        } catch {
            writeFailed(error)
            return false
        }
        committedBytes = committed.count
        unwritten = ""
        lastError = nil
        failedWrites = 0
        isPaused = false
        droppedWhilePaused = false
        return true
    }

    /// The whole file as last written, header included. Nil when there is no
    /// file yet or it cannot be read.
    func contents() -> Data? {
        guard hasFile else { return nil }
        return (try? files.read(url)) ?? nil
    }

    /// The transcript lines as last written, without the header, from the point
    /// the transcript was last cleared.
    func body() -> String? {
        guard let data = contents(), data.count >= header.count + summaryStart else { return nil }
        return String(data: data.dropFirst(header.count + summaryStart), encoding: .utf8)
    }

    /// Saves a summary next to the transcript, as `<transcript name>-summary.md`.
    @discardableResult
    func saveSummary(_ summary: String) -> Bool {
        let stem = url.deletingPathExtension().lastPathComponent
        let target = url.deletingLastPathComponent().appendingPathComponent(stem + "-summary.md")
        let document = format.summaryDocument(summary: summary, transcriptName: url.lastPathComponent)
        do {
            try files.replace(target, with: Data(document.utf8))
            lastSummaryError = nil
            return true
        } catch {
            lastSummaryError = error
            return false
        }
    }

    /// The part of the file to keep: what was written before. If the file was
    /// deleted or cut short in the meantime, this starts it again and says so.
    /// A file that is there but cannot be read throws instead: rewriting it from
    /// what is in memory would destroy the lines that were trimmed from memory.
    private func earlierContents() throws -> Data {
        guard hasFile else { return header }
        if let existing = try files.read(url), existing.count >= committedBytes {
            return Data(existing.prefix(committedBytes))
        }
        let note = Data(Self.missingNote.utf8)
        summaryStart = note.count
        return header + note
    }

    private func writeFailed(_ error: Error) {
        failedWrites += 1
        if failedWrites >= failuresBeforePausing {
            pause(cause: error)
        } else {
            lastError = error
        }
    }

    private func pause(cause: Error?) {
        isPaused = true
        lastError = SavingPaused(cause: cause ?? failureBehindPause)
    }

    private var failureBehindPause: Error? {
        (lastError as? SavingPaused)?.cause ?? lastError
    }

    /// Two calls that start in the same second must not overwrite each other.
    private func unusedURL(for wanted: URL) -> URL {
        guard files.exists(wanted) else { return wanted }
        let stem = wanted.deletingPathExtension().lastPathComponent
        let folder = wanted.deletingLastPathComponent()
        for number in 2...99 {
            let candidate = folder.appendingPathComponent("\(stem) \(number).md")
            if !files.exists(candidate) { return candidate }
        }
        return wanted
    }
}

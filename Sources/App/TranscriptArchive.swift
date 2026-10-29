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
@MainActor
final class TranscriptArchive {
    private(set) var url: URL
    private(set) var lastError: Error?

    private let files: TranscriptFileStoring
    private let format: TranscriptMarkdown
    private let header: Data
    /// Bytes of the file that are header plus committed lines.
    private var committedBytes = 0
    /// Committed lines the file does not have yet.
    private var unwritten = ""

    /// Whether the transcript file exists, as far as this session knows.
    var hasFile: Bool { committedBytes > 0 }

    init(folder: URL, started: Date, files: TranscriptFileStoring, format: TranscriptMarkdown = TranscriptMarkdown()) {
        self.url = folder.appendingPathComponent(format.fileStem(started: started) + ".md")
        self.files = files
        self.format = format
        header = Data(format.header(started: started).utf8)
    }

    /// Committed turns, in transcript order, waiting for the next flush.
    func append(_ turns: [Transcript.Turn]) {
        unwritten += turns.map(format.line(for:)).joined()
    }

    /// Writes the committed lines plus `snapshot` (the turns still in progress).
    /// Nothing is written for an empty transcript. A failed write keeps the
    /// lines for the next try.
    @discardableResult
    func flush(snapshot: [Transcript.Turn]) -> Bool {
        guard hasFile || !unwritten.isEmpty || !snapshot.isEmpty else { return true }
        if !hasFile { url = unusedURL(for: url) }
        var committed = earlierContents()
        committed.append(Data(unwritten.utf8))
        var document = committed
        document.append(Data(snapshot.map(format.line(for:)).joined().utf8))
        do {
            try files.replace(url, with: document)
        } catch {
            lastError = error
            return false
        }
        committedBytes = committed.count
        unwritten = ""
        lastError = nil
        return true
    }

    /// The whole file as last written, header included.
    func contents() -> Data? {
        hasFile ? files.read(url) : nil
    }

    /// The transcript lines as last written, without the header.
    func body() -> String? {
        guard let data = contents(), data.count >= header.count else { return nil }
        return String(data: data.dropFirst(header.count), encoding: .utf8)
    }

    /// Saves a summary next to the transcript, as `<transcript name>-summary.md`.
    @discardableResult
    func saveSummary(_ summary: String) -> Bool {
        let stem = url.deletingPathExtension().lastPathComponent
        let target = url.deletingLastPathComponent().appendingPathComponent(stem + "-summary.md")
        let document = format.summaryDocument(summary: summary, transcriptName: url.lastPathComponent)
        do {
            try files.replace(target, with: Data(document.utf8))
            lastError = nil
            return true
        } catch {
            lastError = error
            return false
        }
    }

    /// The part of the file to keep: what was written before. If the file was
    /// deleted or cut short in the meantime, this starts it again and says so.
    private func earlierContents() -> Data {
        guard hasFile else { return header }
        if let existing = files.read(url), existing.count >= committedBytes {
            return Data(existing.prefix(committedBytes))
        }
        return header + Data("[earlier lines were not found when this file was updated]\n\n".utf8)
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

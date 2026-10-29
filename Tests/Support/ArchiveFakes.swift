import Foundation

/// Transcript files held in memory, so tests see exactly what would be written
/// where, and can make writes fail.
final class FakeTranscriptFiles: TranscriptFileStoring {
    private(set) var files: [URL: Data] = [:]
    private(set) var writes: [URL] = []
    private(set) var reads = 0
    private(set) var prepared: [URL] = []
    var failure: Error?

    func read(_ url: URL) -> Data? {
        reads += 1
        return files[url]
    }

    func exists(_ url: URL) -> Bool {
        files[url] != nil
    }

    func prepareFolder(_ url: URL) throws {
        if let failure { throw failure }
        prepared.append(url)
    }

    func replace(_ url: URL, with data: Data) throws {
        if let failure { throw failure }
        files[url] = data
        writes.append(url)
    }

    func text(at url: URL) -> String? {
        files[url].flatMap { String(data: $0, encoding: .utf8) }
    }

    /// The only file written, for tests that expect exactly one.
    var onlyFile: (url: URL, text: String)? {
        guard files.count == 1, let entry = files.first else { return nil }
        return (entry.key, String(data: entry.value, encoding: .utf8) ?? "")
    }

    func put(_ text: String, at url: URL) {
        files[url] = Data(text.utf8)
    }

    func remove(_ url: URL) {
        files[url] = nil
    }
}

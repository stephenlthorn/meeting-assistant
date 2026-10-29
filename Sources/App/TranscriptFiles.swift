import Foundation

/// The file operations transcript saving needs, so tests can use a fake and
/// the app uses the disk.
protocol TranscriptFileStoring {
    func read(_ url: URL) -> Data?
    func exists(_ url: URL) -> Bool
    /// Replaces the file at `url` with `data` in one step, creating its folder
    /// if needed. A reader never sees half a file, and the file is private to
    /// the user.
    func replace(_ url: URL, with data: Data) throws
}

struct DiskTranscriptFiles: TranscriptFileStoring {
    func read(_ url: URL) -> Data? {
        try? Data(contentsOf: url)
    }

    func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Writes a sibling file that is owner-only from the moment it exists (so
    /// there is no window where it is readable by others), then renames it over
    /// the target. A folder this creates is owner-only too.
    func replace(_ url: URL, with data: Data) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let partial = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).partial")
        let descriptor = open(partial.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw Self.failure() }
        do {
            try Self.writeAll(data, to: descriptor)
            guard fsync(descriptor) == 0 else { throw Self.failure() }
        } catch {
            close(descriptor)
            unlink(partial.path)
            throw error
        }
        close(descriptor)
        guard rename(partial.path, url.path) == 0 else {
            let failure = Self.failure()
            unlink(partial.path)
            throw failure
        }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw failure()
                }
                offset += written
            }
        }
    }

    private static func failure() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

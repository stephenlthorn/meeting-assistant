import XCTest

/// The real file operations, in a throwaway folder.
final class DiskTranscriptFilesTests: XCTestCase {
    private let files = DiskTranscriptFiles()

    func testWritingCreatesTheFolderAndAnOwnerOnlyFile() throws {
        let folder = try makeFolder().appendingPathComponent("Meeting Assistant/2026")
        let file = folder.appendingPathComponent("call.md")

        try files.replace(file, with: Data("hello".utf8))

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "hello")
        XCTAssertEqual(try permissions(of: file), 0o600)
        XCTAssertEqual(try permissions(of: folder), 0o700)
    }

    func testPreparingCreatesAnOwnerOnlyFolderAndIsHarmlessWhenItExists() throws {
        let folder = try makeFolder().appendingPathComponent("Meeting Assistant")

        try files.prepareFolder(folder)
        try files.prepareFolder(folder)

        XCTAssertEqual(try permissions(of: folder), 0o700)
    }

    func testReplacingKeepsTheFileOwnerOnlyEvenIfItWasOpenToOthers() throws {
        let file = try makeFolder().appendingPathComponent("call.md")
        try Data("old".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)

        try files.replace(file, with: Data("new".utf8))

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "new")
        XCTAssertEqual(try permissions(of: file), 0o600)
    }

    func testNothingElseIsLeftBehindInTheFolder() throws {
        let folder = try makeFolder()
        let file = folder.appendingPathComponent("call.md")

        try files.replace(file, with: Data("one".utf8))
        try files.replace(file, with: Data("two".utf8))

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["call.md"])
    }

    func testReadingGivesWhatWasWrittenAndNothingForAMissingFile() throws {
        let file = try makeFolder().appendingPathComponent("call.md")
        XCTAssertNil(try files.read(file))
        XCTAssertFalse(files.exists(file))

        try files.replace(file, with: Data("kept".utf8))

        XCTAssertEqual(try files.read(file), Data("kept".utf8))
        XCTAssertTrue(files.exists(file))
    }

    func testAReadThatFailsIsAnErrorNotAMissingFile() throws {
        let folder = try makeFolder()

        XCTAssertThrowsError(try files.read(folder), "a path that cannot be read as a file is not 'missing'")
    }

    func testAFolderThatDoesNotExistMeansTheFileIsMissing() throws {
        let file = try makeFolder().appendingPathComponent("gone/call.md")

        XCTAssertNil(try files.read(file))
    }

    func testAFolderThatCannotBeCreatedIsAnError() throws {
        let blocker = try makeFolder().appendingPathComponent("not-a-folder")
        try Data("file".utf8).write(to: blocker)

        XCTAssertThrowsError(try files.replace(blocker.appendingPathComponent("call.md"), with: Data("x".utf8)))
    }

    func testAFailedReplaceLeavesTheOldFileAndNoPartialFile() throws {
        let folder = try makeFolder()
        let target = folder.appendingPathComponent("taken")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)

        XCTAssertThrowsError(try files.replace(target, with: Data("x".utf8)))

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["taken"])
    }

    // MARK: - Helpers

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ma-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func permissions(of url: URL) throws -> Int {
        let value = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        return try XCTUnwrap(value).intValue
    }
}

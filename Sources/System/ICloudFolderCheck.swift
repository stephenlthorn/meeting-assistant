import Foundation

/// Whether files saved in a folder would be uploaded to iCloud. The app promises
/// that saved transcripts stay on this Mac, which a folder iCloud syncs would
/// quietly break, so Settings warns when the chosen folder is one.
///
/// A folder syncs when it is inside iCloud Drive's storage, when macOS reports it
/// (or a parent it will be created in) as ubiquitous, or when it is under Desktop
/// or Documents and that folder has an iCloud copy, which is what "Desktop &
/// Documents Folders" sync leaves on disk. The disk questions come in as closures
/// so a test can describe a Mac with and without that sync.
struct ICloudFolderCheck {
    let home: URL
    let exists: (URL) -> Bool
    let isUbiquitous: (URL) -> Bool

    private static let iCloudDriveStorage = "Library/Mobile Documents"
    private static let syncedHomeFolders = ["Desktop", "Documents"]

    func syncs(_ folder: URL) -> Bool {
        let path = resolved(folder)
        let homePath = resolved(home)
        let storage = homePath.appendingPathComponent(Self.iCloudDriveStorage, isDirectory: true)
        if Self.isInside(path, storage) { return true }
        if existingFolders(from: path).contains(where: isUbiquitous) { return true }
        return Self.syncedHomeFolders.contains { name in
            Self.isInside(path, homePath.appendingPathComponent(name, isDirectory: true))
                && exists(storage.appendingPathComponent("com~apple~CloudDocs/\(name)", isDirectory: true))
        }
    }

    /// The folder and its parents that exist, so a folder not created yet is judged by where it will be created.
    private func existingFolders(from path: URL) -> [URL] {
        var folders: [URL] = []
        var candidate = path
        while candidate.path != "/" {
            if exists(candidate) { folders.append(candidate) }
            candidate = candidate.deletingLastPathComponent()
        }
        return folders
    }

    /// Symlinks are followed (a link into iCloud Drive syncs), including for a folder not created
    /// yet: Foundation leaves a path alone when its last part is missing, so the part that exists
    /// is resolved and the rest put back.
    private func resolved(_ url: URL) -> URL {
        var missing: [String] = []
        var base = url.standardizedFileURL
        while base.path != "/", !exists(base) {
            missing.insert(base.lastPathComponent, at: 0)
            base = base.deletingLastPathComponent()
        }
        return missing.reduce(base.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }
    }

    /// Case is ignored because the usual Mac volume ignores it.
    private static func isInside(_ path: URL, _ folder: URL) -> Bool {
        let path = path.path.lowercased()
        let folder = folder.path.lowercased()
        return path == folder || path.hasPrefix(folder + "/")
    }

    /// The check against the real disk, for the user whose home is `home`.
    static func onDisk(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> ICloudFolderCheck {
        ICloudFolderCheck(
            home: home,
            exists: { FileManager.default.fileExists(atPath: $0.path) },
            isUbiquitous: { (try? $0.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem ?? false })
    }
}

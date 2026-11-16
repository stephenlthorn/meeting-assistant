import Foundation

/// One Markdown file as a card: the first `# Heading` is the title, a line
/// `Triggers: a, b, c` lists the phrases, and everything else is the body.
enum CardFile {
    struct Skipped: Error, Equatable {
        let file: String
        let reason: String
    }

    static func parse(_ text: String, file: String) -> Result<Card, Skipped> {
        func skip(_ reason: String) -> Result<Card, Skipped> { .failure(Skipped(file: file, reason: reason)) }
        var title: String?
        var triggerList: String?
        var body: [String] = []
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            if title == nil, line.hasPrefix("# ") {
                title = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
            } else if triggerList == nil, line.lowercased().hasPrefix("triggers:") {
                triggerList = String(line.dropFirst("triggers:".count))
            } else {
                body.append(String(line))
            }
        }
        guard let title else { return skip("no '# Heading' line for the title") }
        guard !title.isEmpty else { return skip("the '# Heading' line is empty") }
        guard let triggerList else { return skip("no 'Triggers: a, b, c' line") }
        let triggers = triggerList.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !CardMatcher.words(in: $0).isEmpty }
        guard !triggers.isEmpty else { return skip("the Triggers line has no usable phrase") }
        let text = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return skip("no body text") }
        return .success(Card(id: "file:" + file, title: title, triggers: triggers, body: text))
    }
}

/// A folder of `.md` files read as cards. Files that cannot be used are listed
/// with why, so one bad note never hides the rest.
enum CardFolder {
    struct Loaded: Equatable {
        var cards: [Card] = []
        var skipped: [CardFile.Skipped] = []
        var folderError: String?
    }

    /// A card is a few lines; anything bigger is not one.
    static let maxFileBytes = 100_000
    static let maxFiles = 1_000

    static func load(_ folder: URL, fileManager: FileManager = .default) -> Loaded {
        var loaded = Loaded()
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        } catch {
            loaded.folderError = "Couldn't read the folder: \(error.localizedDescription)"
            return loaded
        }
        let files = urls.filter { $0.pathExtension.lowercased() == "md" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        for url in files.prefix(maxFiles) {
            let name = url.lastPathComponent
            guard let data = try? Data(contentsOf: url) else {
                loaded.skipped.append(.init(file: name, reason: "couldn't be read"))
                continue
            }
            guard data.count <= maxFileBytes else {
                loaded.skipped.append(.init(file: name, reason: "too large to be a card"))
                continue
            }
            guard let text = String(data: data, encoding: .utf8) else {
                loaded.skipped.append(.init(file: name, reason: "isn't UTF-8 text"))
                continue
            }
            switch CardFile.parse(text, file: name) {
            case .success(let card): loaded.cards.append(card)
            case .failure(let skipped): loaded.skipped.append(skipped)
            }
        }
        if files.count > maxFiles {
            loaded.folderError = "Only the first \(maxFiles) files were read."
        }
        return loaded
    }
}

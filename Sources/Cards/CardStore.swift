import Foundation

/// The cards the user manages in Settings, saved in UserDefaults on this Mac,
/// plus the cards read from their card folder (never saved: the folder is the
/// source). Nothing here touches the network.
@MainActor
final class CardStore: ObservableObject {
    static let defaultsKey = "cards.items"

    @Published private(set) var userCards: [Card]
    @Published private(set) var folderCards: [Card] = []
    @Published private(set) var folderSkipped: [CardFile.Skipped] = []
    @Published private(set) var folderError: String?
    /// Goes up with every change, so whoever compiled the cards (a matcher) can
    /// tell with one comparison that it is stale.
    private(set) var revision = 0

    /// Reads a card folder. A seam so a test can make the read slow.
    var folderLoader: @Sendable (URL) -> CardFolder.Loaded = { CardFolder.load($0) }

    private var folderLoadToken = 0
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        userCards = defaults.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode([Card].self, from: $0) } ?? []
    }

    /// What can fire: enabled cards of the user's, then every card in the folder.
    var activeCards: [Card] { userCards.filter(\.isEnabled) + folderCards }

    /// Every trigger phrase of an active card, once each, for speech recognition's vocabulary.
    var triggerPhrases: [String] {
        var seen = Set<String>()
        return activeCards.flatMap(\.triggers).filter { seen.insert($0.lowercased()).inserted }
    }

    func add(_ card: Card) {
        userCards.append(card)
        changed()
    }

    func update(_ card: Card) {
        guard let index = userCards.firstIndex(where: { $0.id == card.id }) else { return }
        userCards[index] = card
        changed()
    }

    func setEnabled(_ enabled: Bool, id: String) {
        guard let index = userCards.firstIndex(where: { $0.id == id }) else { return }
        userCards[index].isEnabled = enabled
        changed()
    }

    func delete(id: String) {
        userCards.removeAll { $0.id == id }
        changed()
    }

    /// Reads the folder again (nil clears it), on the caller's thread. For Settings,
    /// which wants the answer for the window it is drawing.
    func reloadFolder(_ folder: URL?) {
        folderLoadToken += 1
        apply(folder.map(folderLoader) ?? CardFolder.Loaded())
    }

    /// Reads the folder off the main actor and applies the result when it is in, so a
    /// slow disk or a big folder never holds up the caller (listening starts at once;
    /// the folder's cards become active when loaded). A newer reload wins over an
    /// older one still in flight. Called when listening starts, so edits made in a
    /// notes app are picked up.
    @discardableResult
    func reloadFolderInBackground(_ folder: URL?) -> Task<Void, Never> {
        folderLoadToken += 1
        let token = folderLoadToken
        guard let folder else {
            apply(CardFolder.Loaded())
            return Task {}
        }
        let load = folderLoader
        return Task { [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) { load(folder) }.value
            guard let self, self.folderLoadToken == token else { return }
            self.apply(loaded)
        }
    }

    private func apply(_ loaded: CardFolder.Loaded) {
        guard loaded.cards != folderCards || loaded.skipped != folderSkipped || loaded.folderError != folderError else {
            return
        }
        folderCards = loaded.cards
        folderSkipped = loaded.skipped
        folderError = loaded.folderError
        revision += 1
    }

    private func changed() {
        revision += 1
        if let data = try? JSONEncoder().encode(userCards) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}

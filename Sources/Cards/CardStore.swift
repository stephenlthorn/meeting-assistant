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

    /// Reads the folder again (nil clears it). Called when listening starts and
    /// when Settings opens, so edits made in a notes app are picked up.
    func reloadFolder(_ folder: URL?) {
        let loaded = folder.map { CardFolder.load($0) } ?? CardFolder.Loaded()
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

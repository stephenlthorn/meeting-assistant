import AppKit
import SwiftUI

/// Settings for instant cards: the user's own cards (add, edit, delete, turn
/// off), an optional folder of `.md` files, and whether "You" lines can fire a
/// card too. Everything stays on this Mac.
struct CardsSection: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var store: CardStore
    @State private var editing: CardDraft?

    init(settings: AppSettings) {
        self.settings = settings
        store = settings.cards
    }

    var body: some View {
        Section("Instant cards") {
            ForEach(store.userCards) { card in
                HStack {
                    Toggle("", isOn: Binding(get: { card.isEnabled },
                                             set: { store.setEnabled($0, id: card.id) }))
                        .labelsHidden()
                    VStack(alignment: .leading, spacing: 1) {
                        Text(card.title).lineLimit(1)
                        Text(card.triggers.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button("Edit") { editing = CardDraft(card) }
                    Button("Delete", role: .destructive) { store.delete(id: card.id) }
                }
            }
            Button("Add Card…") { editing = CardDraft() }

            HStack {
                Text(folderLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Choose Card Folder…", action: chooseFolder)
                if settings.cardsFolder != nil {
                    Button("Clear") { settings.cardsFolder = nil }
                }
            }
            if let error = store.folderError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            ForEach(store.folderSkipped.prefix(5), id: \.file) { skipped in
                Text("Skipped \(skipped.file): \(skipped.reason)")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if store.folderSkipped.count > 5 {
                Text("and \(store.folderSkipped.count - 5) more skipped")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Toggle("Also show cards for things you say", isOn: $settings.cardsMatchYou)
            Text(CardsText.help)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { store.reloadFolder(settings.cardsFolder) }
        .onChange(of: settings.cardsFolder) { store.reloadFolder(settings.cardsFolder) }
        .sheet(item: $editing) { draft in
            CardEditor(draft: draft) { saved in
                if store.userCards.contains(where: { $0.id == saved.id }) { store.update(saved) } else { store.add(saved) }
                editing = nil
            } onCancel: {
                editing = nil
            }
        }
    }

    private var folderLabel: String {
        guard let folder = settings.cardsFolder else { return "No card folder chosen" }
        let path = (folder.path as NSString).abbreviatingWithTildeInPath
        return "\(path) (\(store.folderCards.count) cards)"
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a folder of .md files, one card each."
        if panel.runModal() == .OK, let url = panel.url { settings.cardsFolder = url }
    }
}

enum CardsText {
    static let help = "When the other side says a trigger phrase, its card appears in the overlay at once, with no network and no model. Cards are stored on this Mac only and never sent anywhere. In a card folder, each .md file is one card: the first '# Heading' is the title, a line 'Triggers: a, b, c' lists the phrases, and the rest is the text. The folder is read again when listening starts and when this window opens."
}

/// A card being edited, with its triggers as one comma-separated line.
struct CardDraft: Identifiable {
    var id: String
    var title: String
    var triggers: String
    var body: String
    var isEnabled: Bool

    init() {
        id = UUID().uuidString
        title = ""
        triggers = ""
        body = ""
        isEnabled = true
    }

    init(_ card: Card) {
        id = card.id
        title = card.title
        triggers = card.triggers.joined(separator: ", ")
        body = card.body
        isEnabled = card.isEnabled
    }

    var card: Card {
        Card(id: id, title: title.trimmingCharacters(in: .whitespacesAndNewlines),
             triggers: triggers.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                 .filter { !CardMatcher.words(in: $0).isEmpty },
             body: body.trimmingCharacters(in: .whitespacesAndNewlines), isEnabled: isEnabled)
    }

    var isComplete: Bool {
        let card = card
        return !card.title.isEmpty && !card.triggers.isEmpty && !card.body.isEmpty
    }
}

private struct CardEditor: View {
    @State var draft: CardDraft
    let onSave: (Card) -> Void
    let onCancel: () -> Void

    init(draft: CardDraft, onSave: @escaping (Card) -> Void, onCancel: @escaping () -> Void) {
        _draft = State(initialValue: draft)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Title", text: $draft.title)
            TextField("Trigger phrases, separated by commas", text: $draft.triggers)
            Text("Text (Markdown)").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $draft.body)
                .font(.system(size: 12))
                .frame(minHeight: 110)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onSave(draft.card) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.isComplete)
            }
        }
        .padding(16)
        .frame(width: 400)
    }
}

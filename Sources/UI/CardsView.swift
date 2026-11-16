import SwiftUI

/// The instant cards in the overlay, newest on top, each with a dismiss
/// button. Sits above the answer and never covers it: the stack has its own
/// height cap and scrolls inside it, and the section is absent when there are
/// no cards, so the overlay looks as it always did.
struct CardsView: View {
    let controller: AssistantController

    var body: some View {
        if !controller.cards.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(controller.cards) { card in
                            CardRow(card: card) { controller.dismissCard(id: card.id) }
                        }
                    }
                }
                .frame(maxHeight: 160)
                if controller.hiddenCardCount > 0 {
                    Text("+\(controller.hiddenCardCount) more behind these")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Divider()
            }
            .layoutPriority(1)
        }
    }
}

private struct CardRow: View {
    let card: Card
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(card.title)
                    .font(.system(size: 12, weight: .semibold))
                Text(CardText.body(card.body))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss this card")
            .accessibilityLabel("Dismiss card \(card.title)")
        }
        .padding(8)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }
}

enum CardText {
    /// Bold, italics and links show as written; line breaks are kept.
    static func body(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
    }
}

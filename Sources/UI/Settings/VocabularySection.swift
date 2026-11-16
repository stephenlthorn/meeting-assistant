import SwiftUI

/// Settings for the custom vocabulary: one phrase per line.
struct VocabularySection: View {
    @ObservedObject var settings: AppSettings

    private var analysis: Vocabulary.Analysis { Vocabulary.analyze(settings.vocabularyText) }

    var body: some View {
        Section("Custom vocabulary") {
            TextEditor(text: $settings.vocabularyText)
                .frame(minHeight: 70)
                .font(.system(size: 12))
            Text("\(analysis.distinctCount) of \(Vocabulary.maximumPhrases) phrases")
                .font(.caption)
                .foregroundStyle(analysis.ignoredCount > 0 ? .orange : .secondary)
            if analysis.ignoredCount > 0 {
                Text("Only the first \(Vocabulary.maximumPhrases) phrases are used; \(analysis.ignoredCount) will be ignored.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if !analysis.longPhrases.isEmpty {
                Text("\(analysis.longPhrases.count) phrase\(analysis.longPhrases.count == 1 ? " is" : "s are") longer than \(Vocabulary.recommendedWords) words. They are kept, but one or two words each works best.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text("Names, products and jargon to listen for, one per line. Repeats are removed and a change applies from the next Start Listening. If Deepgram is on, these words are sent to Deepgram along with the audio; with Apple's speech servers allowed, to Apple.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

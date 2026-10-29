import SwiftUI

/// The meeting summary in a small window of its own: a summary is longer than
/// the overlay's answer area, and worth selecting from and copying.
struct SummaryView: View {
    let controller: AssistantController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Meeting summary")
                    .font(.headline)
                if controller.isSummarizing {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Button("Copy") { Clipboard.copy(controller.summary) }
                    .disabled(controller.summary.isEmpty)
            }
            if let note = controller.summaryNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                Text(shownText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .frame(minWidth: 380, minHeight: 280)
    }

    private var shownText: String {
        if !controller.summary.isEmpty { return controller.summary }
        return controller.isSummarizing ? "Summarizing…" : "Choose Summarize Meeting in the menu bar menu."
    }
}

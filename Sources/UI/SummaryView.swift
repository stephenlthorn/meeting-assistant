import SwiftUI

/// The meeting summary in a small window of its own: a summary is longer than
/// the overlay's answer area, and worth selecting from and copying. Under it,
/// "Draft follow-up" streams in a short email written from the summary.
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
                VStack(alignment: .leading, spacing: 14) {
                    Text(shownText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if showsFollowUp {
                        Divider()
                        followUpSection
                    }
                }
            }
            followUpControls
        }
        .padding(16)
        .frame(minWidth: 380, minHeight: 280)
    }

    private var showsFollowUp: Bool {
        !controller.followUp.isEmpty || controller.isDraftingFollowUp
    }

    private var followUpSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Follow-up email")
                    .font(.headline)
                if controller.isDraftingFollowUp {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            Text(controller.followUp.isEmpty ? "Drafting…" : controller.followUp)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var followUpControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button("Draft follow-up") { controller.draftFollowUp() }
                    .disabled(controller.followUpBlockedReason != nil || controller.isDraftingFollowUp)
                Spacer()
                Button("Copy draft") { Clipboard.copy(controller.followUp) }
                    .disabled(controller.followUp.isEmpty)
                Button("Open in Mail") { FollowUpMail.open(draft: controller.followUp) }
                    .disabled(controller.followUp.isEmpty)
            }
            if let reason = controller.followUpBlockedReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var shownText: String {
        if !controller.summary.isEmpty { return controller.summary }
        return controller.isSummarizing ? "Summarizing…" : "Choose Summarize Meeting in the menu bar menu."
    }
}

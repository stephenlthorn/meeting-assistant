import SwiftUI

/// The overlay content: status header, live two-sided transcript, and streaming answer.
struct OverlayView: View {
    @ObservedObject var controller: AssistantController
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            section(title: "Transcript (You + Them)") {
                ScrollView {
                    Text(controller.transcript.isEmpty ? "Listening for audio..." : controller.transcript)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 110)
            }
            Divider()
            section(title: "Answer") {
                ScrollView {
                    Text(answerPlaceholder)
                        .font(.system(size: 13, weight: .medium))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(width: 380, height: 420, alignment: .topLeading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var answerPlaceholder: String {
        if !controller.answer.isEmpty { return controller.answer }
        if !settings.apiKeyPresent { return "Add your API key in Settings (⌘,)" }
        return "Press ⌘⇧Space for help"
    }

    private var header: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(controller.isListening ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
            Text(controller.status)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if settings.autoAnswer {
                Image(systemName: "bolt.fill")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
            }
            Text(settings.profile.rawValue)
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
        }
    }

    private func section<Content: View>(title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2)
                .foregroundStyle(.tertiary)
            content()
        }
    }
}

import SwiftUI

/// The overlay content: status, problems with a way to fix them, the live
/// two-sided transcript (kept scrolled to the latest line) and the streaming
/// answer. Each section reads only the controller state it shows, so a new
/// token in the answer does not re-render the transcript and vice versa.
struct OverlayView: View {
    let controller: AssistantController
    @ObservedObject var settings: AppSettings
    let onHide: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            OverlayHeader(controller: controller, settings: settings, onHide: onHide)
            ProblemList(controller: controller)
            Divider()
            TranscriptSection(controller: controller)
            Divider()
            AnswerSection(controller: controller, settings: settings)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(width: 380, height: 420, alignment: .topLeading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct OverlayHeader: View {
    let controller: AssistantController
    @ObservedObject var settings: AppSettings
    let onHide: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(controller.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let notice = controller.notice {
                    Text(notice)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if settings.autoAnswer {
                Image(systemName: "bolt.fill")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
                    .help("Auto-answer is on")
            }
            Text(settings.profile.rawValue)
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
            Button(action: onHide) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Hide the overlay (\(settings.overlayHotKey.label))")
        }
    }

    private var statusColor: Color {
        switch controller.listening {
        case .listening: .green
        case .starting: .orange
        case .sample: .blue
        case .idle: .gray
        }
    }
}

private struct ProblemList: View {
    let controller: AssistantController

    var body: some View {
        if !controller.problems.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(controller.problems) { problem in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                        Text(problem.message)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                        if let fix = problem.fix {
                            Spacer(minLength: 4)
                            Button("Open Settings") { NSWorkspace.shared.open(fix.settingsURL) }
                                .controlSize(.small)
                        }
                    }
                }
            }
        }
    }
}

private struct TranscriptSection: View {
    let controller: AssistantController
    private let bottom = "bottom"

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle(text: "Transcript (You + Them)")
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(transcript)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear
                            .frame(height: 1)
                            .id(bottom)
                    }
                }
                .frame(maxHeight: 110)
                .onChange(of: controller.transcriptDisplay) {
                    proxy.scrollTo(bottom, anchor: .bottom)
                }
            }
        }
    }

    private var transcript: String {
        controller.transcriptDisplay.isEmpty
            ? OverlayText.transcriptPlaceholder(for: controller.listening)
            : controller.transcriptDisplay
    }
}

private struct AnswerSection: View {
    let controller: AssistantController
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                SectionTitle(text: "Answer")
                if controller.isAnswering {
                    ProgressView()
                        .controlSize(.mini)
                }
                Spacer()
                if !controller.answer.isEmpty {
                    Button {
                        Clipboard.copy(controller.answer)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy the answer")
                }
            }
            ScrollView {
                Text(OverlayText.answer(controller.answer, isAnswering: controller.isAnswering,
                                        hasKey: settings.apiKeyPresent, shortcut: settings.answerHotKey.label))
                    .font(.system(size: 13, weight: .medium))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct SectionTitle: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }
}

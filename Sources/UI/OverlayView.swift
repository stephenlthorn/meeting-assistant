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
                Text(StatusLine.text(status: controller.status, listening: controller.listening, model: settings.model))
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
            HStack {
                SectionTitle(text: "Transcript (You + Them)")
                Spacer()
                if controller.listening == .listening {
                    LevelMeter(levels: controller.levels)
                }
            }
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

/// Two thin bars that move with each side's loudness, so a glance says both
/// are being heard. Only this view reads the levels, so ten updates a second
/// redraw it and nothing else.
private struct LevelMeter: View {
    let levels: CaptureLevels

    var body: some View {
        HStack(spacing: 8) {
            LevelBar(label: "You", level: levels.you)
            LevelBar(label: "Them", level: levels.them)
        }
    }
}

private struct LevelBar: View {
    let label: String
    let level: Float
    private let width: CGFloat = 30

    var body: some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Capsule()
                .fill(.quaternary)
                .frame(width: width, height: 4)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(.green)
                        .frame(width: max(level > 0 ? 2 : 0, width * CGFloat(level)), height: 4)
                }
        }
        .animation(.linear(duration: 0.1), value: level)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) audio level")
        .accessibilityValue("\(Int((level * 100).rounded())) percent")
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
            if let note = controller.answerNote {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            ScrollView {
                Text(OverlayText.answer(controller.answer, isAnswering: controller.isAnswering,
                                        hasKey: settings.apiKeyPresent,
                                        keyUnreadable: settings.apiKeySource == .unreadable,
                                        shortcut: settings.answerHotKey.label))
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

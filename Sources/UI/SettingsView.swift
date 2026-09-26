import SwiftUI

/// Preferences window (⌘,): API key (Keychain), model, behavior, extra prompt
/// instructions, and optional Deepgram cloud STT.
struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var apiKeyField = ""
    @State private var deepgramField = ""

    var body: some View {
        Form {
            Section("Anthropic API") {
                SecureField("API key (sk-ant-…)", text: $apiKeyField)
                HStack {
                    Button("Save key") {
                        settings.setAPIKey(apiKeyField)
                        apiKeyField = ""
                    }
                    .disabled(apiKeyField.trimmingCharacters(in: .whitespaces).isEmpty)

                    keyStatus(settings.apiKeyPresent)
                    Spacer()
                    Button("Remove") { settings.setAPIKey("") }
                        .disabled(!settings.apiKeyPresent)
                }
                Picker("Model", selection: $settings.model) {
                    ForEach(settings.availableModels, id: \.self) { id in
                        Text(modelLabel(id)).tag(id)
                    }
                }
            }

            Section("Behavior") {
                Toggle("Auto-answer when the other side asks a question", isOn: $settings.autoAnswer)
                Picker("Profile", selection: Binding(
                    get: { settings.profile },
                    set: { settings.profileRaw = $0.rawValue }
                )) {
                    ForEach(Profile.allCases) { Text($0.rawValue).tag($0) }
                }
            }

            Section("Speech-to-text") {
                Toggle("Use Deepgram cloud STT instead of on-device", isOn: $settings.useCloudSTT)
                SecureField("Deepgram API key", text: $deepgramField)
                HStack {
                    Button("Save key") {
                        settings.setDeepgramKey(deepgramField)
                        deepgramField = ""
                    }
                    .disabled(deepgramField.trimmingCharacters(in: .whitespaces).isEmpty)

                    keyStatus(settings.deepgramKeyPresent)
                    Spacer()
                    Button("Remove") { settings.setDeepgramKey("") }
                        .disabled(!settings.deepgramKeyPresent)
                }
                Text("On-device is the default (private). Cloud STT sends call audio to Deepgram and applies the next time you Start Listening.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Extra instructions") {
                TextEditor(text: $settings.extraInstructions)
                    .frame(minHeight: 70)
                    .font(.system(size: 12))
                Text("Appended to the selected profile's prompt on every answer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 620)
    }

    private func keyStatus(_ present: Bool) -> some View {
        present
            ? Label("Key saved", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
            : Label("No key set", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
    }

    private func modelLabel(_ id: String) -> String {
        switch id {
        case "claude-haiku-4-5": return "Haiku 4.5 — fastest (recommended for live)"
        case "claude-sonnet-5": return "Sonnet 5 — balanced"
        case "claude-opus-5": return "Opus 5 — most capable, slower"
        default: return id
        }
    }
}

import SwiftUI

/// Preferences window: API key (Keychain), model, behavior, shortcuts, extra
/// prompt instructions, optional Deepgram cloud STT, and links to the privacy
/// permissions the app needs.
struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var hotKeys: HotKeyBinder
    @State private var apiKeyField = ""
    @State private var deepgramField = ""
    @State private var saveFailed = false

    var body: some View {
        Form {
            Section("Anthropic API") {
                SecureField("API key (sk-ant-…)", text: $apiKeyField)
                HStack {
                    Button("Save key") { save { settings.setAPIKey(apiKeyField) } clear: { apiKeyField = "" } }
                        .disabled(apiKeyField.trimmingCharacters(in: .whitespaces).isEmpty)
                    keyStatus(settings.apiKeySource, environmentName: "ANTHROPIC_API_KEY",
                              file: "~/.config/meeting-assistant/anthropic_key")
                    Spacer()
                    Button("Remove") { settings.removeAPIKey() }
                        .disabled(settings.apiKeySource != .keychain)
                }
                if saveFailed {
                    Text("Couldn't save the key to the Keychain.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Picker("Model", selection: $settings.model) {
                    ForEach(settings.availableModels, id: \.self) { id in
                        Text(modelLabel(id)).tag(id)
                    }
                }
            }

            Section("Behavior") {
                Toggle("Auto-answer when the other side asks a question", isOn: $settings.autoAnswer)
                Picker("Profile", selection: $settings.profile) {
                    ForEach(Profile.allCases) { Text($0.rawValue).tag($0) }
                }
            }

            Section("Shortcuts") {
                Picker("Answer now", selection: $settings.answerHotKey) {
                    ForEach(HotKeyCombo.answerChoices) { Text($0.label).tag($0) }
                }
                Picker("Show or hide the overlay", selection: $settings.overlayHotKey) {
                    ForEach(HotKeyCombo.overlayChoices) { Text($0.label).tag($0) }
                }
                if let problem = hotKeys.problem {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Speech-to-text") {
                Toggle("Use Deepgram cloud STT instead of on-device", isOn: $settings.useCloudSTT)
                SecureField("Deepgram API key", text: $deepgramField)
                HStack {
                    Button("Save key") { save { settings.setDeepgramKey(deepgramField) } clear: { deepgramField = "" } }
                        .disabled(deepgramField.trimmingCharacters(in: .whitespaces).isEmpty)
                    keyStatus(settings.deepgramKeySource, environmentName: "DEEPGRAM_API_KEY", file: nil)
                    Spacer()
                    Button("Remove") { settings.removeDeepgramKey() }
                        .disabled(settings.deepgramKeySource != .keychain)
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

            Section("Permissions") {
                ForEach(PrivacyPane.allCases, id: \.self) { pane in
                    Button("Open \(pane.title) Settings…") { NSWorkspace.shared.open(pane.settingsURL) }
                }
                Text("Screen Recording captures the other side's audio and Microphone captures yours. After allowing Screen Recording, quit and reopen Meeting Assistant.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 680)
    }

    private func save(_ write: () -> Bool, clear: () -> Void) {
        saveFailed = !write()
        if !saveFailed { clear() }
    }

    private func keyStatus(_ source: AppSettings.KeySource?, environmentName: String, file: String?) -> some View {
        let text: String
        switch source {
        case .keychain: text = "Saved in Keychain"
        case .environment: text = "Using \(environmentName)"
        case .file: text = "Using \(file ?? "key file")"
        case nil: text = "No key set"
        }
        return Label(text, systemImage: source == nil ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
            .foregroundStyle(source == nil ? .orange : .green)
    }

    private func modelLabel(_ id: String) -> String {
        switch id {
        case "claude-haiku-4-5": return "Haiku 4.5 - fastest (recommended for live)"
        case "claude-sonnet-5": return "Sonnet 5 - balanced"
        case "claude-opus-5": return "Opus 5 - most capable, slower"
        default: return id
        }
    }
}

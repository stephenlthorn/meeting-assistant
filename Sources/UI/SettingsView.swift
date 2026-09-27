import SwiftUI

/// Preferences window: API key (Keychain), model, behavior, shortcuts, extra
/// prompt instructions, optional Deepgram cloud STT (only after agreeing to send
/// it audio), privacy terms, and links to the permissions the app needs.
struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var hotKeys: HotKeyBinder
    let showWelcome: () -> Void
    let withdrawTerms: () -> Void
    @State private var apiKeyField = ""
    @State private var deepgramField = ""
    @State private var saveFailed = false
    @State private var confirmingCloudAudio = false

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
                Toggle("Use Deepgram cloud STT instead of on-device", isOn: cloudSTTBinding)
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

            Section("Privacy") {
                Text(settings.hasAcceptedTerms
                     ? "You agreed to the privacy terms on the welcome screen."
                     : "You haven't agreed to the privacy terms yet, so Meeting Assistant can't listen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Review Welcome Screen…", action: showWelcome)
                    Spacer()
                    Button("Withdraw Agreement", action: withdrawTerms)
                        .disabled(!settings.hasAcceptedTerms)
                }
                Link("Privacy policy", destination: AppLinks.privacyPolicy)
            }

            Section("Permissions") {
                ForEach(PrivacyPane.allCases, id: \.self) { pane in
                    Button("Open \(pane.title) Settings…") { NSWorkspace.shared.open(pane.settingsURL) }
                }
                Text("Screen Recording captures the other side's audio and Microphone captures yours. After allowing Screen Recording, quit and reopen Meeting Assistant.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("About") {
                Text("Meeting Assistant is open source under the MIT license. Made by Stephen Thorn.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Link("Source code on GitHub", destination: AppLinks.sourceCode)
                    Spacer()
                    Link("stephenthorn.com", destination: AppLinks.website)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 720)
        .alert("Send call audio to Deepgram?", isPresented: $confirmingCloudAudio) {
            Button("Send Audio to Deepgram") { settings.acceptCloudAudio() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Audio from both sides of your calls will stream to Deepgram for transcription instead of staying on your Mac. Deepgram's privacy terms apply.")
        }
    }

    /// Turning Deepgram on asks first, until the user has agreed once.
    private var cloudSTTBinding: Binding<Bool> {
        Binding(
            get: { settings.useCloudSTT },
            set: { turnOn in
                if turnOn && !settings.cloudAudioAccepted {
                    confirmingCloudAudio = true
                } else {
                    settings.useCloudSTT = turnOn
                }
            })
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

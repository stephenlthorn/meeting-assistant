import SwiftUI

/// Preferences window: API key (Keychain), model, behavior, shortcuts, which
/// app's audio to listen to, extra prompt instructions, optional Deepgram cloud
/// STT and Apple's speech servers (each only after agreeing to send audio
/// there), privacy terms, and links to the permissions the app needs.
struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var hotKeys: HotKeyBinder
    let showWelcome: () -> Void
    let withdrawTerms: () -> Void
    let chooseTranscriptFolder: () -> Void
    @State private var apiKeyField = ""
    @State private var deepgramField = ""
    @State private var saveFailed = false
    @State private var confirmingCloudAudio = false
    @State private var confirmingServerSpeech = false
    @State private var runningApps = SettingsView.runningBundleIDs()

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
                        .disabled(!canRemove(settings.apiKeySource))
                }
                if settings.apiKeySource == .unreadable {
                    Text("macOS wouldn't let Meeting Assistant read the saved key. Allow access when it asks, or save the key again.")
                        .font(.caption)
                        .foregroundStyle(.orange)
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

            Section("Meeting audio") {
                Picker("Listen to", selection: $settings.captureAppBundleID) {
                    Text("All apps").tag(String?.none)
                    ForEach(MeetingApps.choices(running: runningApps, saved: settings.captureAppBundleID)) { app in
                        Text(MeetingApps.label(for: app, running: runningApps)).tag(String?.some(app.bundleID))
                    }
                }
                Text("Pick the app your calls happen in to keep music, notification sounds and other tabs out of the transcript. If it isn't running when you start listening, every app is heard and the overlay says so. Takes effect the next time you start listening.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                        .disabled(!canRemove(settings.deepgramKeySource))
                }
                Text("On-device is the default (private). Turning cloud STT on sends call audio to Deepgram from the next time you Start Listening. Turning it off, or removing the key, stops that right away.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !TranscriberFactory.analyzerAvailable {
                    Toggle("Allow Apple's speech servers if on-device isn't available", isOn: serverSpeechBinding)
                        .alert("Send call audio to Apple?", isPresented: $confirmingServerSpeech) {
                            Button("Allow Apple's Servers") { settings.acceptServerSpeech() }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("If your Mac can't transcribe your language on-device, audio from both sides of your calls will stream to Apple's speech servers instead of staying on your Mac. Apple's privacy terms apply. You can turn this off any time, even mid-call.")
                        }
                    Text("Off by default. Without it, nothing is transcribed when on-device speech is unavailable. Downloading the language in System Settings, Keyboard, Dictation avoids needing it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Extra instructions") {
                TextEditor(text: $settings.extraInstructions)
                    .frame(minHeight: 70)
                    .font(.system(size: 12))
                Text("Appended to the selected profile's prompt on every answer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Transcripts") {
                Toggle("Save transcripts to a folder on this Mac", isOn: $settings.saveTranscripts)
                HStack {
                    Text((settings.transcriptFolder.path as NSString).abbreviatingWithTildeInPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose Folder…", action: chooseTranscriptFolder)
                }
                Text("Off by default. When on, each call is saved as a Markdown file every 30 seconds and when you stop, readable only by you. The files stay on this Mac. Turning it on applies from the next Start Listening; turning it off stops saving right away. Saving also lets Summarize Meeting cover a very long call in full, and saves each summary next to its transcript.")
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
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in
            runningApps = Self.runningBundleIDs()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in
            runningApps = Self.runningBundleIDs()
        }
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

    /// Turning Apple's servers on always asks; turning them off applies at once.
    private var serverSpeechBinding: Binding<Bool> {
        Binding(
            get: { settings.serverSpeechAccepted },
            set: { turnOn in
                if turnOn {
                    confirmingServerSpeech = true
                } else {
                    settings.revokeServerSpeech()
                }
            })
    }

    private static func runningBundleIDs() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
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
        case .unreadable: text = "Allow Keychain access"
        case nil: text = "No key set"
        }
        let usable = source != nil && source != .unreadable
        return Label(text, systemImage: usable ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
            .foregroundStyle(usable ? .green : .orange)
    }

    /// Only a Keychain item can be removed here, readable or not.
    private func canRemove(_ source: AppSettings.KeySource?) -> Bool {
        source == .keychain || source == .unreadable
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

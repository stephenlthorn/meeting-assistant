import XCTest

final class SpeechLanguageTests: XCTestCase {
    private let supported = ["en-US", "en-GB", "de-DE", "es-ES", "fr-FR", "ja-JP"]

    // MARK: - Default and fallback

    func testTheDefaultIsTheCurrentLocaleWhenSupported() {
        let id = SpeechLanguage.defaultIdentifier(supported: supported, current: Locale(identifier: "de_DE"))

        XCTAssertEqual(id, "de-DE")
    }

    func testTheDefaultIsEnglishUSWhenTheCurrentLocaleIsNotSupported() {
        let id = SpeechLanguage.defaultIdentifier(supported: supported, current: Locale(identifier: "th_TH"))

        XCTAssertEqual(id, "en-US")
    }

    func testASavedSupportedLocaleIsUsedWithoutANotice() {
        let resolution = SpeechLanguage.resolve(saved: "fr-FR", supported: supported, current: Locale(identifier: "en_US"))

        XCTAssertEqual(resolution, SpeechLanguage.Resolution(identifier: "fr-FR", notice: nil))
    }

    func testNoSavedChoiceUsesTheDefaultWithoutANotice() {
        let resolution = SpeechLanguage.resolve(saved: nil, supported: supported, current: Locale(identifier: "es_ES"))

        XCTAssertEqual(resolution, SpeechLanguage.Resolution(identifier: "es-ES", notice: nil))
    }

    func testAnUnsupportedSavedLocaleFallsBackAndSaysSo() throws {
        let resolution = SpeechLanguage.resolve(saved: "th-TH", supported: supported, current: Locale(identifier: "en_US"))

        XCTAssertEqual(resolution.identifier, "en-US")
        let notice = try XCTUnwrap(resolution.notice)
        XCTAssertTrue(notice.contains("Thai"), notice)
        XCTAssertTrue(notice.contains("English"), notice)
    }

    func testSavedLocalesAreComparedIgnoringUnderscoresVersusHyphens() {
        let resolution = SpeechLanguage.resolve(saved: "de_DE", supported: supported, current: Locale(identifier: "en_US"))

        XCTAssertEqual(resolution.identifier, "de-DE")
        XCTAssertNil(resolution.notice)
    }

    func testAnEmptySupportedListTrustsTheSavedChoiceInsteadOfInventingAFallback() {
        let resolution = SpeechLanguage.resolve(saved: "de-DE", supported: [], current: Locale(identifier: "en_US"))

        XCTAssertEqual(resolution, SpeechLanguage.Resolution(identifier: "de-DE", notice: nil))
    }

    func testLocalizedNamesAreShownForLocales() {
        XCTAssertEqual(SpeechLanguage.displayName("de-DE", in: Locale(identifier: "en_US")), "German (Germany)")
    }

    // MARK: - Deepgram

    func testDeepgramGetsTheLanguageWhenItIsMapped() {
        XCTAssertEqual(SpeechLanguage.deepgramLanguage(for: "en-US"), "en-US")
        XCTAssertEqual(SpeechLanguage.deepgramLanguage(for: "de-DE"), "de")
        XCTAssertEqual(SpeechLanguage.deepgramLanguage(for: "es-419"), "es-419")
        XCTAssertEqual(SpeechLanguage.deepgramLanguage(for: "fr-CA"), "fr-CA")
        XCTAssertEqual(SpeechLanguage.deepgramLanguage(for: "pt-BR"), "pt-BR")
    }

    func testARegionalVariantFallsBackToItsLanguage() {
        XCTAssertEqual(SpeechLanguage.deepgramLanguage(for: "es-MX"), "es")
        XCTAssertEqual(SpeechLanguage.deepgramLanguage(for: "de_AT"), "de")
    }

    func testNorwegianVariantsMapToDeepgramsNorwegian() {
        XCTAssertEqual(SpeechLanguage.deepgramLanguage(for: "nb-NO"), "no")
    }

    func testAnUnmappedLanguageGetsNoDeepgramLanguage() {
        XCTAssertNil(SpeechLanguage.deepgramLanguage(for: "zh-Hans-CN"))
        XCTAssertNil(SpeechLanguage.deepgramLanguage(for: "xx-YY"))
        XCTAssertNil(SpeechLanguage.deepgramLanguage(for: ""))
    }

    func testDeepgramDefaultsToTheCurrentLocaleWhenMappedElseEnglishUS() {
        XCTAssertEqual(SpeechLanguage.deepgramIdentifier(saved: nil, current: Locale(identifier: "de_DE")), "de-DE")
        XCTAssertEqual(SpeechLanguage.deepgramIdentifier(saved: nil, current: Locale(identifier: "xx_YY")), "en-US")
        XCTAssertEqual(SpeechLanguage.deepgramIdentifier(saved: "xx-YY", current: Locale(identifier: "en_US")), "xx-YY",
                       "an explicit choice is kept, so Settings and the notice can name it")
    }

    // MARK: - Answer language sentence

    func testSameAsTheCallAddsNothingForAnEnglishOrAutomaticCall() {
        XCTAssertNil(SpeechLanguage.answerSentence(answerLanguage: nil, callLocale: nil))
        XCTAssertNil(SpeechLanguage.answerSentence(answerLanguage: nil, callLocale: "en-GB"))
    }

    func testSameAsTheCallNamesAnExplicitNonEnglishCallLanguage() {
        XCTAssertEqual(SpeechLanguage.answerSentence(answerLanguage: nil, callLocale: "es-ES"), "Answer in Spanish.")
    }

    func testAnExplicitAnswerLanguageIsNamedWhateverTheCallLanguage() {
        XCTAssertEqual(SpeechLanguage.answerSentence(answerLanguage: "de", callLocale: "en-US"), "Answer in German.")
        XCTAssertEqual(SpeechLanguage.answerSentence(answerLanguage: "en", callLocale: "ja-JP"), "Answer in English.")
    }

    func testThePromptsCarryTheSentenceOnlyWhenThereIsOne() {
        let withSentence = AnswerPrompt.system("Base prompt.", languageSentence: "Answer in German.")
        let without = AnswerPrompt.system("Base prompt.", languageSentence: nil)

        XCTAssertTrue(withSentence.hasSuffix("Answer in German."), withSentence)
        XCTAssertEqual(without, "Base prompt.")
        XCTAssertTrue(SummaryPrompt.system(extraInstructions: "", languageSentence: "Answer in German.").contains("Answer in German."))
        XCTAssertFalse(SummaryPrompt.system(extraInstructions: "", languageSentence: nil).contains("Answer in"))
        XCTAssertEqual(SummaryPrompt.system(extraInstructions: "Keep it short."),
                       SummaryPrompt.system(extraInstructions: "Keep it short.", languageSentence: nil))
    }
}

@MainActor
final class SpeechSettingsTests: XCTestCase {
    func testNothingIsChosenByDefault() {
        let settings = makeTestSettings(for: self)

        XCTAssertNil(settings.speechLocaleIdentifier)
        XCTAssertNil(settings.answerLanguage)
        XCTAssertEqual(settings.vocabularyText, "")
        XCTAssertNil(settings.answerLanguageSentence)
    }

    func testChoicesSurviveARestart() {
        let suite = "MeetingAssistantTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        func open() -> AppSettings {
            AppSettings(defaults: defaults, secrets: InMemorySecretStore(values: [:]), environment: [:],
                        anthropicKeyFile: URL(fileURLWithPath: "/nonexistent/anthropic_key"))
        }
        let first = open()
        first.speechLocaleIdentifier = "de-DE"
        first.answerLanguage = "en"
        first.vocabularyText = "TiDB\nSlate"

        let second = open()

        XCTAssertEqual(second.speechLocaleIdentifier, "de-DE")
        XCTAssertEqual(second.answerLanguage, "en")
        XCTAssertEqual(second.vocabulary, ["TiDB", "Slate"])
    }

    func testChoosingAutomaticAgainForgetsTheSavedLocale() {
        let settings = makeTestSettings(for: self)
        settings.speechLocaleIdentifier = "de-DE"

        settings.speechLocaleIdentifier = nil

        XCTAssertNil(settings.speechLocaleIdentifier)
    }

    func testTheAnswerSentenceFollowsTheChoices() {
        let settings = makeTestSettings(for: self)
        settings.speechLocaleIdentifier = "fr-FR"
        XCTAssertEqual(settings.answerLanguageSentence, "Answer in French.")

        settings.answerLanguage = "en"
        XCTAssertEqual(settings.answerLanguageSentence, "Answer in English.")
    }

    func testAListeningSessionKeepsTheOptionsItStartedWith() {
        let settings = makeTestSettings(for: self)
        settings.speechLocaleIdentifier = "de-DE"
        settings.vocabularyText = "TiDB"

        settings.freezeSpeechOptions()
        settings.speechLocaleIdentifier = "fr-FR"
        settings.vocabularyText = "Slate"

        XCTAssertEqual(settings.activeSpeechOptions, SpeechOptions(localeIdentifier: "de-DE", vocabulary: ["TiDB"]))
        XCTAssertEqual(settings.speechOptions, SpeechOptions(localeIdentifier: "fr-FR", vocabulary: ["Slate"]))
    }

    func testStoppingReleasesTheSessionOptions() {
        let settings = makeTestSettings(for: self)
        XCTAssertFalse(settings.speechSessionActive)
        settings.freezeSpeechOptions()
        XCTAssertTrue(settings.speechSessionActive)

        settings.releaseSpeechOptions()

        XCTAssertNil(settings.activeSpeechOptions)
        XCTAssertFalse(settings.speechSessionActive)
    }
}

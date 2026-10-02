import Foundation
import Testing
@testable import AINews

/// The translation policy is pure, so it is tested directly. The framework
/// session itself cannot be constructed in a test, which is exactly why the
/// decision was factored out of it.
@Suite("Translation policy")
struct TranslationTests {

    private let target = "en"

    @Test("A real translation is stored")
    func storesTranslation() {
        #expect(
            TranslationCoordinator.decide(
                sourceLanguageCode: "zh",
                targetText: "Cambricon's founder is subject to enforcement",
                targetLanguageCode: target
            ) == .store("Cambricon's founder is subject to enforcement")
        )
    }

    @Test("Japanese and Korean are translated too")
    func translatesJapaneseAndKorean() {
        #expect(TranslationCoordinator.decide(sourceLanguageCode: "ja", targetText: "DNS reverse lookup", targetLanguageCode: target) == .store("DNS reverse lookup"))
        #expect(TranslationCoordinator.decide(sourceLanguageCode: "ko", targetText: "Autumn harvest in Gangnam", targetLanguageCode: target) == .store("Autumn harvest in Gangnam"))
    }

    @Test("Text already in the target language is skipped, not stored")
    func skipsAlreadyEnglish() {
        // Storing it would be harmless but it would show a pointless second
        // line identical to the first.
        #expect(
            TranslationCoordinator.decide(
                sourceLanguageCode: "en",
                targetText: "Niyo FY26: Revenue Zooms 80% YoY",
                targetLanguageCode: target
            ) == .skip
        )
    }

    @Test("An empty result is ignored rather than stored as a blank headline")
    func ignoresEmptyResult() {
        #expect(TranslationCoordinator.decide(sourceLanguageCode: "zh", targetText: "", targetLanguageCode: target) == .ignore)
        #expect(TranslationCoordinator.decide(sourceLanguageCode: "zh", targetText: "   \n ", targetLanguageCode: target) == .ignore)
    }

    @Test("An unknown source language is still translated, not skipped")
    func unknownSourceStillTranslates() {
        // Detection can fail; that must not be treated as "already English".
        #expect(TranslationCoordinator.decide(sourceLanguageCode: nil, targetText: "Some headline", targetLanguageCode: target) == .store("Some headline"))
    }

    @Test("Surrounding whitespace is trimmed")
    func trimsWhitespace() {
        #expect(TranslationCoordinator.decide(sourceLanguageCode: "zh", targetText: "  Hello  ", targetLanguageCode: target) == .store("Hello"))
    }

    // MARK: - Pre-filter

    @Test("ASCII-only titles are treated as already English")
    func asciiIsProbablyEnglish() {
        #expect(TranslationCoordinator.isProbablyEnglish("Niyo FY26: Revenue Zooms 80%"))
        #expect(TranslationCoordinator.isProbablyEnglish("Apple ships M5"))
    }

    @Test("CJK titles, and even one non-ASCII glyph, are not skipped")
    func nonASCIIIsNotEnglish() {
        #expect(!TranslationCoordinator.isProbablyEnglish("长安汽车 9 月交付 22.89 万辆"))
        #expect(!TranslationCoordinator.isProbablyEnglish("DNSの「逆引き」って何？"))
        // A single rupee sign must be enough to send it to the translator
        // rather than silently skipping.
        #expect(!TranslationCoordinator.isProbablyEnglish("Revenue grows to ₹158 Cr"))
    }

    @Test("The target language is English")
    func targetIsEnglish() {
        #expect(TranslationCoordinator.targetLanguage.languageCode?.identifier == "en")
    }
}

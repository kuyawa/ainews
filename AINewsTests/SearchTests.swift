import Foundation
import Testing
@testable import AINews

/// The search field matched only the original title, so an English query
/// found nothing on a translated row - which is most of the list.
@Suite("Headline search")
struct SearchTests {

    private func headline(original: String, translated: String?) -> Headline {
        Headline(
            url: URL(string: "https://example.com/a")!,
            title: original,
            sourceID: "x",
            publishedAt: nil,
            fetchedAt: .now,
            lastSeenAt: .now,
            translatedTitle: translated
        )
    }

    @Test("An English query matches the translation, not just the original")
    func matchesTranslation() {
        let row = headline(original: "长安汽车 9 月交付", translated: "Changan Auto delivers 228,900")
        #expect(HeadlineListView.matches(row, query: "changan"))
        #expect(HeadlineListView.matches(row, query: "CHANGAN"))       // case-insensitive
        #expect(HeadlineListView.matches(row, query: "228,900"))       // numbers too
    }

    @Test("The original script still matches")
    func matchesOriginal() {
        let row = headline(original: "长安汽车 9 月交付", translated: "Changan Auto delivers")
        #expect(HeadlineListView.matches(row, query: "长安"))
    }

    @Test("A row with no translation is still searchable by its own title")
    func matchesUntranslatedRow() {
        let row = headline(original: "Toshiba to double hard disk drive supply", translated: nil)
        #expect(HeadlineListView.matches(row, query: "toshiba"))
        #expect(!HeadlineListView.matches(row, query: "nintendo"))
    }

    @Test("An empty or whitespace query matches everything")
    func emptyQueryMatchesAll() {
        let row = headline(original: "Anything", translated: nil)
        #expect(HeadlineListView.matches(row, query: ""))
        #expect(HeadlineListView.matches(row, query: "   "))
    }
}

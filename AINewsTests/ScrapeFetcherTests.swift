import Foundation
import Testing
@testable import AINews

/// The scrape rule is a heuristic rather than a per-site selector, so what it
/// rejects matters as much as what it keeps: navigation, ads and off-site
/// links must not become headlines.
@Suite("Scraping homepages")
struct ScrapeFetcherTests {

    private let page = URL(string: "https://www.example.com/")!

    private func headlines(_ html: String) -> [ParsedItem] {
        ScrapeFetcher.headlines(in: html, pageURL: page)
    }

    @Test("A same-host anchor with headline-length text is kept")
    func keepsHeadlines() {
        let html = """
        <a href="/2026/10/500098.html">Toshiba to double hard disk drive supply</a>
        """
        let items = headlines(html)
        #expect(items.count == 1)
        #expect(items[0].title == "Toshiba to double hard disk drive supply")
        #expect(items[0].url.absoluteString == "https://www.example.com/2026/10/500098.html")
        #expect(items[0].publishedAt == nil)
    }

    @Test("Short link text is treated as navigation and dropped")
    func dropsNavigation() {
        let html = """
        <a href="/about">About</a>
        <a href="/login">Log in</a>
        <a href="/2026/10/1.html">A real headline, long enough to keep</a>
        """
        #expect(headlines(html).count == 1)
    }

    @Test("Off-host, javascript and mailto links are dropped")
    func dropsForeignLinks() {
        let html = """
        <a href="https://ads.example.net/promo">A promotional block of text</a>
        <a href="javascript:void(0)">Open the comment thread here</a>
        <a href="mailto:news@example.com">Email the newsdesk about stories</a>
        """
        #expect(headlines(html).isEmpty)
    }

    @Test("Tags inside the anchor are stripped from the title")
    func stripsInnerTags() {
        let html = """
        <a href="/2026/10/2.html"><span class=\"tag\">Exclusive</span> OpenAI pauses a model release</a>
        """
        let items = headlines(html)
        #expect(items.count == 1)
        #expect(items[0].title == "Exclusive OpenAI pauses a model release")
    }

    @Test("An image-only anchor yields no title and is dropped")
    func dropsImageOnlyAnchors() {
        let html = """
        <a href="/2026/10/3.html"><img src="/a.png" alt=\"\"></a>
        """
        #expect(headlines(html).isEmpty)
    }

    @Test("Duplicates collapse, keeping the first")
    func deduplicates() {
        let html = """
        <a href="/2026/10/4.html">First appearance of this headline</a>
        <a href="/2026/10/4.html">Second appearance of this headline</a>
        """
        let items = headlines(html)
        #expect(items.count == 1)
        #expect(items[0].title == "First appearance of this headline")
    }

    @Test("A relative href resolves against the page")
    func resolvesRelativeURLs() {
        let items = headlines("<a href=\"article/500098.html\">A headline long enough to be kept</a>")
        #expect(items.first?.url.absoluteString == "https://www.example.com/article/500098.html")
    }

    @Test("Entities are decoded, named and numeric")
    func decodesEntities() {
        #expect(ScrapeFetcher.visibleText(from: "OpenAI &amp; Anthropic") == "OpenAI & Anthropic")
        #expect(ScrapeFetcher.visibleText(from: "A &#8211; B") == "A – B")
        #expect(ScrapeFetcher.visibleText(from: "A &#x2013; B") == "A – B")
        #expect(ScrapeFetcher.visibleText(from: "&#65;&#66;") == "AB")
    }

    @Test("Whitespace inside markup collapses to single spaces")
    func collapsesWhitespace() {
        let messy = "A\n\t  headline\n   over   lines"
        #expect(ScrapeFetcher.visibleText(from: messy) == "A headline over lines")
    }

    @Test("A page with no usable anchors yields nothing rather than junk")
    func emptyPageYieldsNothing() {
        #expect(headlines("<html><body><nav><a href=\"/\">Home</a></nav></body></html>").isEmpty)
    }

    // MARK: - Article-shaped destinations

    private func article(_ string: String) -> Bool {
        ScrapeFetcher.looksLikeArticle(URL(string: string)!)
    }

    @Test("Article shapes are accepted")
    func acceptsArticleShapes() {
        #expect(article("https://www.example.com/2026/10/500098.html"))   // extension
        #expect(article("https://www.example.com/news/1234567"))         // numeric id
        #expect(article("https://www.example.com/openai-pauses-a-release")) // slug
    }

    @Test("Section and utility links are rejected")
    func rejectsSections() {
        // These are the ones that swamped DIGITIMES: long enough link text,
        // same host, but not articles.
        #expect(!article("https://www.example.com/semiconductors"))
        #expect(!article("https://www.example.com/opinions"))
        #expect(!article("https://www.example.com/index.php"))
        #expect(!article("https://www.example.com/"))
        #expect(!article("https://www.example.com/{{id}}.html"))
    }

    @Test("A tracking query does not make the same article a second headline")
    func dedupeIgnoresTrackingQuery() {
        let plain = URL(string: "https://www.example.com/news/a20261002VL206/story.html")!
        let tracked = URL(string: "https://www.example.com/news/a20261002VL206/story.html?chid=10")!
        #expect(ScrapeFetcher.dedupeKey(for: plain) == ScrapeFetcher.dedupeKey(for: tracked))
    }

    @Test("A query that carries the article id is still a distinct key")
    func dedupeKeepsQueryWhenItIsTheIdentity() {
        // /index.php is not article-shaped, so the whole URL is the key and
        // two different articles are not merged.
        let first = URL(string: "https://www.example.com/index.php?id=1")!
        let second = URL(string: "https://www.example.com/index.php?id=2")!
        #expect(ScrapeFetcher.dedupeKey(for: first) != ScrapeFetcher.dedupeKey(for: second))
    }

    @Test("Site furniture is dropped even though it is long enough to pass")
    func dropsFurniture() {
        let html = """
        <a href="/copyright.html">Copyright policy</a>
        <a href="/corrections.html">Notes &amp; corrections</a>
        <a href="/privacy.html">Privacy policy</a>
        <a href="/2026/10/500098.html">A real headline, comfortably long</a>
        """
        let items = headlines(html)
        #expect(items.count == 1)
        #expect(items[0].title == "A real headline, comfortably long")
    }

    @Test("A story ABOUT copyright is not treated as furniture")
    func keepsCopyrightStories() {
        // Matched on the whole title, not a substring, so real coverage of
        // copyright law survives.
        let html = "<a href=\"/2026/10/500099.html\">Copyright law reform clears its first hurdle</a>"
        #expect(headlines(html).count == 1)
    }
}
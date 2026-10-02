import Foundation
import Testing
@testable import AINews

/// One fixture per format, because the seed list really does contain all three
/// and a parser that only handles RSS 2.0 would silently starve three sources.
@Suite("Feed parsing")
struct FeedParserTests {

    private let parser = FeedParser()
    private let feedURL = URL(string: "https://example.com/feed.xml")!

    private func parse(_ xml: String) throws -> [ParsedItem] {
        try parser.items(from: Data(xml.utf8), feedURL: feedURL)
    }

    // MARK: - RSS 2.0

    private let rss2 = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0">
      <channel>
        <title>Example</title>
        <item>
          <title>First headline</title>
          <link>https://example.com/a</link>
          <pubDate>Tue, 01 Oct 2026 08:14:22 +0000</pubDate>
        </item>
        <item>
          <title><![CDATA[Second & headline]]></title>
          <link>https://example.com/b</link>
          <pubDate>Tue, 01 Oct 2026 09:00:00 +0000</pubDate>
        </item>
      </channel>
    </rss>
    """

    @Test("RSS 2.0 items parse with titles and links")
    func rss2Parses() throws {
        let items = try parse(rss2)
        #expect(items.count == 2)
        #expect(items[0].title == "First headline")
        #expect(items[0].url.absoluteString == "https://example.com/a")
        #expect(items[0].publishedAt != nil)
    }

    @Test("CDATA titles are unwrapped, entities are decoded")
    func cdataIsHandled() throws {
        let items = try parse(rss2)
        #expect(items[1].title == "Second & headline")
    }

    // MARK: - RSS 1.0 / RDF

    private let rdf = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
             xmlns:dc="http://purl.org/dc/elements/1.1/"
             xmlns="http://purl.org/rss/1.0/">
      <channel rdf:about="https://example.com">
        <title>Example RDF</title>
      </channel>
      <item rdf:about="https://example.com/rdf-a">
        <title>RDF headline</title>
        <link>https://example.com/rdf-a</link>
        <dc:date>2026-10-01T08:14:22Z</dc:date>
      </item>
    </rdf:RDF>
    """

    @Test("RSS 1.0 / RDF items parse, including namespaced dc:date")
    func rdfParses() throws {
        let items = try parse(rdf)
        #expect(items.count == 1)
        #expect(items[0].title == "RDF headline")
        #expect(items[0].url.absoluteString == "https://example.com/rdf-a")
        // The namespaced date must be picked up, not dropped.
        #expect(items[0].publishedAt != nil)
    }

    // MARK: - Atom

    private let atom = """
    <?xml version="1.0" encoding="utf-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom">
      <title>Example Atom</title>
      <link rel="self" href="https://example.com/feed.atom"/>
      <entry>
        <title>Atom headline</title>
        <link rel="alternate" type="text/html" href="https://example.com/atom-a"/>
        <updated>2026-10-01T08:14:22Z</updated>
      </entry>
      <entry>
        <title>Atom headline without rel</title>
        <link href="https://example.com/atom-b"/>
        <published>2026-10-01T09:00:00Z</published>
      </entry>
    </feed>
    """

    @Test("Atom entries read href, skip rel=self, accept a missing rel")
    func atomParses() throws {
        let items = try parse(atom)
        #expect(items.count == 2)
        // rel="self" must never be mistaken for an article.
        #expect(items[0].url.absoluteString == "https://example.com/atom-a")
        #expect(items[1].url.absoluteString == "https://example.com/atom-b")
    }

    @Test("Atom format is detected without relying on the URL extension")
    func atomDetectedFromContent() throws {
        // Same bytes, deliberately misleading file extension.
        let items = try parser.items(
            from: Data(atom.utf8),
            feedURL: URL(string: "https://example.com/feed.rdf")!
        )
        #expect(items.count == 2)
    }

    // MARK: - Robustness

    @Test("A malformed date never fails the parse")
    func badDateIsTolerated() throws {
        let xml = """
        <rss version="2.0"><channel><item>
          <title>Undated</title><link>https://example.com/c</link>
          <pubDate>not a real date at all</pubDate>
        </item></channel></rss>
        """
        let items = try parse(xml)
        #expect(items.count == 1)
        #expect(items[0].publishedAt == nil)
    }

    @Test("javascript and mailto links are rejected")
    func unsafeSchemesRejected() throws {
        let xml = """
        <rss version="2.0"><channel>
          <item><title>Bad</title><link>javascript:alert(1)</link></item>
          <item><title>Also bad</title><link>mailto:x@example.com</link></item>
          <item><title>Good</title><link>https://example.com/ok</link></item>
        </channel></rss>
        """
        let items = try parse(xml)
        #expect(items.count == 1)
        #expect(items[0].title == "Good")
    }

    @Test("Empty titles are dropped")
    func emptyTitlesDropped() throws {
        let xml = """
        <rss version="2.0"><channel>
          <item><title>   </title><link>https://example.com/blank</link></item>
        </channel></rss>
        """
        #expect(try parse(xml).isEmpty)
    }

    @Test("Duplicate URLs within one feed collapse to one item")
    func duplicatesCollapse() throws {
        let xml = """
        <rss version="2.0"><channel>
          <item><title>Same</title><link>https://example.com/dup</link></item>
          <item><title>Same again</title><link>https://example.com/dup</link></item>
        </channel></rss>
        """
        #expect(try parse(xml).count == 1)
    }

    @Test("Relative links resolve against the feed URL")
    func relativeLinksResolve() throws {
        let xml = """
        <rss version="2.0"><channel>
          <item><title>Relative</title><link>/story/1</link></item>
        </channel></rss>
        """
        let items = try parse(xml)
        #expect(items[0].url.absoluteString == "https://example.com/story/1")
    }

    @Test("Malformed XML throws parseFailed rather than returning nothing")
    func malformedXMLThrows() throws {
        #expect(throws: FeedError.self) {
            try parse("<rss><channel><item><title>unterminated")
        }
    }
}

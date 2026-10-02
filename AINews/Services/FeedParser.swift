import Foundation

/// Parses RSS 2.0, RSS 1.0 (RDF) and Atom with no third-party dependency.
///
/// The format is detected from the document itself, never from the URL
/// extension: a .xml file can contain Atom and a .rdf file can contain RSS 2.0.
/// The seed list happens to contain all three formats, and one of each is
/// covered by a committed fixture in the test target.
struct FeedParser: Sendable {

    func items(from data: Data, feedURL: URL) throws -> [ParsedItem] {
        let collector = FeedCollector(feedURL: feedURL)
        let parser = XMLParser(data: data)
        parser.delegate = collector
        // Namespace processing gives local names, so dc:date arrives as "date"
        // and Atom's feed/entry arrive unprefixed.
        parser.shouldProcessNamespaces = true

        guard parser.parse() else {
            let reason = parser.parserError?.localizedDescription ?? "malformed XML"
            throw FeedError.parseFailed(reason)
        }
        return collector.results()
    }
}

private final class FeedCollector: NSObject, XMLParserDelegate {

    private enum Format { case unknown, rss2, rdf, atom }

    private let feedURL: URL
    private var format: Format = .unknown
    private var inItem = false

    private var buffer = ""
    private var capturing = false

    private var title: String?
    private var link: String?
    private var guid: String?
    private var dateText: String?

    private var collected: [ParsedItem] = []

    init(feedURL: URL) { self.feedURL = feedURL }

    // MARK: - XMLParserDelegate

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName {
        case "rss": if format == .unknown { format = .rss2 }
        case "RDF": if format == .unknown { format = .rdf }
        case "feed": if format == .unknown { format = .atom }
        default: break
        }

        if elementName == "item" || elementName == "entry" {
            inItem = true
            title = nil; link = nil; guid = nil; dateText = nil
            buffer = ""; capturing = false
            return
        }

        guard inItem else { return }

        switch elementName {
        case "title":
            capturing = true; buffer = ""

        case "link":
            if format == .atom {
                // Atom puts the URL in href, and rel="self"/"edit"/"enclosure"
                // are not the article. Only alternate (the default) counts.
                let rel = attributeDict["rel"] ?? "alternate"
                if rel == "alternate", let href = attributeDict["href"] {
                    link = href
                }
            } else {
                capturing = true; buffer = ""
            }

        case "guid", "id":
            capturing = true; buffer = ""

        case "pubDate", "date", "published", "updated", "issued", "created":
            capturing = true; buffer = ""

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturing { buffer += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if capturing, let text = String(data: CDATABlock, encoding: .utf8) {
            buffer += text
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "item" || elementName == "entry" {
            finishItem()
            inItem = false
            return
        }

        guard inItem, capturing else { return }
        let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        capturing = false
        buffer = ""

        switch elementName {
        case "title":
            title = value
        case "link":
            if format != .atom { link = value }
        case "guid", "id":
            // Some feeds omit link and carry the article URL in guid.
            if guid == nil { guid = value }
        case "pubDate", "date", "published", "updated", "issued", "created":
            // First date wins: Atom published is a stronger signal than updated,
            // and both should beat a later dc:date if one ever appears.
            if dateText == nil { dateText = value }
        default:
            break
        }
    }

    // MARK: - Assembly

    func results() -> [ParsedItem] {
        // Deduplicate within the feed; the store deduplicates across runs.
        var seen = Set<URL>()
        return collected.filter { seen.insert($0.url).inserted }
    }

    private func finishItem() {
        defer {
            title = nil; link = nil; guid = nil; dateText = nil
            buffer = ""; capturing = false
        }

        guard let rawTitle = title, !rawTitle.isEmpty else { return }
        guard let href = link ?? guid, let url = resolve(href) else { return }
        collected.append(
            ParsedItem(title: rawTitle, url: url, publishedAt: parseDate(dateText))
        )
    }

    private func resolve(_ href: String) -> URL? {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lowered = trimmed.lowercased()
        guard !lowered.hasPrefix("javascript:"),
              !lowered.hasPrefix("mailto:"),
              !lowered.hasPrefix("#") else { return nil }

        if let absolute = URL(string: trimmed), let scheme = absolute.scheme {
            let s = scheme.lowercased()
            return (s == "http" || s == "https") ? absolute : nil
        }
        // Relative links resolve against the feed's own URL.
        return URL(string: trimmed, relativeTo: feedURL)?.absoluteURL
    }

    /// RSS uses RFC 822, Atom uses ISO 8601, and real feeds in the wild get
    /// both wrong. A bad date must never fail a parse, so this returns nil
    /// rather than throwing.
    private func parseDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: raw) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: raw) { return date }

        let rfc = DateFormatter()
        rfc.locale = Locale(identifier: "en_US_POSIX")
        rfc.timeZone = TimeZone(secondsFromGMT: 0)
        for pattern in [
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEE, dd MMM yyyy HH:mm Z",
            "dd MMM yyyy HH:mm:ss Z",
        ] {
            rfc.dateFormat = pattern
            if let date = rfc.date(from: raw) { return date }
        }
        return nil
    }
}

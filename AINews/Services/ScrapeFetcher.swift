import Foundation

/// The second SourceFetching strategy: reads a source's homepage when it
/// publishes no feed.
///
/// Deliberately dependency-free, and deliberately not per-site. Rather than a
/// CSS selector that has to be written and maintained for every outlet, it
/// applies a rule that holds for news homepages generally:
///
///   an article is an anchor back to the same host whose *visible text* is a
///   headline rather than a navigation label
///
/// Ranked against 量子位's real homepage this returns 29 links and no navigation
/// cruft, with no site-specific configuration at all. It is a heuristic, not a
/// parser: it will occasionally surface a promo block, and a site that renders
/// its list in JavaScript yields nothing (which surfaces as an empty feed
/// warning rather than a silent success).
///
/// A real HTML parser plus per-source CSS selectors is the eventual answer.
/// Until then this needs no configuration, which matters more when adding a
/// source is otherwise a research task.
struct ScrapeFetcher: SourceFetching {

    let client: HTTPClient

    init(client: HTTPClient = HTTPClient()) {
        self.client = client
    }

    /// Link text shorter than this is navigation almost every time - "首页",
    /// "More", "登录", "About". Real headlines are longer in every language
    /// this app reads.
    static let minimumTitleLength = 12

    /// Site furniture that is long enough to pass the length test and points
    /// at a real page, so nothing else catches it. Matched against the WHOLE
    /// title so a genuine story about copyright law is not swept up with the
    /// "Copyright policy" link.
    static let furnitureTitles: Set<String> = [
        "copyright policy", "privacy policy", "terms & conditions", "terms of use",
        "cookie policy", "notes & corrections", "about us", "contact us",
        "all rights reserved", "advertise with us",
    ]

    func items(for source: SourceSnapshot) async throws -> [ParsedItem] {
        guard case .scrape(let homepage, _) = FetchRouter.route(source) else {
            throw FeedError.parseFailed("source is not routed to a scrape")
        }

        let data = try await client.get(homepage)
        try Task.checkCancellation()

        guard let html = Self.decode(data) else {
            throw FeedError.parseFailed("response was not decodable text")
        }

        let items = Self.headlines(in: html, pageURL: homepage)

        // A homepage that yields nothing is usually JavaScript-rendered or a
        // block page. Reporting it as an empty feed keeps it visible instead of
        // looking like a successful fetch of no news.
        guard !items.isEmpty else { throw FeedError.emptyFeed }
        return items
    }

    // MARK: - Decoding

    /// UTF-8 first, then GB18030, since several Chinese outlets still serve it.
    /// Latin-1 cannot fail, so it is the floor rather than a nil.
    nonisolated static func decode(_ data: Data) -> String? {
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        let gb = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )
        )
        if let chinese = String(data: data, encoding: gb) { return chinese }
        return String(data: data, encoding: .isoLatin1)
    }

    // MARK: - Extraction

    nonisolated static func headlines(in html: String, pageURL: URL) -> [ParsedItem] {
        let pattern = "<a\\s[^>]*href\\s*=\\s*[\"']([^\"']+)[\"'][^>]*>(.*?)</a>"
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return [] }

        let text = html as NSString
        var seen = Set<String>()
        var items: [ParsedItem] = []

        for match in regex.matches(in: html, range: NSRange(location: 0, length: text.length)) {
            guard match.numberOfRanges >= 3 else { continue }

            let href = text.substring(with: match.range(at: 1))
            let inner = text.substring(with: match.range(at: 2))

            guard let url = resolve(href, against: pageURL) else { continue }

            let title = visibleText(from: inner)
            guard title.count >= minimumTitleLength else { continue }

            // An unrendered template placeholder ("{{main_title}}") is not a
            // headline, and neither is an anchor whose destination is not
            // shaped like an article.
            guard !title.contains("{{"),
                  !furnitureTitles.contains(title.lowercased()),
                  looksLikeArticle(url) else { continue }

            guard seen.insert(dedupeKey(for: url)).inserted else { continue }

            items.append(ParsedItem(title: title, url: url, publishedAt: nil))
        }
        return items
    }

    /// Whether a destination is shaped like an article rather than a section.
    ///
    /// Link text alone is not enough: DIGITIMES labels its sections
    /// "Semiconductors", "Electric Vehicles", "Research Insights" - all long
    /// enough to pass the length test, and 87 of them swamp the real news.
    /// Their destinations give them away: /semiconductors, /opinions, /index.php.
    ///
    /// A destination qualifies if it ends in a document extension, carries a
    /// numeric id, or is a hyphenated slug. That admits the article shapes in
    /// use across these sources and rejects section and utility links. It is a
    /// trade-off: a site publishing extension-less single-word article URLs
    /// would yield nothing, which shows up as an empty-feed warning rather
    /// than as junk on screen.
    nonisolated static func looksLikeArticle(_ url: URL) -> Bool {
        let path = url.path().lowercased()
        guard !path.isEmpty, path != "/" else { return false }

        // An unrendered template reaches us percent-encoded, so check the
        // decoded form - /%7B%7Bid%7D%7D.html is /{{id}}.html.
        let decodedPath = path.removingPercentEncoding ?? path
        guard !decodedPath.contains("{{") else { return false }

        let components = path.split(separator: "/").map(String.init)

        // index.php and friends are section landing pages, not articles.
        if let last = components.last, last.hasPrefix("index.") { return false }

        let documentExtensions = [".html", ".htm", ".shtml", ".asp", ".jsp", ".php", ".cgi"]
        if documentExtensions.contains(where: { path.hasSuffix($0) }) { return true }
        if components.contains(where: { $0.count >= 4 && $0.allSatisfy(\.isNumber) }) { return true }

        // A slug: hyphenated and long enough not to be a section label.
        if let last = components.last, last.count >= 20, last.contains("-") { return true }

        return false
    }

    /// The key a headline is deduplicated on.
    ///
    /// Publishers link the same article from several places, often varying
    /// only a tracking query - DIGITIMES produced "China turns to 3D
    /// packaging..." twice, once with ?chid=10 and once without - so matching
    /// on the whole URL lists one story twice. Where the path alone identifies
    /// an article the query is decoration and is ignored; otherwise the whole
    /// URL is the key, because a site can carry the article id in the query
    /// alone (/index.php?id=1).
    nonisolated static func dedupeKey(for url: URL) -> String {
        guard looksLikeArticle(url) else { return url.absoluteString }
        return (url.host() ?? "") + url.path()
    }

    /// Resolves a link and keeps only same-host http(s) destinations. Off-site
    /// anchors are almost always ads, social buttons or wire syndication.
    nonisolated static func resolve(_ href: String, against pageURL: URL) -> URL? {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lowered = trimmed.lowercased()
        guard !lowered.hasPrefix("javascript:"),
              !lowered.hasPrefix("mailto:"),
              !lowered.hasPrefix("#"),
              !lowered.hasPrefix("data:") else { return nil }

        guard let url = URL(string: trimmed, relativeTo: pageURL)?.absoluteURL,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }

        func host(_ value: String?) -> String {
            (value ?? "").lowercased().replacingOccurrences(of: "www.", with: "")
        }
        guard host(url.host()) == host(pageURL.host()) else { return nil }

        return url
    }

    /// The link's visible text: tags stripped, entities decoded, whitespace
    /// collapsed. An image-only anchor therefore yields "" and is dropped.
    nonisolated static func visibleText(from markup: String) -> String {
        let stripped = markup.replacingOccurrences(
            of: "<[^>]+>", with: " ", options: .regularExpression
        )
        let decoded = decodeEntities(stripped)
        return decoded.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    nonisolated static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }

        let named = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'",
            "&#39;": "'", "&nbsp;": " ", "&hellip;": "…", "&mdash;": "—",
            "&ndash;": "–", "&rsquo;": "’", "&lsquo;": "‘", "&ldquo;": "“", "&rdquo;": "”",
        ]
        var out = text
        for (entity, replacement) in named {
            out = out.replacingOccurrences(of: entity, with: replacement)
        }

        // Numeric forms: &#8211; and &#x2013;
        for (pattern, radix) in [("&#([0-9]{1,7});", 10), ("&#[xX]([0-9A-Fa-f]{1,6});", 16)] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let source = out as NSString
            let matches = regex.matches(in: out, range: NSRange(location: 0, length: source.length))
            for match in matches.reversed() {
                guard match.numberOfRanges >= 2 else { continue }
                let digits = source.substring(with: match.range(at: 1))
                guard let value = UInt32(digits, radix: radix),
                      let scalar = Unicode.Scalar(value) else { continue }
                out = (out as NSString).replacingCharacters(
                    in: match.range, with: String(Character(scalar))
                )
            }
        }
        return out
    }
}

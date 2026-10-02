import Foundation

/// Transport and parse failures.
///
/// The http case keeps the status code rather than flattening to "request
/// failed", because the failure policy treats 403/429 and 5xx differently and
/// the UI reports the code to the user.
enum FeedError: Error, Sendable, Equatable {
    case http(Int)
    case timedOut
    case transport(String)
    case parseFailed(String)
    case emptyFeed

    /// Short, human-readable text for the source list.
    var shortDescription: String {
        switch self {
        case .http(let code): return "HTTP \(code)"
        case .timedOut: return "timed out"
        case .transport(let detail): return detail
        case .parseFailed(let detail): return detail
        case .emptyFeed: return "feed contained no items"
        }
    }
}

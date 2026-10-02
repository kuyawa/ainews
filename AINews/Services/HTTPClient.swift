import Foundation
import Synchronization

/// Caps redirect chains. State is guarded by a Mutex because the delegate is
/// called off the main actor and Swift 6 will not accept unguarded mutation.
private final class RedirectLimiter: NSObject, URLSessionTaskDelegate, Sendable {
    private let hops = Mutex<[Int: Int]>([:])
    private let limit: Int

    init(limit: Int = 3) { self.limit = limit }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        let count = hops.withLock { store -> Int in
            let next = (store[task.taskIdentifier] ?? 0) + 1
            store[task.taskIdentifier] = next
            return next
        }
        defer {
            if count >= limit { hops.withLock { $0[task.taskIdentifier] = nil } }
        }
        // Returning nil stops the redirect and hands back the 3xx response,
        // which surfaces as an HTTP error rather than a silently wrong page.
        return count > limit ? nil : request
    }
}

/// All outbound HTTP lives here.
///
/// Ephemeral by design: no cookie storage, no credential storage, no on-disk
/// cache. This app reads published feeds and should leave no trace on the
/// machine and present no persistent identity to publishers.
actor HTTPClient {
    static let defaultUserAgent =
        "AINews/1.0 (personal feed reader; +https://github.com/kuyawa/ainews)"

    private let session: URLSession

    init(userAgent: String = HTTPClient.defaultUserAgent) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = ["User-Agent": userAgent]
        self.session = URLSession(
            configuration: config,
            delegate: RedirectLimiter(limit: 3),
            delegateQueue: nil
        )
    }

    func get(_ url: URL) async throws -> Data {
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse else {
                throw FeedError.transport("non-HTTP response")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw FeedError.http(http.statusCode)
            }
            return data
        } catch let error as FeedError {
            throw error
        } catch let error as URLError {
            switch error.code {
            case .timedOut:
                throw FeedError.timedOut
            case .cancelled:
                throw CancellationError()
            default:
                throw FeedError.transport(error.localizedDescription)
            }
        }
    }
}

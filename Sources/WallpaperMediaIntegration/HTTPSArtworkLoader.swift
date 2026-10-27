import Foundation
import Security

/// Internal owned-fixture trust; production's public initializer never supplies it.
struct ArtworkTestTrust: Sendable {
    let anchorDER: Data
    let hostname: String
}

public struct HTTPSArtworkLoader: SystemMediaArtworkLoading {
    private let timeout: TimeInterval
    private let testTrust: ArtworkTestTrust?

    public init(timeout: TimeInterval = 15) {
        precondition(timeout.isFinite && timeout > 0)
        self.timeout = timeout; testTrust = nil
    }

    init(timeout: TimeInterval, testTrust: ArtworkTestTrust) {
        precondition(timeout.isFinite && timeout > 0)
        self.timeout = timeout; self.testTrust = testTrust
    }

    public func load(_ source: SystemMediaArtworkSource, for identity: SystemMediaArtworkIdentity) async throws -> SystemMediaArtwork {
        try Task.checkCancellation()
        let bytes: Data
        switch source {
        case .unavailable: throw SystemMediaError.noCurrentItem
        case .embedded(let data): bytes = data
        case .remote(let location): bytes = try await download(location)
        }
        // ImageIO decoding never blocks the main actor or metadata/transport queue.
        let decoding = Task.detached { try ArtworkImageDecoder.decode(bytes, for: identity) }
        return try await withTaskCancellationHandler {
            let artwork = try await decoding.value
            try Task.checkCancellation()
            return artwork
        } onCancel: { decoding.cancel() }
    }

    private func download(_ location: SystemMediaArtworkURL) async throws -> Data {
        let delegate = ArtworkRequestDelegate(testTrust: testTrust)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false; configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        var request = URLRequest(url: location.url)
        request.timeoutInterval = timeout
        let outcome: Result<Data, Error>
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            if let error = delegate.redirectFailure { throw error }
            guard let http = response as? HTTPURLResponse else {
                throw SystemMediaArtworkError.network(code: NSURLErrorBadServerResponse, message: "Response was not HTTP")
            }
            guard (200..<300).contains(http.statusCode) else { throw SystemMediaArtworkError.httpStatus(http.statusCode) }
            outcome = .success(data)
        } catch {
            if Task.isCancelled { outcome = .failure(CancellationError()) }
            else if let rejected = delegate.redirectFailure { outcome = .failure(rejected) }
            else if let artwork = error as? SystemMediaArtworkError { outcome = .failure(artwork) }
            else {
                let cause = error as NSError
                outcome = .failure(SystemMediaArtworkError.network(code: cause.code, message: cause.localizedDescription))
            }
        }
        session.invalidateAndCancel()
        await delegate.finishedInvalidating()
        return try outcome.get()
    }
}

private final class ArtworkRequestDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var failure: SystemMediaArtworkError?
    private var invalidated = false
    private var invalidationWaiter: CheckedContinuation<Void, Never>?
    private let testTrust: ArtworkTestTrust?

    init(testTrust: ArtworkTestTrust?) { self.testTrust = testTrust }
    var redirectFailure: SystemMediaArtworkError? { lock.lock(); defer { lock.unlock() }; return failure }

    func finishedInvalidating() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if invalidated { lock.unlock(); continuation.resume() }
            else { invalidationWaiter = continuation; lock.unlock() }
        }
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        lock.lock()
        invalidated = true
        let waiter = invalidationWaiter; invalidationWaiter = nil
        lock.unlock()
        waiter?.resume()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        do {
            guard let url = request.url else { throw SystemMediaArtworkError.invalidURL("Missing redirect URL") }
            _ = try SystemMediaArtworkURL(url.absoluteString)
            completionHandler(request)
        } catch let error as SystemMediaArtworkError {
            lock.lock(); failure = error; lock.unlock()
            completionHandler(nil)
        } catch {
            // URL validation has one typed failure; keep any unexpected failure observable.
            lock.lock(); failure = .invalidURL(String(describing: error)); lock.unlock()
            completionHandler(nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let testTrust else { completionHandler(.performDefaultHandling, nil); return }
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == testTrust.hostname,
              let trust = challenge.protectionSpace.serverTrust,
              let anchor = SecCertificateCreateWithData(nil, testTrust.anchorDER as CFData),
              SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, testTrust.hostname as CFString)) == errSecSuccess,
              SecTrustSetAnchorCertificates(trust, [anchor] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil) else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

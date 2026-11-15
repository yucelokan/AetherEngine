import Foundation
import Testing
@testable import AetherEngine

/// Auth challenge, Retry-After and proxy facts on source network events. Synthetic
/// responses only; no event may carry a URL, host, realm or header value from them.
/// Part of `SourceFailureDiagnosticsTests`, so the process-wide handler is never installed by two
/// suites at once.
extension SourceFailureDiagnosticsTests {
    private static let syntheticURL = URL(string: "https://origin.invalid/live/stream.m3u8")!

    private static func syntheticResponse(_ status: Int, _ headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: syntheticURL, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }

    private final class AuthFactsResponse: @unchecked Sendable {
        nonisolated(unsafe) var value: URLResponse?
    }

    private final class AuthFactsCollector: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let trace = SourceNetworkDiagnostics.Trace(role: .hlsPlaylist)
        nonisolated(unsafe) var onResponse: (@Sendable (URLResponse) -> Void)?
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            onResponse?(response)
            completionHandler(.allow)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
            trace.metrics(task: task, metrics: metrics)
        }
    }

    private final class AuthFactsEvents: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [SourceNetworkDiagnostics.Event] = []
        func add(_ event: SourceNetworkDiagnostics.Event) { lock.withLock { values.append(event) } }
        func snapshot() -> [SourceNetworkDiagnostics.Event] { lock.withLock { values } }
    }

    /// Runs one request against a loopback origin that answers with `status` and `headers`, through
    /// the real task delegate path, and returns the events the trace emitted for it.
    private func events(status: Int, headers: [String: String] = [:]) async throws -> [SourceNetworkDiagnostics.Event] {
        let server = try #require(ScriptedOriginServer { _ in
            .init(status: status, declaredLength: 0, close: true, extraHeaders: headers)
        })
        defer { server.stop() }
        let url = URL(string: "http://127.0.0.1:\(server.port)/live/stream.m3u8")!
        let events = AuthFactsEvents()
        let previous = SourceNetworkDiagnostics.handler
        SourceNetworkDiagnostics.handler = { if $0.originalURL == url { events.add($0) } }
        defer { SourceNetworkDiagnostics.handler = previous }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let collector = AuthFactsCollector()
        let session = URLSession(configuration: configuration, delegate: collector, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: url)
        let received = AuthFactsResponse()
        collector.onResponse = { response in received.value = response }
        task.resume()
        try await waitFor { events.snapshot().contains { $0.phase == .metrics } }
        // The same trace reports the response and the completion the way the readers' delegates do.
        collector.trace.response(task: task, response: try #require(received.value))
        collector.trace.completed(task: task, error: nil)
        return events.snapshot()
    }

    @Test("A 407 with Proxy-Authenticate reports a proxy challenge and its scheme only",
          .timeLimit(.minutes(3)))
    func proxyChallenge() async throws {
        let all = try await events(status: 407, headers: ["Proxy-Authenticate": "Basic realm=\"secret-realm\""])
        let response = try #require(all.first { $0.phase == .response })
        let metrics = try #require(all.first { $0.phase == .metrics })
        for event in [response, metrics] {
            #expect(event.status == 407)
            #expect(event.authChallenge == .proxy)
            #expect(event.authScheme == .basic)
        }
        #expect(response.proxyConnection == nil)
        #expect(metrics.proxyConnection == false)
    }

    @Test("A 407 without Proxy-Authenticate reports no challenge and no scheme",
          .timeLimit(.minutes(3)))
    func proxyRefusalWithoutChallenge() async throws {
        let all = try await events(status: 407)
        let response = try #require(all.first { $0.phase == .response })
        #expect(response.status == 407)
        #expect(response.authChallenge == .absent)
        #expect(response.authScheme == nil)
    }

    @Test("A 401 with WWW-Authenticate reports an origin challenge and the first scheme only", arguments: [
        ("Digest realm=\"r\", nonce=\"n\"", SourceNetworkDiagnostics.AuthScheme.digest),
        ("BEARER error=\"invalid_token\"", .bearer),
        ("Negotiate", .negotiate),
        ("NTLM", .ntlm),
        ("Basic realm=\"r\", Digest realm=\"r\"", .basic),
        ("Mutual realm=\"r\"", .other),
    ])
    func originChallenge(header: String, scheme: SourceNetworkDiagnostics.AuthScheme) {
        let found = SourceNetworkDiagnostics.authChallenge(of: Self.syntheticResponse(401, ["WWW-Authenticate": header]))
        #expect(found?.challenge == .www)
        #expect(found?.scheme == scheme)
    }

    @Test("A 403 counts, and the header that belongs to the status wins when both are present")
    func bothHeaders() {
        let both = ["WWW-Authenticate": "Digest realm=\"r\"", "Proxy-Authenticate": "NTLM"]
        #expect(SourceNetworkDiagnostics.authChallenge(of: Self.syntheticResponse(403, both))?.challenge == .www)
        #expect(SourceNetworkDiagnostics.authChallenge(of: Self.syntheticResponse(403, both))?.scheme == .digest)
        #expect(SourceNetworkDiagnostics.authChallenge(of: Self.syntheticResponse(407, both))?.challenge == .proxy)
        #expect(SourceNetworkDiagnostics.authChallenge(of: Self.syntheticResponse(407, both))?.scheme == .ntlm)
    }

    @Test("A status other than 401, 403 and 407 leaves the challenge fields nil, header or not",
          .timeLimit(.minutes(3)), arguments: [200, 206, 302, 404, 429, 503])
    func otherStatusLeavesFieldsNil(status: Int) async throws {
        let all = try await events(status: status, headers: ["WWW-Authenticate": "Basic realm=\"r\""])
        #expect(!all.isEmpty)
        for event in all {
            #expect(event.authChallenge == nil)
            #expect(event.authScheme == nil)
            #expect(event.retryAfterSeconds == nil)
        }
    }

    @Test("Retry-After is read as seconds and bounded like the playlist path")
    func retryAfterBounded() {
        func retryAfter(_ value: String?) -> TimeInterval? {
            SourceNetworkDiagnostics.retryAfterSeconds(of: Self.syntheticResponse(429, value.map { ["Retry-After": $0] } ?? [:]))
        }
        #expect(retryAfter("2") == 2)
        #expect(retryAfter("999999") == HLSLiveIngestReader.maximumRetryWait)
        #expect(retryAfter("-4") == 0)
        #expect(retryAfter("inf") == nil)
        #expect(retryAfter("nan") == nil)
        #expect(retryAfter("Wed, 21 Oct 2026 07:28:00 GMT") == nil)
        #expect(retryAfter(nil) == nil)
    }

    @Test("An oversized Retry-After reaches the event bounded", .timeLimit(.minutes(3)))
    func retryAfterOnEvent() async throws {
        let all = try await events(status: 503, headers: ["Retry-After": "86400"])
        let response = try #require(all.first { $0.phase == .response })
        #expect(response.retryAfterSeconds == HLSLiveIngestReader.maximumRetryWait)
        #expect(response.authChallenge == nil)
    }

    @Test("AuthFactsEvents never carry a realm, header value or other response text", .timeLimit(.minutes(3)))
    func eventHasNoHeaderValues() async throws {
        let realm = "secret-realm-\(UUID().uuidString)"
        let all = try await events(status: 401, headers: [
            "WWW-Authenticate": "Basic realm=\"\(realm)\"", "Retry-After": "3", "Server": "private-host.invalid"])
        for event in all {
            let text = String(reflecting: event)
            #expect(!text.contains(realm))
            #expect(!text.contains("private-host"))
            #expect(!text.contains("Basic"))
            #expect(!text.contains("WWW-Authenticate"))
        }
    }
}

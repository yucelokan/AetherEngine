import Foundation
import Testing
@testable import AetherEngine

/// A refused source request reports whether it carried an auth challenge, never the challenge's
/// own text (WUW-1129: a playback 407 was logged without its challenge).
@Suite("Source network auth challenge diagnostics", .serialized)
struct SourceNetworkAuthChallengeDiagnosticsTests {
    private typealias Facts = SourceNetworkDiagnostics.ResponseFacts
    private let url = URL(string: "http://example.invalid/stream.ts")!

    private func response(_ status: Int, _ headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }

    @Test("A 407 with Proxy-Authenticate reports a proxy challenge and its scheme")
    func proxyChallengePresent() {
        let facts = Facts(response(407, ["Proxy-Authenticate": "Basic realm=\"secret-proxy-realm\""]))
        #expect(facts.authChallenge == .present)
        #expect(facts.authChallengeHeader == .proxy)
        #expect(facts.authScheme == .basic)
    }

    @Test("A 407 without Proxy-Authenticate reports no challenge")
    func proxyChallengeMissing() {
        let facts = Facts(response(407))
        #expect(facts.authChallenge == SourceNetworkDiagnostics.AuthChallenge.none)
        #expect(facts.authChallengeHeader == nil)
        #expect(facts.authScheme == nil)
    }

    @Test("A 401 with WWW-Authenticate reports a www challenge and never the realm")
    func wwwChallengeDropsRealm() {
        let facts = Facts(response(401, ["WWW-Authenticate": "Basic realm=\"secret-realm\", charset=\"UTF-8\""]))
        #expect(facts.authChallenge == .present)
        #expect(facts.authChallengeHeader == .www)
        #expect(facts.authScheme == .basic)
        #expect(!String(describing: facts).contains("secret-realm"))
    }

    @Test("A 403 is a refusal too, and the scheme is the first token, lowercased")
    func forbiddenChallenge() {
        let facts = Facts(response(403, ["www-authenticate": "DIGEST realm=\"r\", nonce=\"n\", Basic realm=\"x\""]))
        #expect(facts.authChallenge == .present)
        #expect(facts.authScheme == .digest)
    }

    @Test("A 407 that carries only WWW-Authenticate still reports it as the www header")
    func otherHeaderFallback() {
        let facts = Facts(response(407, ["WWW-Authenticate": "Bearer"]))
        #expect(facts.authChallengeHeader == .www)
        #expect(facts.authScheme == .bearer)
    }

    @Test("A 200 carries no challenge fields, even when it names a challenge header",
          arguments: [200, 206, 302, 404, 429, 503])
    func otherStatusesCarryNone(status: Int) {
        let facts = Facts(response(status, ["WWW-Authenticate": "Basic realm=\"r\"",
                                            "Proxy-Authenticate": "Basic"]))
        #expect(facts.authChallenge == nil)
        #expect(facts.authChallengeHeader == nil)
        #expect(facts.authScheme == nil)
    }

    @Test("Scheme tokens map to the fixed set; an unknown or empty one is other",
          arguments: [("Negotiate abc", SourceNetworkDiagnostics.AuthScheme.negotiate),
                      ("NTLM", .ntlm), ("Bearer realm=x", .bearer), ("  Digest,realm=x", .digest),
                      ("Fancy-Scheme token", .other), ("", .other)])
    func schemeMapping(value: String, expected: SourceNetworkDiagnostics.AuthScheme) {
        #expect(Facts.scheme(value) == expected)
    }

    @Test("Retry-After is delta-seconds only, never negative and capped",
          arguments: [("5", 5), (" 30 ", 30), ("0", 0), ("999999", 3_600), ("-4", nil),
                      ("Wed, 21 Oct 2026 07:28:00 GMT", nil), ("nan", nil), ("inf", nil), ("", nil)])
    func retryAfterBounds(value: String, expected: Int?) {
        #expect(Facts.retryAfterSeconds(value) == expected)
    }

    @Test("A 503 with Retry-After reports the seconds and no challenge")
    func retryAfterOnThrottle() {
        let facts = Facts(response(503, ["Retry-After": "7"]))
        #expect(facts.retryAfterSeconds == 7)
        #expect(facts.authChallenge == nil)
    }

    @Test("No HTTP response means no facts")
    func noResponse() {
        #expect(Facts(nil) == Facts(response(200)))
    }
}

extension SourceFailureDiagnosticsTests {
    /// Replies with a scripted status and headers through a real URLSession task.
    private final class ScriptedChallengeResponse: URLProtocol, @unchecked Sendable {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let response = HTTPURLResponse(url: request.url!, statusCode: 407, httpVersion: "HTTP/1.1",
                headerFields: ["Proxy-Authenticate": "NTLM realm=\"secret-realm\"", "Retry-After": "12"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private final class ChallengeEvents: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [SourceNetworkDiagnostics.Event] = []
        func add(_ value: SourceNetworkDiagnostics.Event) { lock.withLock { values.append(value) } }
        func snapshot() -> [SourceNetworkDiagnostics.Event] { lock.withLock { values } }
    }

    // The handler is process-wide, so this runs inside the suite that already serializes handler users.
    @Test("The trace puts the facts on the real events of a refused task",
          .timeLimit(.minutes(1)))
    func traceCarriesFacts() async throws {
        let events = ChallengeEvents()
        let previous = SourceNetworkDiagnostics.handler
        let url = URL(string: "http://example.invalid/stream.ts")!
        let target = url
        SourceNetworkDiagnostics.handler = { event in
            guard event.originalURL == target else { return }
            events.add(event)
        }
        defer { SourceNetworkDiagnostics.handler = previous }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptedChallengeResponse.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let trace = SourceNetworkDiagnostics.Trace(role: .probe)
        let task = await withCheckedContinuation { (done: CheckedContinuation<URLSessionDataTask, Never>) in
            let box = ChallengeTaskBox()
            let task = session.dataTask(with: url) { _, _, _ in done.resume(returning: box.task!) }
            box.task = task
            task.resume()
        }
        trace.completed(task: task, error: nil)
        let completed = try #require(events.snapshot().last)
        #expect(completed.status == 407)
        #expect(completed.authChallenge == .present)
        #expect(completed.authChallengeHeader == .proxy)
        #expect(completed.authScheme == .ntlm)
        #expect(completed.retryAfterSeconds == 12)
        #expect(completed.proxyConnection == nil)
        #expect(!String(describing: completed).contains("secret-realm"))
    }

    private final class ChallengeTaskBox: @unchecked Sendable { var task: URLSessionDataTask? }
}

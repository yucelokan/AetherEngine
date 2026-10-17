import Foundation
import Testing
@testable import AetherEngine

@Suite("Source failure diagnostics", .serialized)
struct SourceFailureDiagnosticsTests {
    private final class CorrelationEvents: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [SourceNetworkDiagnostics.Event] = []
        func add(_ value: SourceNetworkDiagnostics.Event) { lock.withLock { values.append(value) } }
        func snapshot() -> [SourceNetworkDiagnostics.Event] { lock.withLock { values } }
    }

    @Test("A delayed old HLS request keeps its attempt after a retry and a different playback", .timeLimit(.minutes(1)))
    func delayedHLSRequestKeepsOriginalAttempt() async throws {
        let events = CorrelationEvents()
        let previous = SourceNetworkDiagnostics.handler
        SourceNetworkDiagnostics.handler = { events.add($0) }
        defer { SourceNetworkDiagnostics.handler = previous }
        let releaseOld = DispatchSemaphore(value: 0)
        let server = try #require(ScriptedOriginServer { request in
            // ScriptedOriginServer runs each reply on its own detached serving thread.
            if request.range == "bytes=0-0" { releaseOld.wait() }
            return .init(status: 200, declaredLength: 0)
        })
        defer { releaseOld.signal(); server.stop() }
        let session = URLSession(configuration: .ephemeral, delegate: EngineTLS.sessionDelegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let playbackID = UUID()
        let old = SourceNetworkDiagnostics.Context(playbackID: playbackID, attemptID: UUID())
        let retry = SourceNetworkDiagnostics.Context(playbackID: playbackID, attemptID: UUID())
        let replacement = SourceNetworkDiagnostics.Context(playbackID: UUID(), attemptID: UUID())
        let oldURL = URL(string: "http://127.0.0.1:\(server.port)/old.m3u8")!
        let retryURL = URL(string: "http://127.0.0.1:\(server.port)/retry.m3u8")!
        let replacementURL = URL(string: "http://127.0.0.1:\(server.port)/replacement.m3u8")!
        var originalRequest = URLRequest(url: oldURL)
        originalRequest.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let oldRequest = SourceNetworkDiagnostics.request(originalRequest, context: old)
        let oldFetch = Task {
            // The request was already created for the outgoing attempt. Even
            // a newer ambient context at fetch time must not replace its owner.
            try await SourceNetworkDiagnostics.$context.withValue(retry) {
                try await BoundedPlaylistFetch.data(for: oldRequest, session: session, limit: 1_024)
            }
        }
        defer { oldFetch.cancel() }
        try await waitFor { server.requests.contains { $0.range == "bytes=0-0" } }
        let retryRequest = SourceNetworkDiagnostics.request(URLRequest(url: retryURL), context: retry)
        _ = try await SourceNetworkDiagnostics.$context.withValue(replacement) {
            try await BoundedPlaylistFetch.data(for: retryRequest, session: session, limit: 1_024)
        }
        let replacementRequest = SourceNetworkDiagnostics.request(URLRequest(url: replacementURL), context: replacement)
        _ = try await BoundedPlaylistFetch.data(for: replacementRequest, session: session, limit: 1_024)
        #expect(!events.snapshot().contains { $0.originalURL == oldURL && $0.phase == "completed" })
        releaseOld.signal()
        let (_, oldResponse) = try await oldFetch.value
        #expect((oldResponse as? HTTPURLResponse)?.statusCode == 200)

        let completed = events.snapshot().filter { $0.phase == "completed" && $0.role == "HLSPlaylist" }
        #expect(completed.map(\.originalURL) == [retryURL, replacementURL, oldURL])
        #expect(Set(completed.map(\.requestID)).count == 3)
        for (url, expected) in [(oldURL, old), (retryURL, retry), (replacementURL, replacement)] {
            let requestEvents = events.snapshot().filter { $0.originalURL == url }
            #expect(requestEvents.contains { $0.phase == "response" })
            #expect(requestEvents.contains { $0.phase == "completed" })
            #expect(requestEvents.allSatisfy { $0.context == expected })
            #expect(Set(requestEvents.map(\.requestID)).count == 1)
        }
    }

    @Test("Playlist segment and key requests preserve the reader's original context and headers")
    func hlsRequestsKeepCapturedContextAndHeaders() throws {
        let original = SourceNetworkDiagnostics.Context(playbackID: UUID(), attemptID: UUID())
        let replacement = SourceNetworkDiagnostics.Context(playbackID: UUID(), attemptID: UUID())
        let baseURL = URL(string: "https://origin.example/live/main.m3u8")!
        let headers = ["Authorization": "Bearer private-fixture-token", "User-Agent": "fixture-agent"]
        let reader = SourceNetworkDiagnostics.$context.withValue(original) {
            HLSLiveIngestReader(playlistURL: baseURL, httpHeaders: headers)
        }
        defer { reader.close() }
        try SourceNetworkDiagnostics.$context.withValue(replacement) {
            let fresh = try #require(reader.makeFreshMainReader())
            defer { fresh.close() }
            for path in ["main.m3u8", "segment.ts", "encryption.key"] {
                let url = baseURL.deletingLastPathComponent().appendingPathComponent(path)
                for owner in [reader, fresh] {
                    let request = owner.makeRequest(url)
                    #expect(SourceNetworkDiagnostics.context(for: request) == original)
                    #expect(request.url == url)
                    #expect(request.httpMethod == "GET")
                    #expect(request.allHTTPHeaderFields?.count == headers.count)
                    for (name, value) in headers { #expect(request.value(forHTTPHeaderField: name) == value) }
                    #expect(request.value(forHTTPHeaderField: "playback_id") == nil)
                    #expect(request.value(forHTTPHeaderField: "attempt_id") == nil)
                }
            }
            let crossOrigin = reader.makeRequest(URL(string: "https://cdn.example/segment.ts")!)
            #expect(SourceNetworkDiagnostics.context(for: crossOrigin) == original)
            #expect(crossOrigin.value(forHTTPHeaderField: "Authorization") == nil)
        }
    }

    @Test("Trace captures once and an unbound request cannot borrow an ambient playback")
    func tracesFreezeContextAndKeepUnboundRequestsUnattributed() throws {
        let events = CorrelationEvents()
        let previous = SourceNetworkDiagnostics.handler
        SourceNetworkDiagnostics.handler = { events.add($0) }
        defer { SourceNetworkDiagnostics.handler = previous }
        let original = SourceNetworkDiagnostics.Context(playbackID: UUID(), attemptID: UUID())
        let replacement = SourceNetworkDiagnostics.Context(playbackID: UUID(), attemptID: UUID())
        let url = URL(string: "https://origin.example/segment.ts")!
        let trace = SourceNetworkDiagnostics.$context.withValue(original) {
            SourceNetworkDiagnostics.Trace(role: "HLSSegment")
        }
        let tagged = SourceNetworkDiagnostics.request(URLRequest(url: url), context: original)
        let unbound = SourceNetworkDiagnostics.request(tagged, context: nil)
        #expect(SourceNetworkDiagnostics.context(for: tagged) == original)
        #expect(SourceNetworkDiagnostics.context(for: unbound) == nil)
        SourceNetworkDiagnostics.$context.withValue(replacement) {
            trace.record("response", originalURL: url, url: url, status: 200)
            trace.record("completed", originalURL: url, url: url, status: 200)
            let unboundTrace = SourceNetworkDiagnostics.Trace(role: "HLSKey",
                context: SourceNetworkDiagnostics.context(for: unbound))
            unboundTrace.record("completed", originalURL: url, url: url, status: 200)
        }
        let captured = events.snapshot()
        #expect(captured.count == 3)
        #expect(captured[0].context == original && captured[1].context == original)
        #expect(captured[0].requestID == captured[1].requestID)
        #expect(captured[2].context == nil)
        #expect(captured[2].requestID != captured[0].requestID)
    }

    @Test("A segment carriage probe completes once with its captured context", .timeLimit(.minutes(1)), arguments: [200, 403])
    func carriageProbeCompletesWithCapturedContext(status: Int) async throws {
        let events = CorrelationEvents()
        let previous = SourceNetworkDiagnostics.handler
        SourceNetworkDiagnostics.handler = { events.add($0) }
        defer { SourceNetworkDiagnostics.handler = previous }
        let body = Data([0, 1, 2, 3])
        let server = try #require(ScriptedOriginServer { _ in
            .init(status: status, declaredLength: Int64(body.count), close: true, body: body)
        })
        defer { server.stop() }
        let session = URLSession(configuration: .ephemeral, delegate: EngineTLS.sessionDelegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let original = SourceNetworkDiagnostics.Context(playbackID: UUID(), attemptID: UUID())
        let replacement = SourceNetworkDiagnostics.Context(playbackID: UUID(), attemptID: UUID())
        let url = URL(string: "http://127.0.0.1:\(server.port)/head.ts")!
        do {
            _ = try await SourceNetworkDiagnostics.$context.withValue(replacement) {
                try await HLSCarriageProbe.classifySegmentHead(
                    url: url, httpHeaders: [:], session: session, diagnosticContext: original)
            }
            #expect(status == 200)
        } catch {
            #expect(error as? HLSIngestError == .playlistUnreachable(status: status))
            #expect(status == 403)
        }
        let captured = events.snapshot().filter { $0.originalURL == url }
        #expect(captured.filter { $0.phase == "response" }.count == 1)
        #expect(captured.filter { $0.phase == "completed" }.count == 1)
        #expect(captured.allSatisfy { $0.context == original && $0.role == "HLSSegment" && $0.status == status })
        #expect(Set(captured.map(\.requestID)).count == 1)
    }

    @Test("Bounded HLS requests report real HTTP refusals without synthetic cancellation")
    func boundedResponseEvidence() async throws {
        final class Events: @unchecked Sendable {
            let lock = NSLock()
            var values: [SourceNetworkDiagnostics.Event] = []
            func add(_ value: SourceNetworkDiagnostics.Event) { lock.withLock { values.append(value) } }
            func snapshot() -> [SourceNetworkDiagnostics.Event] { lock.withLock { values } }
        }
        let events = Events()
        let previous = SourceNetworkDiagnostics.handler
        SourceNetworkDiagnostics.handler = { events.add($0) }
        defer { SourceNetworkDiagnostics.handler = previous }
        let server = try #require(ScriptedOriginServer { _ in .init(status: 403, declaredLength: 0) })
        defer { server.stop() }
        let session = URLSession(configuration: .ephemeral, delegate: EngineTLS.sessionDelegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let url = URL(string: "http://127.0.0.1:\(server.port)/private.m3u8")!
        let (_, response) = try await BoundedPlaylistFetch.data(for: URLRequest(url: url), session: session, limit: 1024)
        #expect((response as? HTTPURLResponse)?.statusCode == 403)
        let terminal = try #require(events.snapshot().first {
            $0.originalURL == url && $0.phase == "completed" && $0.role == "HLSPlaylist"
        })
        #expect(terminal.status == 403)
        #expect(terminal.urlErrorCode == nil)
    }

    @Test("Real source response events retain status and origin")
    func responseEvidence() throws {
        final class Events: @unchecked Sendable {
            let lock = NSLock()
            var values: [SourceNetworkDiagnostics.Event] = []
            func add(_ value: SourceNetworkDiagnostics.Event) { lock.lock(); values.append(value); lock.unlock() }
        }
        let events = Events()
        let previous = SourceNetworkDiagnostics.handler
        SourceNetworkDiagnostics.handler = { events.add($0) }
        defer { SourceNetworkDiagnostics.handler = previous }
        let server = try #require(ScriptedOriginServer { _ in .init(status: 403, declaredLength: 0) })
        defer { server.stop() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/live/test.ts")!, isLive: true)
        defer { reader.markClosed(); reader.close() }
        #expect(throws: AVIOReaderError.httpStatus(403)) { try reader.open() }
        events.lock.lock()
        let values = events.values
        events.lock.unlock()
        let response = try #require(values.first { $0.phase == "response" && $0.status == 403 && $0.originalURL?.port == Int(server.port) && $0.role == "PersistentRead" })
        #expect(response.originalURL?.port == Int(server.port))
        #expect(response.url?.host == "127.0.0.1")
        #expect(response.urlErrorCode == nil)
        #expect(response.role == "PersistentRead")
    }

    @MainActor
    @Test("Live initial probe preserves HTTP refusal, including uppercase HTTP", arguments: [401, 403, 404, 429, 503])
    func liveProbePreservesRefusal(status: Int) async throws {
        let server = try #require(ScriptedOriginServer { _ in
            .init(status: status, declaredLength: 0)
        })
        defer { server.stop() }
        let engine = try AetherEngine()
        defer { engine.stop() }
        var options = LoadOptions()
        options.isLive = true
        let url = URL(string: "HTTP://127.0.0.1:\(server.port)/live/test.ts")!
        do {
            _ = try await engine.load(url: url, options: options)
            Issue.record("A refused source must fail")
        } catch {
            #expect(engine.errorInfo?.underlyingCode == status)
            #expect(engine.errorInfo?.kind == (AVIOReader.isRateLimitStatus(status) ? .sourceRateLimited : .sourceRefused))
            #expect(!server.requests.isEmpty, "Uppercase HTTP must use the HTTP reader")
        }
    }

    @Test("URL errors survive wrappers without reading localized messages")
    func nestedTransportCode() {
        for code in [-1001, -1003, -1004, -1006, -1009, -1202, -999] {
            let error = NSError(domain: "Wrapper", code: 7, userInfo: [NSUnderlyingErrorKey: URLError(URLError.Code(rawValue: code))])
            #expect(SourceNetworkDiagnostics.urlErrorCode(error) == code)
        }
        #expect(SourceNetworkDiagnostics.urlErrorCode(NSError(domain: "private.example", code: -1003)) == nil)
    }

    @Test("NSError carries the actual FFmpeg failure rather than its Swift enum ordinal")
    func demuxCodeSurvivesBridge() {
        for code: Int32 in [-1094995529, -1128613112, -1296385272, -5] {
            let error = DemuxerError.openFailed(code: code) as NSError
            #expect(error.domain == "AetherEngine.DemuxerError")
            #expect(error.code == Int(code))
        }
    }

    @MainActor
    @Test("Live initial connection failure keeps the URL error instead of generic live unavailable")
    func liveConnectionFailure() async throws {
        let server = try #require(ScriptedOriginServer { _ in .init(status: 200, declaredLength: 0) })
        let url = URL(string: "http://127.0.0.1:\(server.port)/live/test.ts")!
        server.stop()
        let engine = try AetherEngine()
        defer { engine.stop() }
        var options = LoadOptions()
        options.isLive = true
        do {
            _ = try await engine.load(url: url, options: options)
            Issue.record("Closed source must fail")
        } catch {
            #expect(engine.errorInfo?.kind == .sourceOpenFailed)
            #expect(engine.errorInfo?.underlyingDomain == NSURLErrorDomain)
            #expect(engine.errorInfo?.underlyingCode == NSURLErrorCannotConnectToHost)
        }
    }
}

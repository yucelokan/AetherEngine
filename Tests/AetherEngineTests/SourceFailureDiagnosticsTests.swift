import Foundation
import Testing
@testable import AetherEngine

@Suite("Source failure diagnostics", .serialized)
struct SourceFailureDiagnosticsTests {
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

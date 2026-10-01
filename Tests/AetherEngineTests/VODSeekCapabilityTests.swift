import Foundation
import Combine
import Testing
@testable import AetherEngine

@MainActor
struct VODSeekCapabilityTests {
    @Test("A known duration never makes a forward-only source seekable")
    func rejectsForwardOnlySeek() async throws {
        let engine = try AetherEngine()
        engine.state = .playing
        engine.isSessionReady = true
        engine.duration = 493.6
        engine.isSourceSeekable = false
        engine.clock.currentTime = 14.99
        engine.clock.sourceTime = 4.99 // sequential source PTS can differ from display time
        var events: [SeekEvent] = []
        let sub = engine.seekEvents.sink { events.append($0) }
        defer { sub.cancel(); engine.stop() }
        #expect(!engine.canSeek)
        await engine.seek(to: 271.7)
        #expect(events.map(\.outcome) == [.rejected(.sourceNotSeekable)])
        #expect(engine.currentTime == 14.99)
        #expect(engine.state == .playing)
        #expect(!engine.isSeeking)
    }

    @Test("Seekability belongs to this load and clears at stop")
    func capabilityLifecycle() throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        engine.duration = 493.6
        engine.isSessionReady = true
        engine.state = .playing
        #expect(!engine.canSeek)
        engine.isSourceSeekable = true
        #expect(engine.canSeek)
        engine.isSourceSeekable = false
        #expect(!engine.canSeek)
        engine.stop()
        #expect(engine.isSourceSeekable == nil)
        #expect(!engine.canSeek)
    }

    @Test("Native seek completion requires success and an actual landing")
    func completionValidation() {
        #expect(!NativeAVPlayerHost.seekCompletionReachedTarget(finished: true, actual: 14.99, target: 271.7))
        #expect(!NativeAVPlayerHost.seekCompletionReachedTarget(finished: false, actual: 271.7, target: 271.7))
        #expect(!NativeAVPlayerHost.seekCompletionReachedTarget(finished: true, actual: 271.7, target: 14.99))
        #expect(!NativeAVPlayerHost.seekCompletionReachedTarget(finished: true, actual: .nan, target: 14.99))
        #expect(NativeAVPlayerHost.seekCompletionReachedTarget(finished: true, actual: 271.72, target: 271.7))
        #expect(NativeAVPlayerHost.seekCompletionReachedTarget(finished: true, actual: 14.99, target: 15))
    }
    @Test("A deferred seek drops its optimistic clock when the source proves forward-only")
    func deferredSeekRejectedAfterProbe() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        engine.duration = 493.6
        engine.state = .loading
        engine.clock.sourceTime = 5
        await engine.seek(to: 271.7)
        #expect(engine.isSeeking)
        engine.isSourceSeekable = false
        engine.state = .playing
        let settled = try await waitFor(upTo: .seconds(1)) { !engine.isSeeking }
        #expect(settled)
        #expect(engine.currentTime == 5)
    }

    @Test("An exhausted opening budget stays a transport failure and is not repeated by routing")
    func exhaustedOpenDoesNotReprobe() async throws {
        let gate = ProbeTestGate()
        let origin = try ProbeHTTPTestOrigin(data: Data(repeating: 0, count: 8192),
            response: { _, _ in gate.wait(); return nil })
        let engine = try AetherEngine()
        defer { engine.stop(); gate.open(); origin.stop() }
        var options = LoadOptions(sourceOpenPolicy: .init(firstByteTimeout: 0.15, sizeProbeTimeout: 0.25))
        options.maxConcurrentSourceRequests = 1
        options.suppressDisplayCriteria = true
        let started = ContinuousClock.now
        do {
            try await engine.load(url: URL(string: "http://127.0.0.1:\(origin.port)/media.mkv")!, options: options)
            Issue.record("an unanswered source must not load successfully")
        } catch {
            #expect(error as? AVIOReaderError == .requestTimeout)
        }
        #expect(started.duration(to: .now) < .seconds(2))
        #expect(origin.requests.count == 2)
        #expect(engine.errorInfo?.kind == .sourceOpenFailed)
        #expect(engine.errorInfo?.underlyingDomain == NSURLErrorDomain)
        #expect(engine.errorInfo?.underlyingCode == URLError.timedOut.rawValue)
        #expect(!engine.canSeek)
    }

}

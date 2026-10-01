import Foundation
import Testing
@testable import AetherEngine

@Suite(.timeLimit(.minutes(2)))
struct SourceOpenRecoveryTests {
    private let bytes = Data(repeating: 0x47, count: 8192)

    private func url(_ origin: ProbeHTTPTestOrigin) -> URL {
        URL(string: "http://127.0.0.1:\(origin.port)/media.bin")!
    }

    private func readPrefix(_ reader: AVIOReader) -> Data {
        var data = Data(count: 16)
        let count = data.withUnsafeMutableBytes {
            reader.read(into: $0.baseAddress!.assumingMemoryBound(to: UInt8.self), size: 16)
        }
        return count > 0 ? data.prefix(Int(count)) : Data()
    }

    @Test("A silent initial request reaches the alternate request shape within the host budget")
    func coldRequestRecovery() async throws {
        let origin = try ProbeHTTPTestOrigin(data: bytes, stage: .headers)
        let source = url(origin)
        OriginRequestBudget.shared.setHostLimit(1, for: source)
        let reader = AVIOReader(url: source, boundedInitialFetch: 4096,
            sourceOpenPolicy: .init(firstByteTimeout: 0.2, sizeProbeTimeout: 2))
        defer { reader.markClosed(); reader.close(); origin.stop() }
        let started = ContinuousClock.now
        let job = ProbeTestJob { try reader.open() }
        try await waitFor { origin.blocked.entered }
        try await job.outcome().get()
        #expect(started.duration(to: .now) < .seconds(3), "must not pay the old 15-second wait")
        #expect(reader.isSeekable)
        #expect(readPrefix(reader) == bytes.prefix(16))
        #expect(OriginRequestBudget.shared.snapshot(for: source)?.peakInflight == 1)
        #expect(origin.requests.map(\.method).allSatisfy { $0 == "GET" })
        #expect(origin.requests.contains { $0.range == "bytes=0-" })
        #expect(origin.requests.count == 2, "the recovered data connection must be retained, not reprobed")
        #expect(origin.failure == nil)
    }

    @Test("A single-request origin tries Range, HEAD and bounded Range without a speculative fan")
    func serialFallbacks() throws {
        let origin = try ProbeHTTPTestOrigin(data: bytes, response: { request, index in
            guard index < 2 else { return nil }
            let status = request.method == "HEAD" ? 403 : 405
            return Data("HTTP/1.1 \(status) Refused\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        })
        let source = url(origin)
        OriginRequestBudget.shared.setHostLimit(1, for: source)
        let reader = AVIOReader(url: source, prefetchEnabled: false,
            sourceOpenPolicy: .init(firstByteTimeout: 1, sizeProbeTimeout: 3))
        defer { reader.markClosed(); reader.close(); origin.stop() }
        try reader.open()
        #expect(reader.isSeekable)
        #expect(readPrefix(reader) == bytes.prefix(16))
        #expect(Array(origin.requests.prefix(3).map(\.method)) == ["GET", "HEAD", "GET"])
        #expect(Array(origin.requests.prefix(3).map(\.range)) == ["bytes=0-", nil, "bytes=0-1"])
        #expect(OriginRequestBudget.shared.snapshot(for: source)?.peakInflight == 1)
        #expect(OriginRequestBudget.shared.snapshot(for: source)?.inflight == 0)
        #expect(origin.failure == nil)
    }

    @Test("A held connection whose headers resolved the size survives a delayed body")
    func slowBodyKeepsConnection() async throws {
        let origin = try ProbeHTTPTestOrigin(data: bytes, stage: .body, stallOpenEndedBody: true)
        let source = url(origin)
        OriginRequestBudget.shared.setHostLimit(1, for: source)
        // The held transport exposes the response head before any body byte. URLSession can
        // coalesce them, which would exercise the unknown-size fallback instead of this branch.
        let reader = AVIOReader(url: source, boundedInitialFetch: 4096, heldConnection: true,
            sourceOpenPolicy: .init(firstByteTimeout: 0.2, sizeProbeTimeout: 2))
        defer { reader.markClosed(); reader.close(); origin.stop() }
        let job = ProbeTestJob { try reader.open() }
        try await waitFor { origin.blocked.entered }
        try await job.outcome().get()
        #expect(reader.isSeekable)
        #expect(origin.requests.count == 1, "a slow body must not cause a redundant size probe")
        origin.blocked.open()
        #expect(readPrefix(reader) == bytes.prefix(16))
        #expect(origin.requests.count == 1)
    }

    @Test("Silent serial fallbacks share one deadline before forward-only playback")
    func sharedProbeDeadline() async throws {
        let gate = ProbeTestGate()
        let origin = try ProbeHTTPTestOrigin(data: bytes, response: { request, _ in
            if request.range == "bytes=0-" || request.range == "bytes=0-1" || request.method == "HEAD" {
                gate.wait()
            }
            return nil
        })
        let source = url(origin)
        OriginRequestBudget.shared.setHostLimit(1, for: source)
        let reader = AVIOReader(url: source, prefetchEnabled: false,
            sourceOpenPolicy: .init(firstByteTimeout: 1, sizeProbeTimeout: 0.45))
        defer { reader.markClosed(); reader.close(); gate.open(); origin.stop() }
        let started = ContinuousClock.now
        let job = ProbeTestJob { try reader.open() }
        try await job.outcome().get()
        #expect(started.duration(to: .now) < .seconds(2), "the timeout must not multiply per fallback")
        #expect(!reader.isSeekable, "without a size, playback must not advertise byte seeking")
        #expect(readPrefix(reader) == bytes.prefix(16))
        #expect(OriginRequestBudget.shared.snapshot(for: source)?.inflight == 0)
    }

    @Test("A winning size probe cancels and joins its slow siblings before data fetch")
    func winningProbeReleasesSiblings() async throws {
        let gate = ProbeTestGate()
        let origin = try ProbeHTTPTestOrigin(data: bytes, response: { request, _ in
            if request.range == "bytes=0-" || request.range == "bytes=0-1" { gate.wait() }
            return nil
        })
        let source = url(origin)
        let reader = AVIOReader(url: source, prefetchEnabled: false,
            sourceOpenPolicy: .init(firstByteTimeout: 1, sizeProbeTimeout: 10))
        defer { reader.markClosed(); reader.close(); gate.open(); origin.stop() }
        let job = ProbeTestJob { try reader.open() }
        try await waitFor { gate.entered }
        try await job.outcome().get()
        #expect(!gate.isOpen, "the winner must not wait for the losing origin to respond")
        #expect(OriginRequestBudget.shared.snapshot(for: source)?.inflight == 0,
                "no losing probe may retain a ticket after open")
        #expect(reader.isSeekable)
        #expect(readPrefix(reader) == bytes.prefix(16))
    }

    @Test("Teardown cancels a metadata request waiting for the origin slot")
    func cancellationWhileWaitingForSlot() async throws {
        let origin = try ProbeHTTPTestOrigin(data: bytes)
        let source = url(origin)
        OriginRequestBudget.shared.setHostLimit(1, for: source)
        let ticket = OriginRequestBudget.shared.acquire(for: source, label: "test-holder", timeout: 1)
        let reader = AVIOReader(url: source, prefetchEnabled: false,
            sourceOpenPolicy: .init(firstByteTimeout: 1, sizeProbeTimeout: 30))
        defer { reader.close(); OriginRequestBudget.shared.release(ticket); origin.stop() }
        let job = ProbeTestJob { try reader.open() }
        try await waitFor { OriginRequestBudget.shared.snapshot(for: source)?.waiting == 1 }
        let started = ContinuousClock.now
        reader.markClosed()
        let result = try await job.outcome()
        #expect(started.duration(to: .now) < .seconds(1))
        if case .success = result { Issue.record("cancelled open must not succeed") }
        #expect(origin.requests.isEmpty)
        #expect(OriginRequestBudget.shared.snapshot(for: source)?.inflight == 1)
        #expect(OriginRequestBudget.shared.snapshot(for: source)?.waiting == 0)
    }
    @Test("Unanswered opens fail within their budgets without inventing a forward-only source")
    func unansweredOpenDoesNotBecomeSequential() async throws {
        let gate = ProbeTestGate()
        let origin = try ProbeHTTPTestOrigin(data: bytes, response: { _, _ in gate.wait(); return nil })
        let source = url(origin)
        OriginRequestBudget.shared.setHostLimit(1, for: source)
        let reader = AVIOReader(url: source,
            sourceOpenPolicy: .init(firstByteTimeout: 0.15, sizeProbeTimeout: 0.25))
        defer { reader.markClosed(); reader.close(); gate.open(); origin.stop() }
        let started = ContinuousClock.now
        let job = ProbeTestJob { try reader.open() }
        let result = try await job.outcome()
        if case .failure(let error) = result {
            #expect(error as? AVIOReaderError == .requestTimeout)
        } else { Issue.record("no response is not a successful sequential open") }
        #expect(started.duration(to: .now) < .seconds(2))
        #expect(origin.requests.count == 2)
        #expect(origin.requests.allSatisfy { $0.method == "GET" && $0.range != nil })
        #expect(OriginRequestBudget.shared.snapshot(for: source)?.inflight == 0)
    }

    @Test("Cancelling the alternate data open releases the origin slot promptly")
    func cancelDataRetry() async throws {
        let gate = ProbeTestGate()
        let origin = try ProbeHTTPTestOrigin(data: bytes, response: { _, _ in gate.wait(); return nil })
        let source = url(origin)
        OriginRequestBudget.shared.setHostLimit(1, for: source)
        let reader = AVIOReader(url: source,
            sourceOpenPolicy: .init(firstByteTimeout: 0.15, sizeProbeTimeout: 30))
        defer { reader.close(); gate.open(); origin.stop() }
        let job = ProbeTestJob { try reader.open() }
        try await waitFor { origin.requests.count == 2 }
        let started = ContinuousClock.now
        reader.markClosed()
        let result = try await job.outcome()
        if case .failure(let error) = result { #expect(error is CancellationError) }
        else { Issue.record("cancelled data retry must not open") }
        #expect(started.duration(to: .now) < .seconds(1))
        #expect(OriginRequestBudget.shared.snapshot(for: source)?.inflight == 0)
    }

    @Test("A truncated 206 body recovers without losing or duplicating bytes")
    func truncatedBodyRecovers() async throws {
        let content = Data((0..<8192).map { UInt8($0 % 251) })
        let origin = try ProbeHTTPTestOrigin(data: content, response: { _, index in
            guard index == 0 else { return nil }
            return Data("HTTP/1.1 206 Partial Content\r\nContent-Length: 8192\r\nContent-Range: bytes 0-8191/8192\r\nConnection: close\r\n\r\n".utf8) + content.prefix(2048)
        })
        let source = url(origin)
        OriginRequestBudget.shared.setHostLimit(1, for: source)
        let reader = AVIOReader(url: source, sourceOpenPolicy: .init(firstByteTimeout: 1, sizeProbeTimeout: 1))
        defer { reader.markClosed(); reader.close(); origin.stop() }
        let received = ProbeTestBox(Data())
        let job = ProbeTestJob {
            try reader.open()
            var result = Data()
            var chunk = [UInt8](repeating: 0, count: 1024)
            while result.count < content.count {
                let count = chunk.withUnsafeMutableBufferPointer { reader.read(into: $0.baseAddress!, size: 1024) }
                guard count > 0 else { break }
                result.append(contentsOf: chunk.prefix(Int(count)))
            }
            received.update { $0 = result }
        }
        try await job.outcome().get()
        #expect(received.value == content)
        #expect(reader.isSeekable)
        // URLSession may discard a short body before delivering any data callback. In that
        // case byte zero is the unread frontier; otherwise the delivered prefix is retained.
        #expect(origin.requests.count >= 2)
        let retries = origin.requests.dropFirst().compactMap { $0.range }
        #expect(!retries.isEmpty)
        #expect(retries.allSatisfy { $0.hasPrefix("bytes=0-") || $0.hasPrefix("bytes=2048-") })
        #expect(OriginRequestBudget.shared.snapshot(for: source)?.peakInflight == 1)
    }

}

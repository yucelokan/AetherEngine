import Testing
import Foundation
@testable import AetherEngine

/// The spatial bridge encodes on `APACEncodePipeline`'s queue while it decodes the next chunk
/// (#731). Every chunk the producer rendered must reach the encoder intact and in order, and what
/// reaches the muxer must be the packets the encoder returned, in the same order, on the same
/// timestamps, through restarts, resets and failures.
///
/// The reference is the real encoder seen from inside the pipeline (`RecordingAPACEncoder`), not a
/// second encode on the test thread: Apple's APAC encoder is not byte-reproducible across threads
/// (macOS 27.0.1 returns one of two streams for the same input, 851,362 or 851,540 bytes for the 40
/// chunks below, depending on the thread and the process's history).
@Suite("APAC encode pipeline", .offCooperativePoolOneLane)
struct APACEncodePipelineTests {

    private static let layout = SpatialSpeakerLayout.l714
    private static let chunk = 2048

    @available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *)
    private func makeEncoder() throws -> APACEncoder {
        try APACEncoder(layout: Self.layout, bitRate: Self.layout.channelCount * 320_000)
    }

    /// A different tone per channel, continuous across chunks.
    private func fill(_ planes: [UnsafeMutablePointer<Float>], frames: Int, startFrame: Int) {
        for (c, p) in planes.enumerated() {
            for i in 0..<frames {
                p[i] = 0.1 * sin(Float(startFrame + i) * 2 * .pi * Float(200 + 50 * c) / 48_000)
            }
        }
    }

    @available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *)
    private func submit(
        _ pipeline: APACEncodePipeline, _ buffer: inout APACEncodePipeline.PlaneBuffer,
        chunks: Range<Int>, origin: Int64
    ) {
        for k in chunks {
            fill(buffer.planes, frames: Self.chunk, startFrame: k * Self.chunk)
            buffer = pipeline.submit(buffer, frames: Self.chunk, position: origin + Int64(k * Self.chunk))
        }
    }

    @Test("the encoder gets every chunk as rendered, and the packets are its own, in order, stamped from the first chunk's position")
    func passesChunksAndPacketsThroughExactly() throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        // What the producer renders, kept apart from the pool, whose buffers are reused.
        let scratch = (0..<Self.layout.channelCount).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: Self.chunk) }
        defer { scratch.forEach { $0.deallocate() } }
        let rendered: [[[UInt32]]] = (0..<40).map { k in
            fill(scratch, frames: Self.chunk, startFrame: k * Self.chunk)
            return scratch.map { UnsafeBufferPointer(start: $0, count: Self.chunk).map(\.bitPattern) }
        }

        let real = try makeEncoder()
        let encoder = RecordingAPACEncoder(real)
        let pipeline = APACEncodePipeline(encoder: encoder, channels: Self.layout.channelCount,
                                          bufferFrames: Self.chunk)
        #expect(pipeline.leadingFrames == real.leadingFrames)
        #expect(pipeline.magicCookie == real.magicCookie)
        var buffer = pipeline.takeInitialBuffer()
        var got: [APACEncodePipeline.StampedPacket] = []
        var errors: [Error] = []
        for k in 0..<40 {
            submit(pipeline, &buffer, chunks: k..<(k + 1), origin: 96_000)
            let out = pipeline.collect()
            got += out.packets
            errors += out.errors
        }
        let finished = pipeline.finish()
        got += finished.packets
        errors += finished.errors
        #expect(errors.isEmpty)

        #expect(encoder.calls == Array(repeating: .encode, count: 40) + [.flush])
        let inputs = encoder.inputs
        try #require(inputs.count == rendered.count)
        let altered = inputs.indices.filter { inputs[$0] != rendered[$0] }
        #expect(altered.isEmpty, "chunks that reached the encoder differing from what was rendered: \(altered)")

        let returned = encoder.packets
        try #require(!returned.isEmpty)
        #expect(got.count == returned.count)
        #expect(got.map(\.data) == returned.map(\.data))
        #expect(got.map(\.isSync) == returned.map(\.isSync))
        #expect(got.map(\.pts) == got.indices.map { 96_000 + Int64($0) * 1024 })
    }

    @Test("a reset drops what was queued, and the next chunk starts a run on its own position")
    func resetDropsQueuedWork() throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let pipeline = APACEncodePipeline(encoder: try makeEncoder(), channels: Self.layout.channelCount,
                                          bufferFrames: Self.chunk)
        var buffer = pipeline.takeInitialBuffer()
        submit(pipeline, &buffer, chunks: 0..<20, origin: 0)
        pipeline.reset()
        submit(pipeline, &buffer, chunks: 0..<10, origin: 480_000)
        let out = pipeline.finish()

        let fresh = APACEncodePipeline(encoder: try makeEncoder(), channels: Self.layout.channelCount,
                                       bufferFrames: Self.chunk)
        var freshBuffer = fresh.takeInitialBuffer()
        submit(fresh, &freshBuffer, chunks: 0..<10, origin: 480_000)
        #expect(out.packets.map(\.data) == fresh.finish().packets.map(\.data), "the encoder really started over")
        #expect(out.errors.isEmpty)
        #expect(out.packets.first?.pts == 480_000, "nothing from before the reset survives")
        #expect(out.packets.map(\.pts) == out.packets.indices.map { 480_000 + Int64($0) * 1024 })
    }

    @Test("a restart ends the run with its tail, and the next run starts on the next chunk's position")
    func restartStartsANewRun() throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let pipeline = APACEncodePipeline(encoder: try makeEncoder(), channels: Self.layout.channelCount,
                                          bufferFrames: Self.chunk)
        var buffer = pipeline.takeInitialBuffer()
        submit(pipeline, &buffer, chunks: 0..<10, origin: 0)
        pipeline.restart()
        submit(pipeline, &buffer, chunks: 0..<10, origin: 1_000_000)
        let pts = pipeline.finish().packets.map(\.pts)
        let split = try #require(pts.firstIndex(of: 1_000_000))
        // 20480 frames plus 2048 of priming, padded to whole packets.
        #expect(split == Int((Double(10 * Self.chunk + 2048) / 1024).rounded(.up)))
        #expect(pts[..<split] == ArraySlice((0..<split).map { Int64($0) * 1024 }))
        #expect(pts[split...].elementsEqual((0..<(pts.count - split)).map { 1_000_000 + Int64($0) * 1024 }))
    }

    @Test("a chunk the encoder refuses is reported and becomes a gap, and later packets keep their position")
    func failedChunkBecomesAGap() throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let pipeline = APACEncodePipeline(encoder: try makeEncoder(), channels: Self.layout.channelCount,
                                          bufferFrames: Self.chunk)
        var buffer = pipeline.takeInitialBuffer()
        submit(pipeline, &buffer, chunks: 0..<5, origin: 0)
        // After end of stream the encoder refuses input until it is reset, which the failure does.
        _ = pipeline.finish()
        submit(pipeline, &buffer, chunks: 5..<6, origin: 0)
        submit(pipeline, &buffer, chunks: 6..<10, origin: 0)
        let out = pipeline.finish()
        #expect(out.errors.count == 1)
        #expect(out.packets.first?.pts == Int64(6 * Self.chunk), "the refused chunk is skipped, not shifted onto")
        #expect(out.packets.map(\.pts) == out.packets.indices.map { Int64(6 * Self.chunk) + Int64($0) * 1024 })
    }

    @Test("a shift moves every packet stamped after it, the encoder's held-back ones included")
    func shiftMovesLaterPackets() throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let reference = APACEncodePipeline(encoder: try makeEncoder(), channels: Self.layout.channelCount,
                                           bufferFrames: Self.chunk)
        var referenceBuffer = reference.takeInitialBuffer()
        submit(reference, &referenceBuffer, chunks: 0..<5, origin: 0)
        let unshifted = reference.settle().packets.count

        let pipeline = APACEncodePipeline(encoder: try makeEncoder(), channels: Self.layout.channelCount,
                                          bufferFrames: Self.chunk)
        var buffer = pipeline.takeInitialBuffer()
        submit(pipeline, &buffer, chunks: 0..<5, origin: 0)
        pipeline.shift(by: 4800)
        submit(pipeline, &buffer, chunks: 5..<10, origin: 4800)
        let pts = pipeline.finish().packets.map(\.pts)
        #expect(pts[..<unshifted].elementsEqual((0..<unshifted).map { Int64($0) * 1024 }))
        #expect(pts[unshifted...].elementsEqual((unshifted..<pts.count).map { 4800 + Int64($0) * 1024 }))
    }

    @Test("a shift between runs leaves the next run on its own chunk's position")
    func shiftBetweenRunsIsTheCallersPosition() throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let pipeline = APACEncodePipeline(encoder: try makeEncoder(), channels: Self.layout.channelCount,
                                          bufferFrames: Self.chunk)
        var buffer = pipeline.takeInitialBuffer()
        submit(pipeline, &buffer, chunks: 0..<3, origin: 0)
        pipeline.restart()
        _ = pipeline.settle()
        pipeline.shift(by: 4800)
        submit(pipeline, &buffer, chunks: 0..<3, origin: 200_000)
        #expect(pipeline.finish().packets.first?.pts == 200_000)
    }

    @Test("closing with work queued waits for it and leaves nothing running")
    func closeWaitsForQueuedWork() throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let pipeline = APACEncodePipeline(encoder: try makeEncoder(), channels: Self.layout.channelCount,
                                          bufferFrames: Self.chunk)
        var buffer = pipeline.takeInitialBuffer()
        submit(pipeline, &buffer, chunks: 0..<8, origin: 0)
        pipeline.close()
        let closed = pipeline.collect().packets.count

        let reference = APACEncodePipeline(encoder: try makeEncoder(), channels: Self.layout.channelCount,
                                           bufferFrames: Self.chunk)
        var referenceBuffer = reference.takeInitialBuffer()
        submit(reference, &referenceBuffer, chunks: 0..<8, origin: 0)
        #expect(closed == reference.settle().packets.count, "every queued chunk ran before close returned")
    }
}

/// The real encoder, recording every call: the samples each `encode` was given (copied on entry,
/// before the encoder reads them, because the pipeline's buffers are reused) and every packet the
/// encoder returned, `flush` included.
@available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *)
private final class RecordingAPACEncoder: APACPacketEncoding, @unchecked Sendable {
    enum Call: Equatable { case encode, flush, reset }

    private let encoder: APACEncoder
    private let lock = NSLock()
    private var recordedCalls: [Call] = []
    private var recordedInputs: [[[UInt32]]] = []
    private var recordedPackets: [APACEncoder.Packet] = []

    init(_ encoder: APACEncoder) { self.encoder = encoder }

    var leadingFrames: Int { encoder.leadingFrames }
    var magicCookie: Data { encoder.magicCookie }

    var calls: [Call] { lock.withLock { recordedCalls } }
    /// Per `encode` call, per channel, the samples' bit patterns.
    var inputs: [[[UInt32]]] { lock.withLock { recordedInputs } }
    var packets: [APACEncoder.Packet] { lock.withLock { recordedPackets } }

    func encode(planes: [UnsafePointer<Float>], frameCount: Int) throws -> [APACEncoder.Packet] {
        let input = planes.map { UnsafeBufferPointer(start: $0, count: frameCount).map(\.bitPattern) }
        lock.withLock {
            recordedCalls.append(.encode)
            recordedInputs.append(input)
        }
        return record(try encoder.encode(planes: planes, frameCount: frameCount))
    }

    func flush() throws -> [APACEncoder.Packet] {
        lock.withLock { recordedCalls.append(.flush) }
        return record(try encoder.flush())
    }

    func reset() {
        lock.withLock { recordedCalls.append(.reset) }
        encoder.reset()
    }

    private func record(_ packets: [APACEncoder.Packet]) -> [APACEncoder.Packet] {
        lock.withLock { recordedPackets += packets }
        return packets
    }
}

// Tests/AetherEngineTests/Issue684FirstServeLatchTests.swift
// AE#684 review: on an INGEST the first-serve gate held the second playlist request too. AVPlayer opens
// a session with two `/media.m3u8` requests back to back, each without an `_HLS_msn`, so each re-enters
// the gate. With the cushion satisfied both pass at once. On a bounded start (the window under the
// holdback, served after its grace) the second one waited out a second grace: measured on a
// three-segment 6 s upstream as 2.012 s to the first manifest, then 2.02 s more before `init.mp4`.
//
// The fork keeps its first-request-only contract on raw sources through an explicit host
// option. Upstream leaves that arm off by default until a device validates its edge behavior.
// The advertised target duration and holdback remain unchanged.
import XCTest
@testable import AetherEngine

final class Issue684FirstServeLatchTests: XCTestCase {

    private func makeProvider(ingest: Bool) -> (VideoSegmentProvider, SegmentCache) {
        let cache = SegmentCache(forwardWindow: 10, backwardWindow: 10)
        let policy = ingest ? LiveCadencePolicy(observe: { 0.1 }, cutTargetSeconds: 0.5, clock: { 0 }) : nil
        let provider = VideoSegmentProvider(
            cache: cache,
            segments: [],
            codecsString: "avc1.4D001E,mp4a.40.2",
            supplementalCodecs: nil,
            resolution: (720, 576),
            videoRange: .sdr,
            frameRate: 25,
            hdcpLevel: nil,
            sourceBitrate: 1_500_000,
            isLive: true,
            liveWindowSizing: LiveWindowSizing(targetSegmentDurationSeconds: 0.5, dvrWindowSeconds: nil),
            allowsBoundedDegradedStart: true,
            firstServeLatchCoversEngineCut: !ingest,
            liveCadencePolicy: policy
        )
        return (provider, cache)
    }

    private func seconds(_ body: () -> Void) -> Double {
        let start = DispatchTime.now()
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
    }

    /// Two 0.2 s segments against a 3 s holdback: the bounded start, grace 0.5 s.
    func testOnAnIngestASecondRequestIsNotHeldForASecondGrace() {
        let (provider, cache) = makeProvider(ingest: true)
        defer { cache.close() }
        provider.appendLiveSegment(index: 0, startSeconds: 0, durationSeconds: 0.2)
        provider.appendLiveSegment(index: 1, startSeconds: 0.2, durationSeconds: 0.2)

        var served = false
        let first = seconds { served = provider.waitForFirstLiveSegment(timeout: 3) }
        XCTAssertTrue(served)
        XCTAssertGreaterThanOrEqual(first, 0.45, "the first request pays the grace, as before")

        let second = seconds { served = provider.waitForFirstLiveSegment(timeout: 3) }
        XCTAssertTrue(served)
        XCTAssertLessThan(second, 0.2, "a manifest has gone out; the gate is open")
    }

    /// Downstream contract: a raw source also pays the startup grace only once.
    func testOnASelfCutSourceTheSecondRequestDoesNotRepeatItsGrace() {
        let (provider, cache) = makeProvider(ingest: false)
        defer { cache.close() }
        provider.appendLiveSegment(index: 0, startSeconds: 0, durationSeconds: 0.2)
        provider.appendLiveSegment(index: 1, startSeconds: 0.2, durationSeconds: 0.2)

        var served = false
        let first = seconds { served = provider.waitForFirstLiveSegment(timeout: 3) }
        XCTAssertTrue(served)
        XCTAssertGreaterThanOrEqual(first, 0.45)
        let second = seconds { served = provider.waitForFirstLiveSegment(timeout: 3) }
        XCTAssertTrue(served)
        XCTAssertLessThan(second, 0.2, "successful raw-source admission remains latched")
    }

    /// The latch is on a SERVED manifest. A gate that gave up with nothing cut has served none.
    func testAnUnservedGateStaysAGate() {
        let (provider, cache) = makeProvider(ingest: true)
        defer { cache.close() }
        XCTAssertFalse(provider.waitForFirstLiveSegment(timeout: 0.1))
        XCTAssertFalse(provider.waitForFirstLiveSegment(timeout: 0.1))
    }
}

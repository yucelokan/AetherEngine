import Foundation
import XCTest
@testable import AetherEngine

final class LivePacketReplayGuardTests: XCTestCase {
    private func packet(_ stream: LivePacketReplayGuard.Stream, _ tick: Int64,
                        payload: UInt8? = nil) -> LivePacketReplayGuard.Signature {
        .init(stream: stream, dts: tick, pts: tick,
              payload: Data([payload ?? UInt8(truncatingIfNeeded: tick), 0xA5]))
    }

    func testExactVideoAndAudioReplayResumesAtFirstNewPackets() {
        var guard_ = LivePacketReplayGuard()
        for tick in 0..<40 {
            guard_.record(packet(.video, Int64(tick)), sourceSeconds: Double(tick))
            guard_.record(packet(.audio, Int64(tick)), sourceSeconds: Double(tick))
        }

        for tick in 20..<40 {
            let video = guard_.inspect(packet(.video, Int64(tick)), sourceSeconds: Double(tick),
                                       timeBaseSeconds: 1, videoFrontier: 39, audioFrontier: 39)
            XCTAssertTrue(video.drop)
            if tick == 20 { XCTAssertEqual(video.event, .began) }
            let audio = guard_.inspect(packet(.audio, Int64(tick)), sourceSeconds: Double(tick),
                                       timeBaseSeconds: 1, videoFrontier: 39, audioFrontier: 39)
            XCTAssertTrue(audio.drop)
        }

        let newVideo = guard_.inspect(packet(.video, 40), sourceSeconds: 40,
                                      timeBaseSeconds: 1, videoFrontier: 39, audioFrontier: 39)
        XCTAssertFalse(newVideo.drop)
        XCTAssertNil(newVideo.event)
        let newAudio = guard_.inspect(packet(.audio, 40), sourceSeconds: 40,
                                      timeBaseSeconds: 1, videoFrontier: 39, audioFrontier: 39)
        XCTAssertFalse(newAudio.drop)
        XCTAssertEqual(newAudio.event, .finished(videoPackets: 20, audioPackets: 20,
                                                 videoSeconds: 19))
        XCTAssertFalse(guard_.isDroppingReplay)
    }

    func testClockResetWithNewContentNeverDropsAFrame() {
        var guard_ = LivePacketReplayGuard()
        for tick in 0..<40 {
            guard_.record(packet(.video, Int64(tick)), sourceSeconds: Double(tick))
        }
        let result = guard_.inspect(packet(.video, 20, payload: 0xFF), sourceSeconds: 20,
                                    timeBaseSeconds: 1, videoFrontier: 39,
                                    audioFrontier: Int64.min)
        XCTAssertFalse(result.drop)
        XCTAssertNil(result.event)
    }

    func testAudioCanReachTheOverlapBeforeVideo() {
        var guard_ = LivePacketReplayGuard()
        for tick in 0..<40 {
            guard_.record(packet(.video, Int64(tick)), sourceSeconds: Double(tick))
            guard_.record(packet(.audio, Int64(tick)), sourceSeconds: Double(tick))
        }
        let firstAudio = guard_.inspect(packet(.audio, 20), sourceSeconds: 20,
                                        timeBaseSeconds: 1, videoFrontier: 39, audioFrontier: 39)
        XCTAssertTrue(firstAudio.drop)
        XCTAssertEqual(firstAudio.event, .began)
        XCTAssertTrue(guard_.inspect(packet(.video, 20), sourceSeconds: 20,
                                     timeBaseSeconds: 1, videoFrontier: 39,
                                     audioFrontier: 39).drop)
    }

    func testFirstDifferentPacketInsideReplayIsForwarded() {
        var guard_ = LivePacketReplayGuard()
        for tick in 0..<40 {
            guard_.record(packet(.video, Int64(tick)), sourceSeconds: Double(tick))
        }
        XCTAssertTrue(guard_.inspect(packet(.video, 20), sourceSeconds: 20,
                                     timeBaseSeconds: 1, videoFrontier: 39,
                                     audioFrontier: Int64.min).drop)
        let different = guard_.inspect(packet(.video, 21, payload: 0xFF), sourceSeconds: 21,
                                       timeBaseSeconds: 1, videoFrontier: 39,
                                       audioFrontier: Int64.min)
        XCTAssertFalse(different.drop)
        XCTAssertEqual(different.event, .mismatch(videoPackets: 1, audioPackets: 0))
    }

    func testOldHistoryCannotSuppressNewContent() {
        var guard_ = LivePacketReplayGuard()
        for tick in 0..<100 {
            guard_.record(packet(.video, Int64(tick)), sourceSeconds: Double(tick))
        }
        let old = guard_.inspect(packet(.video, 20), sourceSeconds: 20,
                                 timeBaseSeconds: 1, videoFrontier: 99,
                                 audioFrontier: Int64.min)
        XCTAssertFalse(old.drop)
    }

    func testLongPairedOverlapRequiresFreshSourceWhenEitherTrackDiverges() {
        for changedStream in [LivePacketReplayGuard.Stream.video, .audio] {
            var guard_ = LivePacketReplayGuard()
            for tick in 0..<40 {
                for stream in [LivePacketReplayGuard.Stream.video, .audio] {
                    guard_.record(packet(stream, Int64(tick)), sourceSeconds: Double(tick))
                }
            }
            for tick in 20..<24 {
                for stream in [LivePacketReplayGuard.Stream.audio, .video] {
                    XCTAssertTrue(guard_.inspect(packet(stream, Int64(tick)),
                        sourceSeconds: Double(tick), timeBaseSeconds: 1,
                        videoFrontier: 39, audioFrontier: 39).drop)
                }
            }
            let changed = guard_.inspect(packet(changedStream, 24, payload: 0xFF),
                sourceSeconds: 24, timeBaseSeconds: 1, videoFrontier: 39, audioFrontier: 39)
            XCTAssertFalse(changed.drop, "different media is not classified as a duplicate")
            XCTAssertEqual(changed.event, .interrupted(videoPackets: 4, audioPackets: 4))
            XCTAssertNotNil(guard_.confirmedPrefix, "producer must stop rather than remux the prefix")
        }
    }

    func testOneMatchingTrackCannotConfirmAProgrammeBoundary() {
        var guard_ = LivePacketReplayGuard()
        for tick in 0..<40 {
            for stream in [LivePacketReplayGuard.Stream.video, .audio] {
                guard_.record(packet(stream, Int64(tick)), sourceSeconds: Double(tick))
            }
        }
        for tick in 20..<24 {
            _ = guard_.inspect(packet(.video, Int64(tick)), sourceSeconds: Double(tick),
                timeBaseSeconds: 1, videoFrontier: 39, audioFrontier: 39)
        }
        _ = guard_.inspect(packet(.audio, 20), sourceSeconds: 20,
            timeBaseSeconds: 1, videoFrontier: 39, audioFrontier: 39)
        XCTAssertNil(guard_.confirmedPrefix)
        let changed = guard_.inspect(packet(.audio, 21, payload: 0xFF), sourceSeconds: 21,
            timeBaseSeconds: 1, videoFrontier: 39, audioFrontier: 39)
        XCTAssertEqual(changed.event, .mismatch(videoPackets: 4, audioPackets: 1))
        XCTAssertFalse(guard_.isDroppingReplay)
    }

    func testNestedRollbackDoesNotEraseAlreadyConfirmedOverlap() {
        var guard_ = LivePacketReplayGuard()
        for tick in 0..<40 {
            guard_.record(packet(.video, Int64(tick)), sourceSeconds: Double(tick))
        }
        for tick in [20, 21, 22, 23, 20] {
            _ = guard_.inspect(packet(.video, Int64(tick)), sourceSeconds: Double(tick),
                timeBaseSeconds: 1, videoFrontier: 39, audioFrontier: Int64.min)
        }
        XCTAssertNotNil(guard_.confirmedPrefix)
        let changed = guard_.inspect(packet(.video, 21, payload: 0xFF), sourceSeconds: 21,
            timeBaseSeconds: 1, videoFrontier: 39, audioFrontier: Int64.min)
        XCTAssertEqual(changed.event, .interrupted(videoPackets: 5, audioPackets: 0))
        guard_.reset()
        XCTAssertNil(guard_.confirmedPrefix)
        XCTAssertFalse(guard_.isDroppingReplay)
    }

    func testSubthresholdPairedMatchesRemainAmbiguous() {
        var guard_ = LivePacketReplayGuard()
        for tick in 0..<40 {
            for stream in [LivePacketReplayGuard.Stream.video, .audio] {
                guard_.record(packet(stream, Int64(tick)), sourceSeconds: Double(tick))
            }
        }
        for tick in 20..<22 {
            for stream in [LivePacketReplayGuard.Stream.video, .audio] {
                _ = guard_.inspect(packet(stream, Int64(tick)), sourceSeconds: Double(tick),
                    timeBaseSeconds: 1, videoFrontier: 39, audioFrontier: 39)
            }
        }
        XCTAssertNil(guard_.confirmedPrefix)
        let changed = guard_.inspect(packet(.video, 22, payload: 0xFF), sourceSeconds: 22,
            timeBaseSeconds: 1, videoFrontier: 39, audioFrontier: 39)
        XCTAssertEqual(changed.event, .mismatch(videoPackets: 2, audioPackets: 2))
    }

    func testSustainedThirtyFPSAndAACOverlapCannotRollbackAfterDivergence() {
        var guard_ = LivePacketReplayGuard()
        for frame in 0..<1_350 {
            guard_.record(packet(.video, Int64(frame * 3_000)), sourceSeconds: Double(frame) / 30)
        }
        for frame in 0..<2_110 {
            guard_.record(packet(.audio, Int64(frame * 1_024)),
                          sourceSeconds: Double(frame * 1_024) / 48_000)
        }
        var replay: [(LivePacketReplayGuard.Signature, Double, Double)] = []
        for frame in 300..<(300 + 738) {
            replay.append((packet(.video, Int64(frame * 3_000)), Double(frame) / 30, 1 / 90_000))
        }
        for frame in 469..<(469 + 1_147) {
            replay.append((packet(.audio, Int64(frame * 1_024)),
                           Double(frame * 1_024) / 48_000, 1 / 48_000))
        }
        replay.sort { $0.1 < $1.1 }
        for (signature, seconds, timeBase) in replay {
            XCTAssertTrue(guard_.inspect(signature, sourceSeconds: seconds,
                timeBaseSeconds: timeBase, videoFrontier: 1_349 * 3_000,
                audioFrontier: 2_109 * 1_024).drop)
        }
        let changed = guard_.inspect(packet(.audio, 1_616 * 1_024, payload: 0xFF),
            sourceSeconds: Double(1_616 * 1_024) / 48_000, timeBaseSeconds: 1 / 48_000,
            videoFrontier: 1_349 * 3_000, audioFrontier: 2_109 * 1_024)
        XCTAssertEqual(changed.event, .interrupted(videoPackets: 738, audioPackets: 1_147))
        XCTAssertFalse(changed.drop)
        XCTAssertNotNil(guard_.confirmedPrefix)
    }

    func testConfiguredAudioWithoutAcceptedHistoryCannotVerifyAReplay() {
        var guard_ = LivePacketReplayGuard()
        for tick in 0..<40 {
            guard_.record(packet(.video, Int64(tick)), sourceSeconds: Double(tick))
        }
        for tick in 20..<24 {
            _ = guard_.inspect(packet(.video, Int64(tick)), sourceSeconds: Double(tick),
                timeBaseSeconds: 1, videoFrontier: 39, audioFrontier: Int64.min, hasAudio: true)
        }
        XCTAssertNil(guard_.confirmedPrefix, "configured audio has supplied no evidence yet")
        let firstAudio = guard_.inspect(packet(.audio, 24), sourceSeconds: 24,
            timeBaseSeconds: 1, videoFrontier: 39, audioFrontier: Int64.min, hasAudio: true)
        XCTAssertEqual(firstAudio.event, .mismatch(videoPackets: 4, audioPackets: 0))
        XCTAssertFalse(firstAudio.drop, "the new audio remains on the ordinary programme-boundary path")
        XCTAssertFalse(guard_.isDroppingReplay)
    }
}

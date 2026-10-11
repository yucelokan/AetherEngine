import CryptoKit
import Foundation

/// Conservatively removes packets that a live origin sends a second time after reconnecting.
/// Source timestamps alone are not evidence of a replay: an encoder can reset its clock while
/// continuing with new pictures. Matching source timestamps AND compressed payloads establish
/// the overlap; short damaged runs inside that interval stay quarantined until it completes.
///
/// The guard is pump-thread-only. Its history is bounded in both source time and packet count;
/// it stores digests, never video or audio payloads. An ambiguous mismatch is forwarded; an
/// interrupted overlap already confirmed on both tracks requires a fresh source instead.
/// Short damaged runs are quarantined until later exact matches establish the same interval.
struct LivePacketReplayGuard {
    static let maximumPendingBytes = 96 * 1_024 * 1_024
    static let maximumPendingPackets = 10_000

    enum Stream: Hashable { case video, audio }

    struct Signature: Hashable {
        let stream: Stream
        let dts: Int64
        let pts: Int64
        let digest: SHA256.Digest

        init(stream: Stream, dts: Int64, pts: Int64, payload: Data) {
            self.init(stream: stream, dts: dts, pts: pts, digest: SHA256.hash(data: payload))
        }

        /// Hashes the packet's own buffer: every live packet passes through here, so no copy.
        init(stream: Stream, dts: Int64, pts: Int64, payload: UnsafeRawBufferPointer) {
            self.init(stream: stream, dts: dts, pts: pts, digest: SHA256.hash(data: payload))
        }

        private init(stream: Stream, dts: Int64, pts: Int64, digest: SHA256.Digest) {
            self.stream = stream
            self.dts = dts
            self.pts = pts
            self.digest = digest
        }
    }

    enum Event: Equatable {
        case began
        case quarantined
        case finished(videoPackets: Int, audioPackets: Int, videoSeconds: Double)
        case mismatch(videoPackets: Int, audioPackets: Int)
        case interrupted(videoPackets: Int, audioPackets: Int)
    }

    struct Decision {
        let drop: Bool
        let event: Event?
    }

    private struct Entry {
        let signature: Signature
        let sourceSeconds: Double
    }

    private struct Overlap {
        let videoFrontier: Int64
        let audioFrontier: Int64
        let requiresAudioMatch: Bool
        var videoFinished = false
        var audioFinished = false
        var videoPackets = 0
        var audioPackets = 0
        var firstVideoSeconds: Double?
        var lastVideoSeconds: Double?
        var firstAudioSeconds: Double?
        var lastAudioSeconds: Double?
        var unmatchedVideo = 0
        var unmatchedAudio = 0
        var firstUnmatchedVideoSeconds: Double?
        var firstUnmatchedAudioSeconds: Double?
        var containsUnmatchedPackets = false
    }

    private static let historySeconds = 45.0
    private static let maximumEntries = 10_000
    private static let backwardTriggerSeconds = HLSSegmentProducer.discontinuityBackwardThresholdSeconds
    // A reconnect can truncate a PES packet. Do not mistake one damaged packet for a new
    // programme, but never scan an unbounded run of different pictures on timestamp alone.
    private static let maximumUnmatchedSeconds = 0.5
    private static let maximumUnmatchedPackets = 64

    private var entries: [Entry] = []
    private var firstEntry = 0
    private var signatureCounts: [Signature: Int] = [:]
    private var overlap: Overlap?
    private var isSourceContinuation = false
    private var replayTailVideoFrontier: Int64?
    private var replayTailAudioFrontier: Int64?

    var isDroppingReplay: Bool { overlap != nil }
    var historyEntryCount: Int { entries.count - firstEntry }

    /// Untimed corrupt packets provide no proof. A completed scan containing one must
    /// still establish distinct exact matches on every participating track.
    mutating func noteDamagedPacket() {
        overlap?.containsUnmatchedPackets = true
    }

    /// One common packet is not proof: each participating track must span the rollback trigger.
    /// Full overlap still completes in place; this evidence only prevents an interrupted scan
    /// from replaying its verified prefix through the ordinary discontinuity path.
    var confirmedPrefix: (videoPackets: Int, audioPackets: Int,
                          videoSeconds: Double, audioSeconds: Double)? {
        guard let current = overlap else { return nil }
        let videoSeconds = (current.lastVideoSeconds ?? 0) - (current.firstVideoSeconds ?? 0)
        let audioSeconds = (current.lastAudioSeconds ?? 0) - (current.firstAudioSeconds ?? 0)
        if isSourceContinuation {
            // A fresh producer can join less than the usual rollback threshold behind
            // cached media. Two exact packets on every participating track prove that prefix.
            guard current.videoPackets >= 2,
                  !current.requiresAudioMatch || current.audioPackets >= 2 else { return nil }
        } else {
            guard videoSeconds >= Self.backwardTriggerSeconds,
                  !current.requiresAudioMatch || audioSeconds >= Self.backwardTriggerSeconds else { return nil }
        }
        return (current.videoPackets, current.audioPackets, videoSeconds, audioSeconds)
    }

    /// Only for a fresh producer continuing the SAME retained cache, never a seek or new load.
    func sourceContinuation() -> Self {
        var result = self
        result.overlap = nil
        result.isSourceContinuation = true
        result.replayTailVideoFrontier = nil
        result.replayTailAudioFrontier = nil
        return result
    }

    mutating func reset() {
        entries.removeAll(keepingCapacity: true)
        firstEntry = 0
        signatureCounts.removeAll(keepingCapacity: true)
        overlap = nil
        isSourceContinuation = false
        replayTailVideoFrontier = nil
        replayTailAudioFrontier = nil
    }

    mutating func record(_ signature: Signature, sourceSeconds: Double) {
        guard sourceSeconds.isFinite else { return }
        entries.append(Entry(signature: signature, sourceSeconds: sourceSeconds))
        signatureCounts[signature, default: 0] += 1
        // Freeze time pruning during a confirmed overlap: the fresh audio/video stream may cross
        // the old frontier at different times, but both still need the same old packet history.
        let cutoff = overlap == nil ? sourceSeconds - Self.historySeconds : -.infinity
        while firstEntry < entries.count,
              (entries[firstEntry].sourceSeconds < cutoff
               || entries.count - firstEntry > Self.maximumEntries) {
            let expired = entries[firstEntry].signature
            if signatureCounts[expired] == 1 {
                signatureCounts.removeValue(forKey: expired)
            } else {
                signatureCounts[expired, default: 0] -= 1
            }
            firstEntry += 1
        }
        if firstEntry > 1_024 {
            entries.removeFirst(firstEntry)
            firstEntry = 0
        }
    }

    mutating func inspect(_ signature: Signature, sourceSeconds: Double, timeBaseSeconds: Double,
                          videoFrontier: Int64, audioFrontier: Int64,
                          hasAudio: Bool = false) -> Decision {
        guard sourceSeconds.isFinite, timeBaseSeconds > 0, signature.dts != Int64.min else {
            return Decision(drop: false, event: nil)
        }

        if overlap == nil {
            let frontier = signature.stream == .video ? videoFrontier : audioFrontier
            // A demuxer can release one last duplicate PES after both tracks crossed the
            // overlap. Keep exact-match protection through a short per-track settling tail.
            let tail = signature.stream == .video ? replayTailVideoFrontier : replayTailAudioFrontier
            if let tail {
                if (Double(signature.dts) - Double(tail)) * timeBaseSeconds > Self.backwardTriggerSeconds {
                    if signature.stream == .video { replayTailVideoFrontier = nil }
                    else { replayTailAudioFrontier = nil }
                } else if signature.dts <= frontier, signatureCounts[signature] != nil {
                    return Decision(drop: true, event: nil)
                }
            }
            guard frontier != Int64.min,
                  (Double(frontier) - Double(signature.dts)) * timeBaseSeconds
                    >= (isSourceContinuation ? 0 : Self.backwardTriggerSeconds),
                  signatureCounts[signature] != nil || entries[firstEntry...].contains(where: {
                      $0.signature.stream == signature.stream && $0.signature.dts == signature.dts
                          && $0.signature.pts == signature.pts
                  }) else {
                return Decision(drop: false, event: nil)
            }
            let requiresAudioMatch = hasAudio || audioFrontier != Int64.min
            overlap = Overlap(videoFrontier: videoFrontier, audioFrontier: audioFrontier,
                              requiresAudioMatch: requiresAudioMatch,
                              videoFinished: false, audioFinished: !requiresAudioMatch)
            if signatureCounts[signature] != nil {
                return dropMatched(signature, sourceSeconds: sourceSeconds, event: .began)
            }
            // The very first returning packet can itself be damaged. Matching timestamps
            // only open a bounded quarantine; later exact evidence must prove the replay.
        }

        var current = overlap!
        let frontier = signature.stream == .video ? current.videoFrontier : current.audioFrontier
        if signature.stream == .audio, current.requiresAudioMatch, frontier == Int64.min {
            // A configured track not admitted yet is not an absent track or replay evidence.
            overlap = nil
            return Decision(drop: false, event: .mismatch(
                videoPackets: current.videoPackets, audioPackets: current.audioPackets))
        }
        if frontier != Int64.min, signature.dts <= frontier {
            guard signatureCounts[signature] != nil else {
                let lastMatch = signature.stream == .video ? current.lastVideoSeconds : current.lastAudioSeconds
                let unmatched = signature.stream == .video ? current.unmatchedVideo : current.unmatchedAudio
                // A damaged first PES can precede this track's first exact match. Its own
                // bounded interval is provisional; completion still needs BOTH tracks' proof.
                let firstUnmatched = signature.stream == .video
                    ? current.firstUnmatchedVideoSeconds : current.firstUnmatchedAudioSeconds
                let anchor = lastMatch ?? firstUnmatched ?? sourceSeconds
                if sourceSeconds >= anchor,
                   sourceSeconds - anchor <= Self.maximumUnmatchedSeconds,
                   unmatched < Self.maximumUnmatchedPackets {
                    if signature.stream == .video {
                        current.unmatchedVideo += 1
                        if current.firstUnmatchedVideoSeconds == nil { current.firstUnmatchedVideoSeconds = sourceSeconds }
                    } else {
                        current.unmatchedAudio += 1
                        if current.firstUnmatchedAudioSeconds == nil { current.firstUnmatchedAudioSeconds = sourceSeconds }
                    }
                    let firstGap = !current.containsUnmatchedPackets
                    current.containsUnmatchedPackets = true
                    overlap = current
                    // This is only a provisional discard: the producer buffers it until BOTH
                    // tracks reach their retained frontier with sufficient exact evidence.
                    return Decision(drop: true, event: firstGap ? .quarantined : nil)
                }
                if confirmedPrefix != nil {
                    return Decision(drop: false, event: .interrupted(
                        videoPackets: current.videoPackets, audioPackets: current.audioPackets))
                }
                overlap = nil
                return Decision(drop: false,
                                event: .mismatch(videoPackets: current.videoPackets,
                                                 audioPackets: current.audioPackets))
            }
            return dropMatched(signature, sourceSeconds: sourceSeconds, event: nil)
        }

        if signature.stream == .video { current.videoFinished = true }
        else { current.audioFinished = true }
        if current.videoFinished && current.audioFinished {
            if current.containsUnmatchedPackets,
               ((current.lastVideoSeconds ?? 0) <= (current.firstVideoSeconds ?? 0)
                || (current.requiresAudioMatch
                    && (current.lastAudioSeconds ?? 0) <= (current.firstAudioSeconds ?? 0))) {
                overlap = nil
                return Decision(drop: false, event: .mismatch(
                    videoPackets: current.videoPackets, audioPackets: current.audioPackets))
            }
            replayTailVideoFrontier = current.videoFrontier
            replayTailAudioFrontier = current.requiresAudioMatch ? current.audioFrontier : nil
            overlap = nil
            isSourceContinuation = false
            return Decision(drop: false, event: .finished(
                videoPackets: current.videoPackets, audioPackets: current.audioPackets,
                videoSeconds: max(0, (current.lastVideoSeconds ?? 0) - (current.firstVideoSeconds ?? 0))))
        }
        overlap = current
        return Decision(drop: false, event: nil)
    }

    private mutating func dropMatched(_ signature: Signature, sourceSeconds: Double,
                                      event: Event?) -> Decision {
        var current = overlap!
        if signature.stream == .video {
            current.unmatchedVideo = 0
            current.firstUnmatchedVideoSeconds = nil
            current.videoPackets += 1
            if current.firstVideoSeconds == nil { current.firstVideoSeconds = sourceSeconds }
            current.lastVideoSeconds = max(current.lastVideoSeconds ?? sourceSeconds, sourceSeconds)
        } else {
            current.unmatchedAudio = 0
            current.firstUnmatchedAudioSeconds = nil
            current.audioPackets += 1
            if current.firstAudioSeconds == nil { current.firstAudioSeconds = sourceSeconds }
            current.lastAudioSeconds = max(current.lastAudioSeconds ?? sourceSeconds, sourceSeconds)
        }
        overlap = current
        return Decision(drop: true, event: event)
    }
}

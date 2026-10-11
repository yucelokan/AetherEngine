import CryptoKit
import Foundation

/// Conservatively removes packets that a live origin sends a second time after reconnecting.
/// Source timestamps alone are not evidence of a replay: an encoder can reset its clock while
/// continuing with new pictures. A packet is removed only when its source timestamps AND its
/// compressed payload match a packet that this producer already accepted.
///
/// The guard is pump-thread-only. Its history is bounded in both source time and packet count;
/// it stores digests, never video or audio payloads. An ambiguous mismatch is forwarded; an
/// interrupted overlap already confirmed on both tracks requires a fresh source instead.
struct LivePacketReplayGuard {
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
    }

    private static let historySeconds = 45.0
    private static let maximumEntries = 10_000
    private static let backwardTriggerSeconds = HLSSegmentProducer.discontinuityBackwardThresholdSeconds

    private var entries: [Entry] = []
    private var firstEntry = 0
    private var signatureCounts: [Signature: Int] = [:]
    private var overlap: Overlap?
    private var isSourceContinuation = false

    var isDroppingReplay: Bool { overlap != nil }
    var historyEntryCount: Int { entries.count - firstEntry }

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
        return result
    }

    mutating func reset() {
        entries.removeAll(keepingCapacity: true)
        firstEntry = 0
        signatureCounts.removeAll(keepingCapacity: true)
        overlap = nil
        isSourceContinuation = false
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
            guard frontier != Int64.min,
                  (Double(frontier) - Double(signature.dts)) * timeBaseSeconds
                    >= (isSourceContinuation ? 0 : Self.backwardTriggerSeconds),
                  signatureCounts[signature] != nil else {
                return Decision(drop: false, event: nil)
            }
            let requiresAudioMatch = hasAudio || audioFrontier != Int64.min
            overlap = Overlap(videoFrontier: videoFrontier, audioFrontier: audioFrontier,
                              requiresAudioMatch: requiresAudioMatch,
                              videoFinished: false, audioFinished: !requiresAudioMatch)
            return dropMatched(signature, sourceSeconds: sourceSeconds, event: .began)
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
            current.videoPackets += 1
            if current.firstVideoSeconds == nil { current.firstVideoSeconds = sourceSeconds }
            current.lastVideoSeconds = max(current.lastVideoSeconds ?? sourceSeconds, sourceSeconds)
        } else {
            current.audioPackets += 1
            if current.firstAudioSeconds == nil { current.firstAudioSeconds = sourceSeconds }
            current.lastAudioSeconds = max(current.lastAudioSeconds ?? sourceSeconds, sourceSeconds)
        }
        overlap = current
        return Decision(drop: true, event: event)
    }
}

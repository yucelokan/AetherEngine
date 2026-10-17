import Foundation
import XCTest
@testable import AetherEngine

final class HLSIngestDiagnosticsTests: XCTestCase {
    func testPlaylistSubreasonsSurviveNSErrorWithoutChangingTheExistingCode() {
        let cases: [(String, HLSIngestDiagnosticReason)] = [
            ("missing #EXTM3U", .missingEXTM3U),
            ("missing TARGETDURATION", .missingTargetDuration),
            ("no segments", .noSegments),
            ("master playlist without variants", .noVariants),
            ("no usable variant", .noUsableVariant),
            ("selected variant is not a media playlist", .expectedMediaPlaylist),
            ("expected media playlist on refresh", .expectedMediaPlaylist),
            ("finite VOD requires EXT-X-ENDLIST", .missingEndList),
            ("unresolvable segment URI", .invalidSegmentURI),
            ("media sequence out of range", .invalidMediaSequence),
            ("TARGETDURATION out of range", .invalidTargetDuration),
            ("EXTINF out of range", .invalidSegmentDuration),
            ("segment duration must be positive", .invalidSegmentDuration),
            ("program duration exceeds 1.0s", .durationLimitExceeded),
            ("playlist exceeds 10 bytes", .playlistSizeLimitExceeded),
            ("playlist line exceeds 10 bytes", .playlistLineLimitExceeded),
            ("segment exceeds 10 bytes", .bodySizeLimitExceeded),
            ("body exceeds 10 bytes", .bodySizeLimitExceeded),
            ("non-UTF8 playlist", .invalidPlaylistEncoding),
            ("playlist is not bounded UTF-8", .invalidPlaylistEncoding),
            ("https://private.invalid/password?token=secret", .playlistInvalid)
        ]
        for (text, reason) in cases {
            let error = HLSIngestError.playlistInvalid(reason: text)
            let bridged = error as NSError
            XCTAssertEqual(bridged.code, 2)
            XCTAssertEqual(bridged.domain, HLSIngestError.errorDomain)
            XCTAssertEqual(error.diagnosticReason, reason)
            XCTAssertEqual(bridged.userInfo[HLSIngestDiagnosticReason.userInfoKey] as? String, reason.rawValue)
            let wrapper = NSError(domain: "AetherEngine.DemuxerError", code: 1,
                                  userInfo: [NSUnderlyingErrorKey: bridged])
            let info = PlaybackErrorInfo(kind: .customSourceProbeFailed, message: "private", underlying: wrapper)
            XCTAssertEqual(info.hlsDiagnosticReason, reason)
            XCTAssertEqual(info.underlyingDomain, wrapper.domain)
            XCTAssertEqual(info.underlyingCode, wrapper.code)
        }
    }

    func testParserRetainsTheSpecificMalformedPlaylistCause() {
        let cases: [(String, HLSIngestDiagnosticReason)] = [
            ("<html>private credentials</html>", .missingEXTM3U),
            ("#EXTM3U\n#EXTINF:4,\nsegment.ts", .missingTargetDuration),
            ("#EXTM3U\n#EXT-X-TARGETDURATION:4", .noSegments),
            ("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1", .noVariants),
            ("#EXTM3U\n#EXT-X-TARGETDURATION:inf\n#EXTINF:4,\nsegment.ts", .invalidTargetDuration),
            ("#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXTINF:nan,\nsegment.ts", .invalidSegmentDuration)
        ]
        for (body, reason) in cases {
            XCTAssertThrowsError(try HLSPlaylistParser.parse(body)) { error in
                XCTAssertEqual(HLSIngestDiagnosticReason.preserved(in: error), reason)
            }
        }
    }

    func testResponseEncryptionAndSegmentReasonsAreFinite() {
        let cases: [(HLSIngestError, HLSIngestDiagnosticReason, Int)] = [
            (.playlistUnreachable(status: -1), .invalidResponse, 1),
            (.playlistUnreachable(status: 403), .httpResponseRefused, 1),
            (.encryptedNotSupported, .encryptionUnsupported, 3),
            (.segmentDecryptFailed(reason: "unresolvable key URI"), .invalidKeyURI, 4),
            (.segmentDecryptFailed(reason: "key length 8 != 16"), .invalidKeyLength, 4),
            (.segmentDecryptFailed(reason: "key length is not 16 bytes"), .invalidKeyLength, 4),
            (.segmentDecryptFailed(reason: "key exceeds 64 bytes"), .keySizeLimitExceeded, 4),
            (.segmentDecryptFailed(reason: "https://private.invalid/token"), .decryptionFailed, 4),
            (.unsupportedSegmentFormat, .segmentFormatUnsupported, 5),
            (.ingestStalled, .ingestStalled, 6),
            (.demuxedAudioNotSupported, .demuxedAudioUnsupported, 7)
        ]
        for (error, reason, code) in cases {
            XCTAssertEqual(error.diagnosticReason, reason)
            XCTAssertEqual((error as NSError).code, code)
        }
    }

    func testUntrustedReasonMetadataIsRejectedAndTraversalIsBounded() {
        let privateMetadata = [HLSIngestDiagnosticReason.userInfoKey: "https://private.invalid/password"]
        XCTAssertNil(HLSIngestDiagnosticReason.preserved(in: NSError(
            domain: HLSIngestError.errorDomain, code: 2, userInfo: privateMetadata)))
        XCTAssertNil(HLSIngestDiagnosticReason.preserved(in: NSError(
            domain: "unrelated.domain", code: 2,
            userInfo: [HLSIngestDiagnosticReason.userInfoKey: "no_segments"])))
        var wrapped: NSError = HLSIngestError.playlistInvalid(reason: "no segments") as NSError
        for _ in 0..<6 {
            wrapped = NSError(domain: "wrapper", code: 1, userInfo: [NSUnderlyingErrorKey: wrapped])
        }
        XCTAssertNil(HLSIngestDiagnosticReason.preserved(in: wrapped), "Traversal must have a fixed bound")
    }
}

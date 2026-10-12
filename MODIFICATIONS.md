# Downstream engine changes

Date: 2026-10-12. Current base: upstream 7.35.1,
`60ac862285ec641d67a984964634b54b57151704`.

The runtime is based on upstream 7.35.1 with the diagnostic, live replay and callback-priority corrections
described below. All ten earlier downstream contribution PRs (#708–#717) are
merged upstream and included in that release. The fork also retains this
modification record and the incorporated GPL text. The API and correction
sections after the current differences describe prior revisions.
The original downstream commit was based on 7.23.2 and is preserved in history.

The changes in this fork remain under the LGPL v3 and Apple Store / DRM
Exception in [LICENSE](LICENSE). The incorporated GPL text is supplied in
[COPYING.GPL3](COPYING.GPL3). Original copyright notices are preserved.
This record identifies the modification dates and source files. These are general engine
APIs and fixes; application UI, support reporting, provider settings and
application resource budgets do not belong here.

## Unflagged replay boundary and progressing-audio video stalls

A real byte-truncated transport replay could retain an unflagged partial outgoing
picture and its intact returning copy at identical DTS/PTS. The verified pending
batch now emits only the returning video picture, before monotonic timestamp repair.
Native and software admission share the correction. Native VideoToolbox and software
regressions compare full decoded pictures for damaged ordinary and keyframe seams.
Untimed outgoing fragments stay quarantined with the damaged boundary; verified replay
discards them before timestamp synthesis can advance the admitted frontier. Ambiguous
boundaries still forward every packet.

`nativeVideoFrameRecovery` is an explicit opt-in, separate from observational frame
diagnostics. It extends bounded same-position presentation recovery to ready layers
with sustained, freshly observed decoded-output stalls. Healthy pictures, not only a
ready flag, rearm recovery. Numeric replay-boundary diagnostics distinguish replaced,
unreplaced and superseded pictures. See [device evidence and reproduction](docs/validation/live-video-progress.md).

## Native video presentation recovery

Date: 2026-10-12. Native playback now distinguishes an advancing item/audio clock
from a previously visible inline layer that remains unready. Bounded same-position
consumer repair preserves the source and live DVR; PiP, external playback, seeks,
pauses, detached/hidden surfaces and starvation are excluded. Optional decoded
output diagnostics detach before PiP and reattach only after inline readiness.
Readiness/eligibility and repair outcomes are logged without source identifiers.

Changes are generic engine code in `AetherEngine+Loading.swift`, `AetherEngine.swift`,
`Native/NativeAVPlayerHost.swift` and `Diagnostics/VideoFrameProgress.swift`, offered
in PR #747. Long-GOP H.264 High / 25 fps / AAC-LC regressions compare all decoded
pictures after a damaged replay through both software admission and native remux.
The reported PiP black-screen onset itself is not conclusively established by the
older logs; the diagnostic transition and missing recovery path are addressed.

## Upstream 7.35.1 integration and contribution coverage

Date: 2026-10-12. The published release is the integration base; unreleased
main-only changes are not imported. Includes the persistent HTTP/1.1 ingest,
format-description scheduling, Blu-ray EP-map/folder seeking, and segment-muxer
teardown corrections from 7.35.0 and 7.35.1. FFmpegBuild is now 3.7.1 under the
upstream minor-version range; other dependency ranges and deployment floors remain.

All runtime differences are offered in upstream PRs #745–#748. The outgoing
video boundary, cadence-aware verification, software admission and opt-in video
progress diagnostics belong to #747; probe-error cause retention, callback
priority and playlist renewal remain independently buildable contributions.
A source-tree audit combines the four PR diffs on the release and compares every
runtime source blob, retaining both recovery and playlist-renewal callbacks at
shared registration sites. The fork alone retains this record and GPL text.

The output observer excludes the external-playback property on visionOS, where
that AVPlayer API is unavailable. iOS/tvOS/visionOS compilation and reproducible
packet/MPEG-TS regressions cover the final correction. The device logs from the
previous integrated revision found three decoded-output gaps; no subsequent
physical-device run of the final lookahead is claimed.

## Current fork difference: outgoing damaged video boundary and output diagnostics

Date: 2026-10-12. A corrupt outgoing video PES can arrive before source timestamps
roll back. Native and software admission now retain that boundary provisionally,
without publishing it or advancing exact-packet history. Paired, distinct replay
evidence discards the damaged packet and admits the intact returning picture.
Without that evidence, fresh-video progression, bounded packet lookahead, EOF or
read failure forward the retained media without erasing admitted source history.
Earlier intact video/audio remain available during the boundary check. Verified
queues keep exact packets once and restore per-video decode order when the
outgoing demuxer releases a late intact picture.
Follow-up on the same date: a clean outgoing picture no longer releases the
boundary by itself. Cadence-aware bounded lookahead covers sparse video, queued
intact pictures supply provisional replay identity, and their missing predecessor
is admitted from the intact returning copy. Recovery history still contains only
committed packets. Both native encoded MPEG-TS and software packet regressions
reproduce the clean-outgoing-picture-before-rollback order from device logs.

An opt-in `LoadOptions.nativeVideoFrameDiagnostics` observes decoded SDR native
output without suppressing the player renderer or retaining pixel buffers. Its
session contract survives in-place item swaps. It separates output gaps from
sampling delays; pause, seek, background, HDR and external playback are excluded.
Compressed-video cadence diagnostics run after replay admission on both paths.
Neither observation requests recovery, changes playback policy or proves what a
physical display presented. The option defaults off; consumers own activation
and support-log handling. The CLI exposes `--native-video-frame-diagnostics`.

Changed files: `Video/LivePacketReplayGuard.swift`, `Video/HLSSegmentProducer.swift`,
`Video/LiveReplayPacketReader.swift`, `Diagnostics/VideoFrameProgress.swift`,
`Native/NativeAVPlayerHost.swift`, `PlayerState.swift`, `AetherEngine+Loading.swift`,
`AetherEngine+ReloadWithOptions.swift` and the CLI, tests and public documentation.
Packet and encoded H.264/AAC MPEG-TS regressions cover damaged boundaries,
unverified damage, EOF, late outgoing pictures and unchanged source-replay cases.
Physical-device verification of this iteration remains pending; prior device
validation below applies to its named revisions. Upstream PRs are unchanged
until that verification is approved.

## Current fork difference: cache-hit timing regression coverage

Date: 2026-10-12. The existing slow-serve test incorrectly assumed a cached
segment always finished before its timer threshold. A gated, cancellable test
now verifies that delayed cached responses preserve their bytes without
restarting production. Changed files: `Tests/AetherEngineTests/Issue93SlowSegmentServeTests.swift`,
`docs/architecture.md` and `CHANGELOG.md`. No runtime source or timeout changes.
This correction is included in upstream PR #746.

## Current fork difference: variable-GOP renewal and software replay admission

Date: 2026-10-12. Focused commits `9e941a46` and `b9cbfcab`. Long-GOP segments that outgrow a sealed HLS target duration
renew the local playlist URL while retaining the source, cache, position and
transport intent. Retired video/subtitle playlists keep their target and end
index. Renewal clears the previous outage latch and cancels obsolete consumer
recovery tasks. CoreMedia playlist-duration failures are not HDR incompatibility.

Software live playback now checks exact replay before clock folding, recording
or DVR append. Paired replay completion drops corrupt boundary packets and a
bounded settling tail removes exact duplicate PES packets released late by the
demuxer. DVR acquisition yields during cursor repositioning so a returning source
cannot keep advancing the window through that transition. Interrupted software
source reads are classified as source loss, not codec failure. No application
identity, UI policy, provider setting or retry budget is introduced.

Changed runtime files: `AetherEngine.swift`, `AetherEngine+Loading.swift`,
`Native/NativeAVPlayerHost.swift`, `Native/MasterFallbackDecision.swift`,
`Native/SoftwarePlaybackHost.swift`, `Network/HLSLocalServer.swift`,
`Video/HLSVideoEngine.swift`, `Video/VideoSegmentProvider.swift`,
`Video/HLSSegmentProducer.swift`, `Video/LivePacketReplayGuard.swift` and
`Video/LiveReplayPacketReader.swift`.

These changes are covered by packet, encoded MPEG-TS, HTTP playlist and reader
concurrency regressions. A local macOS AVPlayer run with H.264/AAC MPEG-TS and a
GOP-length increase resumed on the same source/cache without backward clock
movement or a software fallback; buffering was still observed. A software live
run with a forced transport drop removed a 23.96-second repeated H.264/AAC
interval, resumed on fresh media, and passed rewind and return-to-live checks.
While the source repeated old media in real time, playback had to wait for fresh
packets. Neither run proves uninterrupted playback under arbitrary source loss.
The integrated runtime revision `70e0a215` was subsequently tested on a physical
iPhone (iOS 26.6.1) and Apple TV (tvOS 27.0) on 2026-10-12. Five source
reconnects discarded repeated media without sampled backward clock movement or
player restarts; the tester reported smooth playback. These sessions exercised
native playback. Upstream PRs #745–#748 are open, and all four CI checks on each
PR passed; maintainer review remains pending.

## Current fork difference: playback network callback priority

Date: 2026-10-11. Applied from commit
`2da38d1f2786b8875fd061411e408dfea8a773fa` on the focused
`fix/foreground-origin-budget` branch, based on upstream 7.34.1.
An upstream pull request has not been opened; device verification is pending.

AVIO, held-transport and prewarm sessions use independent serial user-initiated
delegate queues; held transport work uses the same priority. Finite AVIO requests
return their origin ticket on completion rather than waiting for the synchronous
caller to resume. A lock-guarded lease prevents double release during completion,
cancellation, early return and deallocation. Refusal responses are charged before
handing the slot to another reader. Origin ceilings, FIFO admission, pacing and
retry/timeout policy remain unchanged. No public API is added.

`OriginRequestBudgetTests` and `PlaybackNetworkPriorityTests` verify lease
handoff, racing release, abandoned tickets and actual HTTP completion priority
when the request is started by a utility thread. The changelog and architecture
documentation record the change.

## Current fork difference: live source recovery continuity

Date: 2026-10-11. The initial continuity change (`3df6d401`, focused
`e98a982cebc5a3fbff3621ae10eb50270823c200`) was exercised on physical iPhone and
Apple TV. Those traces exposed damaged-packet mismatches replaying the old prefix
and exhausted source recovery becoming terminal. The follow-up is focused commit
`b9cf47a2`, backported as `95d46cfe05f4fa100532a3126e69b3a5460dcf8a`.
The focused branch remains based on upstream 7.34.1. Subsequent physical iPhone
and Apple TV traces verified seven removed replay intervals and exposed a damaged
first-audio-packet boundary. The October 12 correction is focused commit
`bcfefae61e76d909a5e7fb30b4863ec8d64484fc`, backported as
`37e4ea87`. It bounds initial timestamp candidates until later exact paired
matches, preserves genuine programme changes, and discards corrupt unclassified
A/V packets only after the overlap is verified. Source diagnostics distinguish
held/discarded/forwarded corruption; native telemetry no longer implies that the
AVPlayer clock is a rendered-frame counter. The new encoded regressions cover a
changed first AAC packet, a truncated first audio PES and entirely changed paired
media with reused timestamps. No upstream PR has been opened; the October 12
correction still requires physical-device verification and approval.

Native HLS source recovery retains the DVR cache and bounded exact timestamp /
payload history across fresh producers. The failed source connection is cancelled
before replacement; its codec parameters and counters survive until a validated
swap. Source video/audio codec, time-base, dimensions, sample-rate and channel-count
changes require fresh host negotiation. Comparison uses source parameters rather
than a bridge's converted output. Active recording ends at the source seam.

`liveSourceReplayExhausted` distinguishes a bounded recovery that cannot find new
media after verified replay from an ordinary `liveSourceReset`. The host must not
automatically discard the retained evidence through a full load or decoder switch.
Cached DVR remains readable; `retryLiveSourceRecovery()` resumes acquisition into
the same cache and consumer item. Concurrent requests coalesce and stop revokes
them. Short damaged runs within matched overlap are quarantined until both
tracks cross their admitted frontiers; sustained divergence still fails closed
after a verified prefix. The existing per-round reopen limits remain in effect. Application retry
budgets, backoff, provider configuration and UI decisions remain outside the engine.

Changed runtime files: `AetherEngine.swift`, `AetherEngine+Loading.swift`,
`Video/HLSSegmentProducer.swift`, `Video/HLSVideoEngine.swift`,
`Video/HLSVideoEngine+LiveReopen.swift`, `Video/VideoSegmentProvider.swift`,
and `Video/LivePacketReplayGuard.swift`.
Encoded MPEG-TS tests exercise repeated reconnects without duplicate cached media,
plus short overlap, source-layout changes, reader cancellation, stale callbacks and
separate exhaustion delivery. `CHANGELOG.md`, `docs/api.md` and
`docs/architecture.md` document the public contract and bounded-history limits.

## Current fork difference: interrupted verified live replay

Date: 2026-10-11. Backported from commit
`34def7cdfb0403fba6cbbc8dd00c6b058d9ab568` on the focused
`fix/live-partial-source-replay` branch, prepared against upstream 7.34.1.
An upstream pull request has not been opened; device verification is pending.

`Sources/AetherEngine/Video/LivePacketReplayGuard.swift` requires matching
timestamp/payload evidence spanning the rollback interval on every configured
track before treating an interrupted candidate as verified replay.
`Sources/AetherEngine/Video/HLSSegmentProducer.swift` releases those candidate
packets and exits as `sourceReplay` rather than remuxing an old prefix after
divergence, EOF, a read failure or the existing scan bound. Full exact overlap
still continues in place and ambiguous programme boundaries retain their normal
handling. The source recovery continuation above extends this initial correction
without moving host retry policy into the engine.

`Sources/AetherEngine/Video/HLSVideoEngine+LiveReopen.swift` and the
`liveSourceReset` documentation in `Sources/AetherEngine/AetherEngine.swift`
describe the broader existing retune contract without assuming an HTTP reconnect.
The tests cover encoded H.264/AAC and video-only MPEG-TS, matched packet history,
ambiguous resets, interrupted scans and stale-session delivery. `CHANGELOG.md`,
`docs/api.md` and `docs/architecture.md` document this correction.

## Current fork difference: custom-source probe diagnostics

Commit `aef403ae7f80e6f7e253d5a4346acbe81d0c9bb7` (2026-10-10) changes
`Sources/AetherEngine/AetherEngine.swift` so a failed custom-source probe passes
its existing `probeFailure` to `publishError(.customSourceProbeFailed, ...)`.
The host can then read the underlying error domain and numeric code when it
observes the terminal error state. The probe failure still throws the same
`DemuxerError.openFailed(code: -1)`; opening, decoding and recovery policy are
unchanged.

`Tests/AetherEngineTests/PlaybackErrorInfoTests.swift` adds
`customProbeRetainsCause`, which verifies that an empty custom source publishes
its cause before the host observes the terminal state. This current correction
is downstream of upstream 7.34.1; the fork is not byte-identical to that tag.

## API boundaries

- `LiveDVRLimits` accepts a time window, byte allowance, free-space reserve and
  the monotonic expiry of a caller's capacity measurement. Missing/expired
  measurements withdraw optional retention. There is no application-specific
  duration, capacity lifetime, byte minimum or reserve minimum.
- `setNativeLiveDVRLimits` updates the running loopback cache and playlist
  without opening the source again. The cache, playlist and producer admission
  read one synchronized retention snapshot. A weakly owned timer also reclaims
  expired optional history while the producer is parked. Finite consumer and
  live-edge cushions remain pinned; `nativeLiveDVRMandatoryBytes` reports them.
- `LoadOptions.softwareDVRRetention` opts into software spool limits. The caller
  supplies its initial cap and the bytes/seconds reserved for feeding playback
  after a capacity lease expires. Nil preserves the upstream spool behavior.
  `setSoftwareLiveDVRLimits` renews retention without replacing the source,
  decoder or clock. Payload and chunk bytes are checked on append, oversized
  GOPs wait for a new keyframe, and an unlink failure suspends further writes.
- `liveTargetDurationSeconds` and `currentItemLiveEdgeTime` expose measurements.
  `seekToLiveEdge(offsetSeconds:)` accepts a caller-chosen offset and clamps it
  to retained media. The default offset is zero. There is no built-in return-to-
  live safety-margin policy; clients may use the served HLS duration and
  AVPlayer's recommended/configured offset to choose one.
- `needsForegroundVideoRestore` reports actual background video teardown.
  Clients use the existing `reloadAtCurrentPosition(applying:)` API and choose
  their own transport intent. `sessionReloadRefusal` already reports whether a
  custom source can be reopened; a second audio-specific API is unnecessary.

### Live startup admission

`LoadOptions.liveStartupSingleSegmentMinimumSeconds` is an optional threshold for
single finalized-segment admission on `.fastZap` loopback live sources. Nil
preserves upstream's two-segment minimum. The caller chooses both this threshold
and the existing startup grace; neither changes segment cuts or live-edge
holdback. Policy and first-manifest logs expose the effective admission settings.
Long-GOP raw TS can otherwise wait an extra full GOP even with zero grace.
`LoadOptions.liveFirstServeLatchCoversEngineCut` separately lets a host skip a
second manifest startup grace after successful admission on engine-cut sources.
Its default is false, matching upstream 7.26.3; HLS ingest latches by default.
The application chooses whether its validated source and live-edge policy warrant
this lower-latency path. No process-wide environment setting is required.
The real-media script in `Scripts/test-long-gop-startup.sh` covers 5/10-second
H.264 GOPs with B-frames, AAC, paced delivery, AVPlayer clock progression, rewind
and live return on macOS. Physical iOS/tvOS validation remains a host obligation.

## VOD opening and seek capability

An unanswered HTTP data open retries once with an open-ended Range request within
`SourceOpenPolicy.sizeProbeTimeout`. The successful response remains the playback
connection. Two unanswered requests fail as a transport error, without size-only
speculation, a silent forward-only downgrade or another full engine open. A known
size with a delayed body retains its original connection. Actual range-ignoring
and length-less responses retain their existing forward-only handling.

`isSourceSeekable` describes the measured byte source (nil when unknown or owned
by AVFoundation); `canSeek` describes the active session. A duration is not proof
of seekability. Remote HLS uses the native item's measured range. Forward-only
VOD ignores saved positions and rejects arbitrary seeks as `sourceNotSeekable`.
Native completion checks AVPlayer's completion flag and measured position before
reporting a landing, preserving the current load/seek generation fences. Logs
include requested/actual positions, completion status and the recovery phase.

Caller request limits and timeout values remain outside engine policy. The
engine does not introduce provider-specific defaults. The loopback fixture in
`Scripts/test-vod-open-seek.sh` tests a silent initial request, recovered native
forward/backward/paused seeks and honest sequential playback. Reader tests cover
body truncation, unanswered requests, cancellation and existing refusal paths.

### Validation of the VOD correction

Validated the modified working tree on macOS 27.0.1 / Xcode 27.0 (27A266a):
93 focused tests across 14 source-opening and seek suites passed. The two real
AVPlayer scenarios in `Scripts/test-vod-open-seek.sh` also passed with a synthetic
H.264/AAC/SubRip MKV served over loopback. They cover recovery from a silent
first request, subtitle delivery with a single source-request slot, forward,
backward and paused seeks, and rejection of seeks on a sequential source.
The existing 5 s and 10 s GOP live scenarios also passed, including rewind and
return to live. This is macOS evidence; physical iOS/tvOS provider playback is not established
by these tests. No application archive or device build was made for this change.

## Internal corrections

### Live timeline and source overlap

Native loopback output timestamps remain continuous across a source PTS reset.
The displayed clock, resident ranges, item placement, seeks and preview targets
now use the initial session shift consistently. Rendered source PTS retains its
seam mapping for subtitle cues. This prevents a source rollback from moving the
DVR rail backwards or converting a live target into a future item timestamp.
Subtitle backfill uses elapsed session time; cue pruning uses source time.

When the item range mirror predates the resident floor, the engine may use only
already-played, contiguous resident history. Prefetched media alone never creates
a played frontier. Publication and seek landing use the same rule. A queued
resume clamp is fenced by both load and seek generations; all actual seeks,
including live-only seeks, advance the seek generation.

The single-demuxer, stream-copy live path compares source DTS/PTS and SHA-256
payload signatures before recognizing an origin replay. Both tracks must finish
the overlap before duplicate packets are discarded. A mismatch, end, read error
or bounded-buffer limit forwards all pending packets to ordinary discontinuity
handling. History is bounded to 45 seconds/10,000 signatures; candidate packets
are bounded to 96 MiB/10,000 packets. Side audio and audio bridging are excluded.
The watchdog distinguishes this scan from a cutter wedge but still detects a
source that stops delivering. Packet draining is linear rather than repeated
array-front removal. Device performance and long overlap behavior need runtime
validation; a timestamp rollback alone is not proof of a replay.

### Software retention and audio selection

When the software feeder falls behind evicted history, it parks before audio
look-ahead runs, then reuses the existing seek/flush/reanchor path at a retained
keyframe. A user seek, pause, stop or replacement wins over queued recovery.
Changing only the packet cursor would leave future samples on the old clock.

Audio selections coalesce and rebuild serially. Source generations invalidate
stale failures; play/pause during a rebuild supplies the final transport intent.
A native audio handover retains the old item until replacement, except after a
media-services reset. This avoids an unnecessary early surface teardown, but
makes no promise of a gapless switch.

The AV1 capability probe is evaluated only for AV1 routing, keeping decoder
registration out of unrelated H.264/HEVC startup paths.

### Timestamped, bounded still extraction

Resident previews return measured PTS, refinement status and a valid range from
existing native segment files or software packets. They do not seek playback or
open another source. Session and immutable-file identities reject stale results;
segment epoch normalization maps actual PTS back to the display timeline.
Resident extraction helpers are internal; the timestamped facade is public.
Cancellation reaches packet reads and decode loops. Elective extraction keeps
utility queue priority so it yields to playback under CPU contention.

`FrameExtractor.boundedSnapshot` exposes one caller-supplied `ProbeLimits` budget
for open, stream analysis, seek and decode. It uses counted readers and an I/O
cancellation deadline, rejects an already-open context and closes its disposable
context on completion. It returns an optional measured PTS instead of labeling
the requested time as a decoded timestamp. URL selection, when to request a
preview, cache UI behavior and budget values remain the client's responsibility.

## Resource limits and remaining proof

Native retention describes finalized segment payload, not init/subtitle data,
muxer staging, filesystem allocation overhead, AVPlayer buffers or recordings.
Mandatory playback segments can exceed the optional allowance. Software expiry
withdraws seek immediately when its snapshot is read and prunes on the next
append; it does not promise synchronous physical reclamation while no packets
arrive. Software I/O and decoder recovery retain their existing serialized
ownership. The native retention queue drains revisions so an update arriving
during pruning cannot be lost.

Regression coverage is included for retention admission/expiry, actual file
reclamation, default software opt-out, audio selection ownership, timestamp
rollback, replay discrimination/watchdog behavior, preview cancellation/PTS and
bounded HTTP open. Tests do not establish device acceptance or gapless playback.

The initial downstream commit received syntax and whitespace checks only.
During the 7.24.0 integration, compilation exposed an incorrect software-host
forwarding call: `setSoftwareLiveDVRLimits` must invoke the host's
`setLiveDVRLimits`, not the native-session setter. That call is corrected here.

## Upstream 7.24.0 integration

The release merges without textual conflicts. The only files changed by both
upstream and the original downstream commit are `AetherEngine.swift` and
`PlayerState.swift`; their changes affect separate sections. All upstream fixes
are retained:

- The ingest join now covers the served HLS holdback plus an open-GOP margin.
  This changes initial data acquisition, not the downstream caller-selected
  `seekToLiveEdge(offsetSeconds:)` contract. Both can use the same measured
  playlist target duration; no additional hardcoded return-to-live offset is
  introduced in the engine.
- Ingest playlist, segment and key requests participate in the existing origin
  budget. Known playlist URLs bypass the discarded raw probe. Caller load
  options, including optional software retention, survive that reroute.
- Display criteria cleared by the host are reapplied. This complements the
  downstream lifecycle observation and does not replace its audio or foreground
  transport-intent handling.
- Open-stage timing diagnostics are retained; bounded still extraction continues
  to use its existing budget and quiet still-extraction profile.

Local package validation is recorded for this integration below. It does not
establish iOS/tvOS device behavior, and upstream CI's Xcode 27 lanes remain a
separate validation surface.

The integration also completes the host-facing API documentation and changelog.
The capacity-renewal fixture now supplies a fresh caller deadline and verifies
that resubmitting an expired sample cannot renew it. The paused stacked-reload
fixture holds a controlled reader while observing the in-flight transport intent:
polling the transient loading state could otherwise miss a fast reopen and wait
until the test's time limit. Neither correction relaxes a production invariant.

Validation on macOS 26.6.2 arm64, Xcode 26.6 (17F113), Swift 6.3.3:

- `swift test --jobs 4` compiled the package, CLI, examples and test targets. The
  initial run found the documentation and capacity-fixture issues described above.
- After correction, the full `swift test --skip-build --jobs 4` run exited zero:
  689 XCTest cases (one optional live-source skip, zero failures) and 3,961 Swift
  Testing cases in 549 suites (30 optional fixture skips, zero issues).
- The updated public documentation, retention and audio lifecycle suites were
  also run during correction. The final full run includes those changes.
- A downstream package compiled against this source and passed all 125 tests,
  including a synthetic local MPEG-TS thumbnail test; none were skipped.
- The same 125 tests also passed after removing the local editable override and
  resolving the published integration commit
  `0d0a4157418cfa9ae23d511e6f432977be8a27a2` from the remote `develop` branch.
  The follow-up validation record changes documentation and trailing test-file
  whitespace only; production source and test assertions match that tested commit.
- `python3 Scripts/check-doc-links.py` and `git diff --check` passed.

The optional skips require external/synthetic media fixtures or a supplied live
AES-128 URL. They are not passing coverage. iOS/tvOS/visionOS simulator builds,
device playback, the standalone script regressions and the Xcode 27 CI lanes
were not run in this local validation.

Commands for validation with the supported Apple toolchain:

```sh
swift test --filter 'LiveDVRLimitsTests|SoftwareDVRRetentionTests|AudioSelectionOwnershipTests|LiveTimestampRollbackTests|LivePacketReplayGuardTests|Issue406NoCutWatchdogTests|BoundedFrameExtractorTests|FrameDecodeContextHardwareTests|PacketRingBufferTests|ScrubThumbnailSegmentMappingTests|Issue357BackgroundTeardownSelectionTests|Issue189LiveEdgeHoldbackTests|Issue460'
swift test
```

The existing CI workflow also specifies iOS/tvOS/visionOS simulator builds. For a
contribution, report results against the exact commit together with toolchain and
platform. On device, exercise long pause/eviction, capacity expiry, rapid audio
selection plus pause/stop, live timestamp resets and seek across those resets,
foreground restore, cancellation during stalled preview I/O and repeated return
to live. The fork's current branch is not an immutable source reference; consumers
must preserve the resolved commit and its source link for each distributed build.

## Upstream 7.25.1 integration

Upstream 7.25.0 adds process-wide audio-session, display-criteria and Now Playing
coordination for multiple engine instances. Upstream 7.25.1 makes a caller's
cancelled `load()` terminate promptly, including nested software reroutes, and
shortens teardown while a file-size probe is waiting. Both releases are merged
from the published upstream tag; the downstream APIs and resource policy remain.

Two textual conflicts required resolution. Reload error handling retains the
fork's cancellation check alongside upstream's generation check, so a cancelled
or superseded reopen is not published as a playback error. File-size discovery
retains the fork's bounded `SourceSizeProbeScope`: it cancels and joins sibling
requests before playback takes the origin slot. This already observes reader
closure while waiting; an unresolved result is logged only for an open reader.
A controlled probe checks its stop reason before the reader-close signal after
size discovery, so a deadline still reports `ProbeError.timedOut`.
The published upstream tests for load cancellation and shared output remain in
the fork alongside the existing source-open recovery tests.

Validation for this integration on macOS 27.0.1, Xcode 27.0, Swift 6.4:
`swift test --skip-build --jobs 4` completed 672 AetherEngine XCTest cases
(one optional fixture skip), 17 SMB XCTest cases and 4,017 Swift Testing
cases in 556 suites (31 optional fixture skips), with zero failures. The
package, CLI, examples and tests were compiled in
the preceding focused `swift test` run. The final full run followed the probe
error-classification correction. It does not establish iOS/tvOS device playback.

## Software subtitle presentation timing

`setSoftwareSubtitleDelay(_:)` applies a caller-supplied timing adjustment to both
subtitle channels in software PiP. Positive values delay subtitles and negative
values advance them, in media seconds against the presented frame PTS. The setting
survives engine loads and PiP transitions, rejects non-finite input, and does not
reopen the source or change A/V timestamps. Host overlays use the same adjustment
against `clock.sourceTime` and observe that clock directly.

This API does not change AVPlayer-owned native subtitle renditions (including
native PiP and AirPlay). Consumers must expose that capability limit instead of
claiming the native renderer applies an overlay-only timing adjustment.


## Upstream 7.25.2 integration

The published tag is merged with its ingest segment-duration seal, phase-equalised
join, readiness-aware native start and per-item audio/video diagnostics. Dependency
requirements are unchanged. Existing caller-configurable startup admission, live
retention, VOD source recovery and software subtitle timing APIs remain available.

The two conflicting regions were both in `VideoSegmentProvider`. The fork keeps
its existing successful-admission latch for ingest and raw sources, including
cancellation precedence and waking concurrent manifest waiters. The upstream
join-spent observation is read before the media snapshot, preserving its seal
ordering. A separate ingest-only latch is unnecessary. The upstream raw-source
latch test is adapted to this documented downstream contract; the first request
still pays its grace and subsequent requests do not repeat it. The HLS ingest
assertions remain unchanged. No live-edge holdback is reduced by this resolution.

Validation on macOS 27.0.1, Xcode 27.0 (27A266a), Swift 6.4: 194 focused
Aether tests passed (86 XCTest cases and 108 Swift Testing tests), covering all
seven AE#684 suites plus live admission/cadence/holdback, native readiness, source
timestamp rollback, seek capability and subtitle composition/channel selection.
The real AVPlayer fixtures also passed: both 5 s and 10 s GOP raw-TS scenarios
opened and became seekable in about 3.2–3.4 s, advanced normally, rewound and
returned to live; both VOD source-recovery/seek and sequential-source scenarios
passed. These are synthetic macOS measurements, not physical iOS/tvOS or provider
validation. No application build or application test suite was run.

## Upstream 7.28.3 integration

Includes 7.27.2 through 7.28.3: software audio diagnostics and EOF clock handling,
HEVC composition-offset repair and parameter-set preservation, partial keyframe
index validation, opt-in HDR Vivid detection, and H.264/HEVC repair across early
seeks onto open GOPs. The first-serve latch now defaults on for engine-cut live
sources upstream. The existing explicit downstream enable remains compatible;
startup admission thresholds and retention policies still belong to the caller.

The live-provider conflict keeps the caller-policy diagnostic and the upstream
latch semantics. The reload test uses upstream's state-observer synchronization,
which supersedes the earlier downstream controlled-reader fixture. No dependency
requirements or deployment targets are changed by this integration.


Validation on Apple M1 Pro, macOS 27.0.1 (26A434), Xcode 27.0 (27A266a),
Swift 6.4:

- `swift build --jobs 4` passed (library, CLI and compiled examples).
- `swift test --jobs 2` passed: 735 engine XCTest cases (one skipped),
  17 SMB XCTest cases, and the 4,137-case Swift Testing run. Optional external
  fixtures remain opt-in and are reported as skipped by the test runner.
- `Scripts/test-long-gop-startup.sh` passed both real AVPlayer cases: synthetic
  H.264/AAC MPEG-TS with 5 s and 10 s GOPs; first picture and usable seek range
  at about 3.28 s and 3.19 s, followed by rewind and return-to-live playback.
- `Scripts/test-vod-open-seek.sh` passed both real AVPlayer cases: synthetic
  H.264/AAC/SubRip MKV, bounded no-response recovery, forward/backward/paused
  seeking, and honest rejection of seeking on a sequential source.
- Source-recovery tests now use dedicated blocking-I/O workers and semantic
  request/cancellation assertions instead of scheduler-sensitive latency ceilings.
  Idle retention checks use the shared cancellable waiting helper; disposable
  snapshot fixtures are created in the temporary directory.

These checks cover the integrated fork revision. The focused upstream branches
have their own commit-level build and regression results in their PR test plans.


## Upstream 7.32.0 integration

The published release tag, rather than unreleased main, is the integration base.
Upstream includes the original contributions with the shared live/retention and
preview/cancellation integration fixes, plus serialized rebuild transport, held
pictures across audio switches, blocking work off the cooperative pool, HEVC
registration handling, optional progressive VOD segment delivery and explicit
segment-storage exhaustion reporting.

Conflicts were resolved to the release implementation after comparing the fork's
capabilities with the merged contributions. No duplicate downstream runtime patch
is retained. The former liveFirstServeLatchCoversEngineCut host override and
wireCommonHostSinks access widening are dropped; WUW uses the upstream latch
behavior and public contracts. Dependency ranges and deployment targets are
unchanged.


Validation on Apple M1 Pro, macOS 27.0.1, Xcode 27.0, Swift 6.4:

- `swift build --jobs 4` passed.
- `swift test --jobs 4` passed: 736 engine XCTest cases (one skipped),
  17 SMB XCTest cases and the 4,178-case Swift Testing run.
- Both long-GOP AVPlayer live cases passed (H.264/AAC MPEG-TS, 5 s and 10 s GOPs):
  picture and seekability at about 3.26 s / 3.18 s, then rewind and safe live return.
- Both AVPlayer VOD opening/seek cases passed (H.264/AAC/SubRip MKV): bounded
  no-response recovery, forward/backward/paused seeks, and sequential-source rejection.
- Consuming PlaybackKit: 191 XCTest cases, one skipped, no failures; the library
  and its Aether dependency also built for the tvOS 27 Simulator SDK.
- Consumer migration removes the obsolete first-serve override, uses the release's
  LoadOptions argument order, and handles storageExhausted without compatibility
  fallback. Consumer test fixtures publish SDK readiness directly rather than
  widening the engine's private host-sink helper.

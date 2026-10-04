# Downstream engine changes

Date: 2026-10-04. Current base: upstream 7.27.0,
`6f427d217001528befaf90b16a4bc20ae43f82c1`.
The original downstream commit was based on 7.23.2 and is preserved in history.

The changes in this fork remain under the LGPL v3 and Apple Store / DRM
Exception in [LICENSE](LICENSE). The incorporated GPL text is supplied in
[COPYING.GPL3](COPYING.GPL3). Original copyright notices are preserved.
Modified source files carry the modification date. These are general engine
APIs and fixes; application UI, support reporting, provider settings and
application resource budgets do not belong here.

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

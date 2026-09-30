# Downstream engine changes

Date: 2026-09-30. Base: upstream 7.23.2,
`95b7c31d67858dee9ec677a98507464943141b8b`.

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

No build or test execution was performed for this revision. Swift syntax parsing
and whitespace checks were performed; these do not type-check or link the code.
Previous results from an earlier downstream tree are not results for this commit.

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

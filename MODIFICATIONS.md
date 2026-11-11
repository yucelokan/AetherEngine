# Fork provenance and modification history

Updated: 2026-11-11. Integration base: upstream 7.58.0
(`7ea27bff8d8fb4a457d6e0042b0537eb31253583`).

## Current differences

One engine change taken from upstream ahead of its release, with one follow-up still open upstream;
otherwise the source matches 7.58.0 exactly, and this file and `COPYING.GPL3` are the only other
additions. Fixes made here are generic and go upstream as pull requests.

- The MPEG-TS header wait for a PAT program that never sends its PMT (2026-11-11): `Demuxer`
  releases `AVFMTCTX_NOHEADER` from its interrupt callback after 2.5 s of stream analysis that
  received data (a stall counts as at most 0.5 s) when one program still has no PMT and another has
  its PMT and an audio or video stream, and the `open timings` line reports how the analysis ended
  (`stop`, `unresolved`, `programs`, `pmtMissing`, `headerWait`, `probeBytes`, `closeToReturn`).
  Upstream: [#1020](https://github.com/superuser404notfound/AetherEngine/pull/1020) (merged as
  `b8b50f6cdc3aac6824e23909b12ea81a3c8b994e`), the maintainer's follow-up
  `b7e59a37f396025296ed852393967f23d36051c3` (the window runs on time the input delivered data,
  `stop=complete` became `stop=resolved`, cherry-picked here), and
  [#1038](https://github.com/superuser404notfound/AetherEngine/pull/1038) (open: only audio and
  video make a program ready). None of the three is in a release yet; 7.62.1 does not carry them.
  The header-wait code and its tests are identical to upstream's; the docs differ only where the
  7.58.0 docs layout does. Files: `Sources/AetherEngine/Demuxer/Demuxer.swift`,
  `Tests/AetherEngineTests/MissingPMTProbeReleaseTests.swift`, `DocumentedConstantsTests.swift`,
  `docs/api.md`, `docs/formats.md`, `CHANGELOG.md`. Drop this entry and take upstream's version at
  the integration of the first release that carries all three.

The fork's earlier upscale change (`DeferredFrameUpscaler`, 721b9ebc: the stage built off the main
actor, frames passing through until it is ready) was never offered upstream. Upstream fixed the
same freeze itself in 7.58.0 (AE#846: the stage builds on its own queue, a stage that cannot be
built switches itself off), and this integration takes upstream's version and drops the fork's.

Released upstream since the previous integration: the session callback release (PR #922, merge
`74f3a674d3cc18362a4d8c2f63e03f28259b9539`, in 7.52.0) and HLS byte-range segments (PR #928,
merge `a1a6508b`, in 7.53.0).

The fork's source-failure diagnostics landed upstream as PR #818
(merge `aa0bf3b3bda200196b8ad0edaf7481a5fe12cc3a`, released in 7.48.0), including its
second-review fix and the held HTTP/1 failing-hop follow-up.

No app identity, provider credentials, routing policy or UI behavior is embedded.

## Incorporated contribution and integration work

- #708: lazy AV1 capability probing.
- #709: software PiP subtitle delay, with required delay arguments at compositor call sites.
- #710: explicit pending foreground-video restoration.
- #711: serialized audio-track rebuilds; play/pause intent now survives every reconstruction,
  and the native surface can retain the outgoing picture during an audio switch.
- #712: configurable startup and early DVR history; resident fallbacks use the effective
  lease-driven window, and preview requests freeze the live-session shift.
- #713: bounded source opening/recovery preserves seekability; timing-sensitive regressions
  execute their blocking steps on dedicated threads.
- #714: opt-in retention leases and bounded software history, integrated with #712 publication.
- #715: conservative exact replay recognition; compressed packet buffers are hashed without
  an additional payload copy and unreachable side-audio admission was removed.
- #716–#717: measured, cancellable resident previews and bounded disposable snapshots;
  hardware-fallback recursion keeps both completion callbacks and superseded work is cancelled.
- #745: preserve the underlying custom-source probe cause; changelog placement corrected.
- #746: foreground-priority HTTP completion and idempotent origin tickets. The maintainer's
  `b141b147` follow-up charges a detour refusal once and preserves exponential pacing when
  Retry-After is absent.
- #747: paired replay admission, complete-picture replacement, untimed boundary quarantine,
  source/cache continuity and bounded native-video recovery. The maintainer's `7a6fc2f2`
  follow-up keeps legacy exhaustion notifications by default and makes both video-recovery
  halves opt-in.
- #748: renew a playlist whose segment duration outgrows its seal. Its upstream merge retains
  both recovery and renewal handlers and both current-position and replacement-URL arguments.

Consuming applications explicitly select `hostRetriesExhaustedLiveReplay` when they
handle retained-history retries and `nativeVideoFrameRecovery` when they request bounded
presentation repair. Both default to false. Application policy remains in the consumer.

## Earlier modification records and license

The earlier dated records, individual changes and validation limits remain in Git history:
[record before upstream integration](https://github.com/yucelokan/AetherEngine/blob/1d0450c116b6add7939e511f8630065b15dcebf7/MODIFICATIONS.md).

The original contribution series was based on 7.23.2. Subsequent updates integrated
published upstream releases; #748 was incorporated before the 7.37.0 release
and is included in the current 7.54.0 integration.

The engine retains its original copyright notices and the LGPL v3 and Apple Store / DRM
Exception in [LICENSE](LICENSE). The incorporated GPL text is in [COPYING.GPL3](COPYING.GPL3).
These provenance additions do not change the engine's licensing terms.

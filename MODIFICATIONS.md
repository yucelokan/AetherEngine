# Fork provenance and modification history

Updated: 2026-10-13. The integration base is upstream AetherEngine 7.36.0
(`c6365cc3c8850bdb670654ca26dcd21f73670875`), followed by the upstream merge of
PR #748 (`74c81b3c5a0047e1b0229805c20562910367b0e5`).

## Current differences

The runtime sources, tests, package/dependency declarations, examples and upstream
documentation match that upstream main commit. All fourteen contribution PRs
(#708–#717 and #745–#748), including maintainer integration changes and follow-ups,
are incorporated. The fork adds only this provenance record and `COPYING.GPL3`.
No application identity, retry budget, resource policy or UI code is added to the engine.

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
published upstream releases; the current merge also incorporates the post-7.36.0 #748
merge explicitly, rather than claiming it belongs to the published tag.

The engine retains its original copyright notices and the LGPL v3 and Apple Store / DRM
Exception in [LICENSE](LICENSE). The incorporated GPL text is in [COPYING.GPL3](COPYING.GPL3).
These provenance additions do not change the engine's licensing terms.

# Fork provenance and modification history

Updated: 2026-11-24. Integration base: upstream 7.74.0
(`7926810699f9b66422483258e0a486902531dfbe`, tag `7.74.0`). FFmpegBuild 3.19.0 (FFmpeg n8.1.3 unchanged).

## Current differences

One change, not offered upstream yet. Otherwise the source matches 7.73.0 exactly, and this file and
`COPYING.GPL3` are the only other additions. Fixes made here are generic and go upstream as pull
requests.

- Auth challenge, `Retry-After` and proxy facts on source network events (2026-11-17):
  `SourceNetworkDiagnostics.Event` gains `authChallenge` (`absent`, `www` or `proxy`, for a 401, 403
  or 407), `authScheme` (first token only, a fixed set), `retryAfterSeconds` and `proxyConnection`
  (on `metrics` events). No realm or header value is reported. Logging only; no change in playback.
  Upstream: not offered yet; it goes upstream once a suite run has passed it. Commit `05f0e686`.
  Files: `Sources/AetherEngine/Diagnostics/SourceNetworkDiagnostics.swift`,
  `Tests/AetherEngineTests/SourceNetworkDiagnosticsAuthFactsTests.swift`,
  `Tests/AetherEngineTests/Issue255BodyReserveTests.swift`, `docs/api.md`, `docs/source-map.md`,
  `CHANGELOG.md`.

Not taken since 7.73.0: the one-line change to `.github/workflows/used-by-add.yml` (an
upstream-only automation). The fork's push token has no `workflow` scope, so GitHub refuses a push that
changes a workflow file; the fork keeps its copy of that file. Take it with the next integration once the
token allows it.

Dropped in this integration: the fork's APAC encode pipeline test change (2026-11-12). Upstream fixed
the same flake itself in 7.66 to 7.70 (`6a8e7da2`, #1063: the two encodes are compared by decoded
audio), so the integration takes upstream's pipeline and test and the fork's seam is gone.

Released upstream in 7.65.0: the software decoder's playback thread cap, which the fork carried from
2026-11-12 (`SoftwareVideoDecoder` decodes on at most 16 threads):
[#1042](https://github.com/superuser404notfound/AetherEngine/pull/1042) (merged as
`75c08e8e`). This integration takes upstream's decoder, tests and changelog entry, so the fork's
entry is gone. The same release carries the HLS MIME declaration on the AE#154 reroute, offered from
the fork (fork PR #2, never merged into `develop`):
[#1040](https://github.com/superuser404notfound/AetherEngine/pull/1040) (merged as `50bae75a`).
The fork takes it from upstream, so fork PR #2 is superseded.

Released upstream in 7.63.0, integrated just before 7.64.0: the MPEG-TS header wait for a PAT
program that never sends its PMT, which the fork carried ahead of its release from 2026-11-11:
[#1020](https://github.com/superuser404notfound/AetherEngine/pull/1020) (merged as
`b8b50f6cdc3aac6824e23909b12ea81a3c8b994e`), the maintainer's follow-up
`b7e59a37f396025296ed852393967f23d36051c3` and
[#1038](https://github.com/superuser404notfound/AetherEngine/pull/1038) (merged as
`63937c0bd5b2e430318965751a79c9bf76913c86`). This integration takes upstream's `Demuxer.swift`,
tests, docs and changelog entry for it, so the fork's entry is gone.

The fork's earlier upscale change (`DeferredFrameUpscaler`, 721b9ebc) was never offered upstream.
Upstream fixed the same freeze itself in 7.58.0 (AE#846), and the 7.58.0 integration took
upstream's version and dropped the fork's. Earlier releases carried the session callback release
(PR #922, merge `74f3a674d3cc18362a4d8c2f63e03f28259b9539`, in 7.52.0) and HLS byte-range segments
(PR #928, merge `a1a6508b`, in 7.53.0).

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
and is included in the current 7.70.0 integration.

The engine retains its original copyright notices and the LGPL v3 and Apple Store / DRM
Exception in [LICENSE](LICENSE). The incorporated GPL text is in [COPYING.GPL3](COPYING.GPL3).
These provenance additions do not change the engine's licensing terms.

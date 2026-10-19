# Fork provenance and modification history

Updated: 2026-10-19. Integration base: upstream 7.42.0
(`f5af2a389695021af6f3aee86dfd8e485cc2c975`). The source-failure diagnostics
from fork `08e0feb63b5b106549c02882171df931d2b6256b` are retained.

## Current differences

- The length-less read-loss fixture waits for a successful open before cutting the
  body, so the regression measures a mid-read failure rather than an initial refusal.

- HTTP scheme dispatch is case insensitive.
- HLS ingest preserves terminal transport errors, segment retry failures and key HTTP
  refusals. Unsupported HLS formats and invalid/decryption failures have separate
  machine-readable kinds and stable error codes.
- Bounded body fetches expose response, redirect, timing and terminal events, including
  body-limit termination. Intentional refusal cancellation is not a transport error.
- Failed initial live probes preserve their original transport, HTTP or demux
  failure through publication and throwing. Runtime source-loss behavior is unchanged.
- Initial empty persistent/streaming responses retain URL error codes before waking
  the opening thread; a live HTTP refusal remains a typed HTTP status.
- Retiring a ranged connection clears its transport failure before a streaming
  replacement is judged; the replacement still reports its own failures.
- Demux NSError codes retain the historical open/stream-information/read case
  values. The original negative FFmpeg result is separate metadata, also exposed
  as optional `PlaybackErrorInfo.ffmpegErrorCode`; error messages are unchanged.
- Source diagnostic context is load identity: option corrections refuse a changed
  context before teardown and keep the original context during tuning rebuilds.
- Optional `SourceNetworkDiagnostics.handler` observes real reader response,
  redirect, completion and transaction metrics. It never changes request policy.
  Events include URLs for host-side correlation: hosts must redact them before
  persistence. No headers, payloads, or error descriptions are exposed by this API.
- HLS error diagnostics expose finite `HLSIngestDiagnosticReason` values through
  `HLSIngestError` and `PlaybackErrorInfo`, preserving the existing numeric codes,
  messages and error policy. Unknown reason text is mapped to a finite fallback.
- Hosts may supply opaque playback/attempt UUIDs through
  `LoadOptions.sourceDiagnosticsContext`. HLS readers and native carriage probes
  capture that context before creating requests and retain it through internal
  reloads. Late events cannot borrow a successor's identifiers; identifiers stay
  in process and do not become HTTP headers. The held HTTP/1 transport and carriage
  segment probes emit the same source-network event contract. Streamed persistent
  bodies retain that context until their actual completion, failure or cancellation;
  header delivery does not prematurely complete the diagnostic event.
- Regression tests cover mixed-case transport, HTTP refusal classes, connection
  refusal, nested URL errors, finite HLS causes, delayed request ownership,
  unattributed requests, header preservation and real request evidence. The exact
  historical HLS NSError codes are pinned for all cases, and diagnostic assertions
  filter by fixture identity so concurrent requests cannot change their results.

No app identity, provider credentials, routing policy or UI behavior is embedded.
The earlier fourteen contributions remain incorporated in the integration base.

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
and is included in the current 7.42.0 integration.

The engine retains its original copyright notices and the LGPL v3 and Apple Store / DRM
Exception in [LICENSE](LICENSE). The incorporated GPL text is in [COPYING.GPL3](COPYING.GPL3).
These provenance additions do not change the engine's licensing terms.

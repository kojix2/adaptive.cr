# CI and portable test validation

Local validation on 2026-11-01: Linux x86_64, Crystal 1.22.1, Python 3.14.4,
native POD5 0.3.49. An additional isolated Python 3.13.2 environment installed
the unmodified packages in `requirements.txt` for the official-client checks.

These results predate the development dependency policy change: application
builds now run `shards update` and track runtime dependencies on `main`, rather
than requiring the previously recorded lock commits.

## Checks performed

- `scripts/build.sh`: built `adaptive`, `adaptive-junction`, `adaptive-pod5`,
  and Ameba, using the unchanged `shard.lock`.
- `scripts/test.sh`: shell syntax, Crystal formatting, Ameba (23 files),
  24 Crystal specs, 12 portable Python tests, configuration validation, and
  Reject / Accept / Reject sequence replay passed. The two official-client
  tests explicitly skipped in the environment without that package.
- With the official client installed, both additional tests passed: unchanged
  ADC/calibration packaging and bounded failure when the server is unavailable.
- Moleflow integration: all 10 scenarios passed using real gRPC and minimap2
  with fixture basecalling: accept, reject, quota, observe, TLS, deadline,
  worker failure, shutdown, disconnect, and 512-channel quota.
  The same scenarios also passed against a freshly cloned and built Moleflow
  `ff8d569`, with its own locked dependencies and no local overrides.
- `scripts/package.sh`: archive creation, executable/source layout, exclusion
  of Python caches, and SHA-256 verified. Packaging uses portable staging and
  either `sha256sum` or `shasum`, without GNU tar's `--transform`.
- Actionlint 1.7.12, README JSON/link checks, and `git diff --check` passed.

The sandbox prohibits sockets; the integration tests were run with localhost
network access enabled. Dependency/build caches were redirected to `/tmp`.

## CI scope and limits

The workflow uses `ubuntu-latest` and `macos-latest`, Crystal `latest`, and
Python `3.x` with `check-latest: true`. Each job builds the app and a fresh
Moleflow checkout, runs the portable suite and integration, and packages the app.
Python's standard library is sufficient for this suite. The external serializer
is replaced only in its unit tests; live code still uses ONT's official client.

The pinned ONT client 7.13.6 [publishes wheels through CPython 3.13](https://pypi.org/project/ont-pybasecall-client-lib/7.13.6/#files),
not for newer Python. Consequently CI does not install that optional native
package. Install `requirements.txt` with a supported interpreter to enable its
two extra checks. There is no fallback pretending to perform real basecalling.

Local execution is Linux-only. The macOS job targets Apple Silicon (the current
[`macos-latest` runner](https://github.com/actions/runner-images)) and uses
Homebrew libraries. Native POD5 installers support macOS ARM64; Intel macOS
requires a separately built native POD5 library.

No GPU Dorado server or physical MinKNOW device was available. These checks
do not establish basecalling accuracy, enrichment, GPU capacity, sustained
throughput, or hardware compatibility. See [operations](operations.md) before
moving from observation to device actions.

## Stream termination regression (2026-11-01)

Hosted Ubuntu CI passed, while macOS built both apps and passed the unit tests
but failed a strict acknowledgment-count assertion in integration. The
[first failure](https://github.com/kojix2/adaptive.cr/actions/runs/41271162281)
reported 63 ACKs for 65 decisions (quota); the
[next run](https://github.com/kojix2/adaptive.cr/actions/runs/41271599939)
reported 71 ACKs for 73 decisions (reject).

Moleflow sends its final signal tick before ending the RPC and does not continue
processing actions afterward. The client can finish processing that signal and
submit an action before observing the stream end. Such actions cannot receive an
ACK. Adaptive already records them as unresolved and retains any quota
reservation. The test nevertheless required every decision to receive an ACK
for 16-channel runs, contradicting the existing shutdown contract.

Integration now checks unique action IDs, ACK/read/channel correlation, successful
statuses, exact unresolved counts, and confirmed/reserved quota accounting. It
still requires successful ACKs during ordinary active-stream scenarios. Unknown,
duplicate, failed, mismatched, and unaccounted ACKs remain failures.

A deterministic `stream_end` regression uses a test-only TCP proxy to delay
HTTP/2 END_STREAM delivery. All first signal prefixes arrive at Moleflow's final
tick, so 16 decisions remain unresolved, including one reserved but unconfirmed
accept. The previous assertion fails this scenario with `(0, 16)` on Linux too;
the corrected accounting passes. Five portable unit tests also cover the
accounting invariants. The integration suite now has 11 scenarios.

Local verification passed: 24 Crystal specs, 17 portable Python tests (plus two
explicitly skipped optional-client checks), all 11 integration scenarios,
formatting, Ameba, Actionlint, and `git diff --check`.

This correction changes test expectations, not device-control behavior. Hosted
verification is available in the repository's
[Test workflow](https://github.com/kojix2/adaptive.cr/actions/workflows/test.yml).

## Upstream receive flow control (2026-11-01)

After the termination correction, macOS passed the first ten integration cases,
including the deterministic stream-end regression. The
[512-channel case](https://github.com/kojix2/adaptive.cr/actions/runs/41272428071)
then exposed a separate upstream defect: `request stream receive buffer exhausted`.

`grpc.cr` rejected more than 256 coalesced requests or 128 responses before the
application had an opportunity to consume them. Deterministic upstream tests
reproduce both failures on the old implementation. The fix is upstream
[94c4507](https://github.com/kojix2/grpc/commit/94c4507ba5292d95ec3af24e5a57f44c4d1423dd):
both receivers now return HTTP/2 stream credit as messages are consumed, with
separate connection credit and support for incomplete messages exceeding the
window. The initial 65,535-byte window is unchanged.

Upstream verification passed 211 standard specs and 32 independent grpcurl
checks locally. Its [hosted CI](https://github.com/kojix2/grpc/actions/runs/41273903962)
also passed on Ubuntu/macOS, including grpcurl and GripMock. Both applications
obtain the published fix through their existing `main` dependencies; there are
no application-side pacing changes or enlarged receive-buffer limits.

Rebuilt both apps from the published upstream fix and reran local validation:
adaptive passed 24 Crystal specs, 17 portable Python tests, and all 11 integration
scenarios, including 512 channels with zero deadline fallbacks. Moleflow's full
suite also passed, including independent Python 3,000-channel/TLS and POD5 checks.

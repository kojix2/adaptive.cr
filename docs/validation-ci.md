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

macOS execution and hosted Actions results have not been verified locally;
this environment is Linux. The macOS job targets Apple Silicon (the current
[`macos-latest` runner](https://github.com/actions/runner-images)) and uses
Homebrew libraries. Native POD5 installers support macOS ARM64; Intel macOS
requires a separately built native POD5 library.

No GPU Dorado server or physical MinKNOW device was available. These checks
do not establish basecalling accuracy, enrichment, GPU capacity, sustained
throughput, or hardware compatibility. See [operations](operations.md) before
moving from observation to device actions.

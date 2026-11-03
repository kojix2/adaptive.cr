# Offline robustness validation: 2026-11-01

First adversarial validation round on Linux x86_64, using Crystal 1.22.2 for
the final builds. No sequencing instrument or Dorado server was used.

## Reproduced defects and fixes

### Adaptive action acknowledgment deadlines

Timeouts were checked only at the end of `Engine.advance`. A late ACK could
remove an expired operation and confirm its quota reservation before that
check. Worker completion and deadline fallback could also send another action
before the timeout was noticed.

The engine now checks the oldest outstanding operation before advancing,
processing results, accepting ACKs, and committing decisions. The final check
also catches a deadline crossed inside a slow custom policy. Expired operations
retain their reservations and stop the run; they are not confirmed or retried.
Four regressions cover late ACKs, worker completion, deadline fallback, and
slow policies. The first three reproduced failures in the original code.

### Upstream gRPC frame validation

Unsigned wire lengths exceeding the signed buffer/index representation could
overflow during conversion or header-size arithmetic. The incremental decoder
also used signed length arithmetic. Unsupported compression flags were not
rejected until their declared payload had arrived.

`grpc.cr` now shares header validation between the one-shot and incremental
decoders, before conversion, arithmetic, or payload buffering. Lengths above
`Int32::MAX - 5` return `RESOURCE_EXHAUSTED`; invalid flags return `UNIMPLEMENTED`.
The limit follows the existing buffer representation, not an increased queue
size or a new application-side workaround.

### Upstream gRPC malformed-stream handling

Malformed gzip payloads could leak `IO::EOFError` rather than a gRPC status;
an empty compressed payload was accepted despite containing no gzip member.
Header/decoding errors also finished local delivery without resetting the peer's
live RPC.

Malformed gzip is now an `INTERNAL` stream error; a valid gzip member containing
an empty message still works. Malformed metadata/DATA resets only its RPC, from
a separate fiber after the nghttp2 callback releases the connection lock.

Fourteen upstream regressions cover length boundaries and fragmented headers,
compression flags, incomplete valid frames, invalid gzip, corrupt trailers,
valid empty gzip, and deferred resets. Three tests send malformed responses
over real HTTP/2 and verify that a normal RPC still works on the same connection.

## Verification results

| Check | Result |
| --- | --- |
| adaptive.cr Crystal specs | 28 passed |
| Portable Python checks | 17 passed; 2 optional ONT-client checks skipped |
| Moleflow/adaptive integration | All 11 scenarios passed, including 512-channel quota, TLS, shutdown, disconnect, and deterministic stream end |
| grpc.cr standard specs | 225 passed |
| Independent grpcurl interoperability | 32 passed |
| Moleflow standard suite | 29 Crystal specs; plain/TLS, 3,000 channels, five edge cases, explicit slow-consumer termination, and POD5 interoperability passed |
| Formatting, adaptive Ameba, whitespace | Passed |

During initial validation, the applications were rebuilt against the sibling `grpc.cr/src` using
`CRYSTAL_PATH`. No installed dependency sources, dependency declarations, or
lock files were patched. This source selection was needed only before publishing
the upstream fix. Normal development builds fetch the published `main`.

For example, from `adaptive.cr`, with dependencies already installed:

```sh
export CRYSTAL_PATH="$PWD/../grpc.cr/src:$(crystal env CRYSTAL_PATH)"
crystal build src/main.cr --release -o bin/adaptive
crystal build examples/custom.cr --release -o bin/adaptive-junction
scripts/test.sh ../moleflow/bin/moleflow
```

Moleflow was likewise rebuilt with the sibling source path before integration.
The native POD5 binaries and dependencies were already installed. Localhost
socket access was enabled for integration and grpcurl tests.

## Soak checks

Before the corrected rebuild, `python3 scripts/stress.py 512 180` completed:
913.391 MB received, 232,033 chunks, 449 measured action responses; latency
p50 3.82 ms / p95 4.75 ms / p99 5.93 ms; server peak RSS 23.2 MiB and
second-half minimum RSS 19.8 MiB. Signal continuity and payload sizes passed.

The corrected rebuild also completed the same 512-channel, 180-second check:
913.390 MB received, 232,033 chunks, 449 measured responses; p50 3.85 ms /
p95 5.19 ms / p99 8.47 ms; peak RSS 23.2 MiB and second-half minimum RSS
19.5 MiB. Signal continuity and payload sizes passed. Other verification jobs
ran concurrently during this second check.

These are short regression checks, not a controlled before/after performance
comparison or evidence of multi-hour memory stability. They do not establish
GPU capacity, signal-to-sequence accuracy, physical unblock behavior, or
biological enrichment.

## Publication and follow-up validation

The upstream fix was published as gRPC commit
`e7127510e1beccb80de8d9bd6ad85b61d3f2ddc9`. Both applications resolve that
revision through their existing `branch: main` dependencies; their lock files
record the updated resolution without changing the branch policy.

Follow-up validation uses the normal `scripts/build.sh` and `scripts/test.sh`
commands, without the sibling-source override. The optional official ONT-client
tests also passed (all 19 Python checks, none skipped) using the installed client;
this verifies packaging and unavailable-server handling, not live basecalling.

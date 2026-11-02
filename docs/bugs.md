# Regression coverage

This index summarizes corrected behavior and the tests that protect it. Dated
results and reproduction details are in [CI validation](validation-ci.md) and
[offline robustness validation](validation-offline-2026-11-01.md).

| Area | Behavior protected by regression tests |
| --- | --- |
| [Decision engine](../spec/engine_spec.cr) | Check deadlines before actions and after slow policies; discard stale results; reserve quota before sending; confirm successful ACKs once; retain reservations after ACK timeouts; release reservations for definitely unsent actions. |
| [Live session](../spec/live_session_spec.cr) | Stop new work on RPC completion while draining ACKs; handle completion racing with ingestion, worker results and deadline fallback; propagate non-OK completion and unrelated send errors. |
| [Reference index](../spec/index_spec.cr) | Reject missing target contigs and multipart indices whose merged hit lists do not provide global MAPQ. |
| [Python bridge](../tests/test_bridge.py) | Fail immediately on a full server queue; do not resubmit ambiguous requests; validate signal calibration, framing and sequence output; preserve split molecules separately. |
| [CLI](../tests/test_cli.py) | Reject conflicting modes and incomplete diagnostic input; detect missing targets; write an end event on startup failure. |
| [POD5 export](../spec/pod5_export_spec.cr) | Preserve ADC and calibration; select reads by UUID; truncate prefixes; protect existing output; remove incomplete exports. |
| [Action accounting](../tests/test_integration.py) | Distinguish acknowledged, unresolved and unsent actions; reject duplicate or mismatched records and inconsistent quota totals. |

MinKNOW setup construction and explicit `auto_local_auth: false` handling are
fixed and tested in the upstream MinKNOW binding. gRPC framing, flow control,
receive limits and RPC completion belong to the upstream gRPC library. Adaptive
consumes those fixes through its dependencies, without maintaining local patches.

Operational behavior and remaining validation limits are documented in
[operations](operations.md). Use Git history for older implementation details
and release-specific dependency revisions.

# Design decisions

## Dorado integration

Adaptive uses a persistent Python adapter around the official
`ont-pybasecall-client-lib`, rather than implementing the server wire protocol in
Crystal. Dorado Basecall Server is installed separately from the `dorado basecaller`
CLI. Match client and server versions; see [operations](operations.md).

Each worker owns a client connection. The Crystal bridge writes JSON metadata
followed by raw int16 ADC bytes to the adapter's stdin, without base64 encoding
or starting Python for every job. Each submission has a new UUID, separate from
the MinKNOW read ID.
Queue-full responses and timeouts fail the job without adapter-level resubmission;
the next job uses a fresh connection after a failure. Split basecalls remain
separate sequences, since concatenation could invent a junction.

The original investigation consulted the [ONT server documentation](https://nanoporetech.com/software/other/dorado-basecall-server),
the pinned client's API and serializer, and the
[readfish Dorado adapter](https://github.com/LooseLab/readfish/blob/main/src/readfish/plugins/dorado.py).
Legacy [pyguppyclient](https://github.com/nanoporetech/pyguppyclient) protocol code
was also available, but was not evidence of compatibility with the chosen server.
Client packaging tests do not establish live server compatibility or basecalling
accuracy; no GPU Dorado server or physical MinKNOW device has been validated.

## Parallel mapping and state ownership

The [worker pool](../src/adaptive/pool.cr) shares an immutable minimap2 index and
uses `Fiber::ExecutionContext::Parallel` for CPU work. The binding allocates a
separate mapping buffer for each call. Build the index before opening the live
stream and do not manually finalize it while workers can use it.

The application [rejects multipart indices](../src/adaptive/index.cr), because
merging per-part hit lists does not recompute MAPQ across all competing hits.
This is a limitation of the binding path used here, not a general minimap2 defect.

The coordinator owns current read generations, bounded jobs, quota reservations
and ACK accounting. Workers return evidence without updating shared counters.
Before applying a result, the [engine](../src/adaptive/engine.cr) checks channel,
read ID, generation, terminal state and deadlines. RPC completion stops new work
while queued ACKs are drained; only requests known not to have been enqueued
release reservations without an ACK. See [regression coverage](bugs.md).

## Policy scope

Policies receive sequences, mappings with coordinates/strand/CIGAR, prefix length,
channel and read ID, per-read memory and run-level quota state. They can return
Continue, Accept or Reject without requiring a BED-based decision interface.
The [junction example](../examples/junction_policy.cr) uses evidence within each
split sequence and continues when more evidence is needed.

A policy can only use the prefix observed so far; it cannot infer an unseen
downstream feature with certainty. Performance must be measured with the actual
reference, signal, GPU and channel count. The examples provide a programmable
runtime, not a validated biological selection method. Exact resolved dependency
revisions are recorded in [shard.lock](../shard.lock).

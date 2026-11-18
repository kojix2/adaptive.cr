# Signal ownership and allocation benchmarks

The live path keeps decoded ADC chunks in an immutable `SignalPrefix`. Each
append adds a link to the previous prefix. Jobs copy the small prefix value,
sharing its chunks, rather than copying all preceding samples. Later appends
cannot change a job's prefix, including when a read is replaced or times out.
The GC retains chunks until the last state or job referencing them is gone.
Signal interpretation, coordinate frames and the canonical sequence source
are specified in [data-model.md](data-model.md).

`Engine#ingest` copies input by default so callers can reuse their buffers.
The live session passes `take_ownership: true`: the installed Protobuf reader
allocates each `raw_data` field independently, and the session never mutates
it afterward. Ownership transfer requires an exact owned allocation, not a
small view into a larger allocation or reusable transport buffer. Chunks
exposed by a prefix are read-only views.

`Job#signal` is now `Bytes | SignalPrefix`; existing flat `Job.new` calls still
work. `job.write_signal(io)` sends chunks in order through the existing binary
pipe protocol. It allocates temporary chunk descriptors for multi-chunk jobs,
but does not join or copy their ADC payload. `job.signal.to_slice` is an
explicit contiguous conversion, allocating payload storage for chunked jobs.
There is one link allocation per nonempty chunk; unusually small input chunks
therefore have higher metadata overhead than typical MinKNOW chunks.

`Engine#retained_signal_bytes` counts live states' signal payload plus job
prefixes whose states have been released. An active state and its job share
storage and are counted once. An obsolete job remains charged until its
result is consumed, even across further read replacements. `buffered_bytes`
counts state payload, while `inflight_bytes` counts job payload and may
overlap with states. Do not sum these two to estimate physical signal storage.
`max_buffer_bytes` limits retained signal payload; it is not an RSS limit and
does not include chunk metadata, queued transport responses, the minimap2
index and scratch memory, Python processes, or GC allocator overhead.

Bridge responses are read directly into one string allocation. Segment fields
reuse the strings produced by the JSON parser instead of serializing and
parsing each segment again. The optional `segments_only` request avoids
duplicate sequence content on the wire while retaining compatibility with
older clients and adapters. Quality validation scans a string's byte view;
representative-hit selection scans hits without building a temporary array.

## Reproduce

From the repository root, with dependencies and native minimap2 installed:

```sh
crystal run --release benchmarks/memory.cr
```

If the compiler's default cache is not writable, set `CRYSTAL_CACHE_DIR` to a
writable temporary directory. The benchmark requires neither MinKNOW nor
Dorado. It performs five warm-up iterations, collects GC, and reports the
change in `GC.stats.total_bytes`, elapsed time and a checksum. Input chunks
and response frames are created outside the measured loops. It does not
disable GC or measure native allocations, Python allocations, peak RSS, or
GPU transfers. Timings from one short run are not throughput guarantees.

The retained legacy signal benchmark reproduces the former `IO::Memory`
append plus whole-prefix `dup` operations. Both signal cases process ten
4,000-byte input chunks and observe all ten prefix sizes; the total observed
prefix size is 220,000 bytes per iteration. This comparison measures cumulative
allocations, not the peak memory of ten simultaneously retained snapshots.

## Recorded local results

Measured on 2026-11-18, macOS ARM64, Crystal 1.22.3, release builds. The initial
four cases were measured before optimization against source based on
`71f6be3`, after extracting the unchanged bridge response helpers so the
benchmark could call the production decoding path. The checksum for each
matching case remained unchanged.

| Case | Iterations | Allocated bytes before | Allocated bytes after |
| --- | ---: | ---: | ---: |
| Validate 100,000-base sequence and quality | 100 | 10,007,376 | 48 |
| Select representative from 64 hits | 10,000 | 220,958,816 | 0 |
| Decode combined response, about 300 KB | 100 | 159,651,872 | 60,175,072 |
| Retry rejected submission of 40 KB signal | 1,000 | 40,016,000 | 0 |

The negotiated segment-only response carries the same sequence and quality
in about 200 KB and allocated 40,147,904 bytes over 100 decodes. In the
side-by-side signal benchmark, 1,000 iterations allocated 347,390,384 bytes
for the legacy implementation and 478,896 bytes for shared prefixes.

Raw output: [before](memory-before.txt), [after](memory-after.txt).

Regression coverage includes concurrent append/read with GC, borrowed input
reuse, read replacement, orphaned-job budgets, deadline fallback, duplicate
completion, binary chunk order, response boundaries, malformed optional
fields, split segments, legacy responses and the negotiated wire format.
At the initial optimization checkpoint, the full Crystal suite passed 94
examples. The Python suite passed 25 tests
with two optional official-client tests skipped because ONT/NumPy were not
installed. Moleflow integration passed all 11 scenarios, including 512
channels, using real gRPC/minimap2 with a synthetic basecaller. Raw integration
output is in [memory-integration.txt](memory-integration.txt).
Final review results, including typed UInt64 response decoding, are recorded
in [data-model.md](data-model.md#verification-and-sources).

The current changes do not reuse minimap2's native scratch buffers or bound
the application receive queue by bytes. Those remain separate opportunities
that need native-memory and end-to-end measurements with the real basecaller.

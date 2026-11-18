# Signal, sequence and alignment semantics

## Signal format and units

The supported live input is signed, little-endian, 16-bit uncalibrated ADC
signal (`adc_int16_le`). Before opening the live-read RPC, `Live` queries
MinKNOW `get_data_types()` and rejects absent, unsigned, floating-point,
big-endian or non-16-bit ADC descriptions. It does not reinterpret an
unsupported stream as ADC samples.

`SignalPrefix` enforces whole two-byte samples at every append. It shares
immutable chunks; chunk boundaries have no biological meaning. `size` is
bytes and `samples` is samples. The transfer-of-ownership contract in
[memory.md](memory.md) still applies.

`Job#context` is one `SignalContext` containing:

| Field | Meaning |
| --- | --- |
| `start_sample` | Absolute sample index since acquisition started |
| `sample_rate` | Samples per second, finite and positive |
| `offset` | ADC offset used before scaling |
| `scale` | Positive scale for ADC-to-pA conversion |

The conversion is `(adc + offset) * scale`. Jobs validate their context and
sample alignment, and `job.samples` is derived from the signal byte size.
Live calibration and sample rate are captured at startup; acquisition settings
and calibration must remain stable during a session. Restart the session after
changing them.
The bridge request and handshake declare `adc_int16_le`; legacy adapters may
omit the handshake field. The older scalar `Job.new` constructor and metadata
getters remain supported. To change a job context, use
`job.copy_with(context: job.context.copy_with(scale: new_scale))`.

## Coordinates and provenance

These coordinate systems are distinct:

| Value | Unit and coordinate frame |
| --- | --- |
| `Job#start_sample` | Absolute acquisition sample index |
| `BasecallResult#input_samples` | Length of the submitted signal prefix |
| `BasecallSegment#signal_span` | `[start_sample, end_sample)` relative to that submitted parent signal |
| `Mapping#query_start`, `query_end` | Zero-based half-open base interval within one basecall segment |
| `Mapping#target_start`, `target_end` | Zero-based half-open base interval within the reference contig |

`Evidence#samples` remains the input prefix sample count. For sequence-only
analysis with no signal, the existing zero default remains; optional
`BasecallResult#input_samples` distinguishes an unknown count from a known
count. Known counts must agree when constructing evidence.

`SampleInterval` rejects reversed intervals. Basecall results reject intervals
beyond a known input prefix, and a nonempty sequence cannot claim an empty
signal interval. A missing interval means unknown, not zero or the whole
prefix. Sequence lengths and arrival order do not establish signal boundaries.
The current official-client adapter leaves normalized intervals unknown.

Native sample-valued `start_time`, `duration`, `trimmed_samples` and
`trimmed_duration` are preserved under `native_timing` as optional unsigned
integers. Their presence does not establish how splitting/trimming transforms
them into parent-relative coordinates. In particular, neither these fields nor
an interval alone provides a per-base signal mapping; that requires movement
information and its coordinate/stride contract. No movement table is invented.

The original MinKNOW parent ID remains `BasecallResult#read_id`. In official
client 7.13.6, metadata `read_id` identifies the submitted input, and
`strand_id` identifies a split output. `BasecallSegment#read_id` preserves the
latter, with a fallback for legacy clients that lack it. The transport request
UUID is used only for correlation. A split segment is not proof of a separate
physical molecule.

## Alignment classification

`Mapping` retains native primary, secondary and inversion facts.
`classification` derives `Primary`, `Secondary` or `Supplementary` from the
known primary/secondary flags. A legacy non-primary record lacking secondary
information has classification `Unknown`, rather than being guessed to be a
supplementary alignment. Contradictory primary+secondary facts are rejected
when validating mappings or decoding JSON.

`secondary?` and `supplementary?` identify known positive classifications;
inspect `classification.unknown?` when the distinction matters. These flags
survive JSON round trips. A policy deciding between alternative mappings and
split alignments should use them explicitly. The existing built-in `any` and
`primary` selection modes retain their decision rules.

Evidence validates segment indices, query bounds and reference coordinate
ordering. CIGAR remains associated with its segment and strand. Regression
checks cover real minimap2 mappings of forward/reverse queries and queries
with insertions/deletions, including query/reference consumption lengths.

## Canonical sequence ownership

When basecalls exist, their private segment array is the sole retained source
of sequence, quality, child identity and provenance. Constructors snapshot
caller arrays and expose segments through a read-only slice. Strings are
shared without copying their payload. `sequences` returns a fresh compatibility
array, so replacing its entries cannot disconnect sequence from quality or
provenance. Internal mapping/policy code uses segments, `each_sequence` and
`base_count` directly.

Sequence-only evidence owns one private sequence array. `Evidence` never
retains a second sequence array alongside basecalls. JSON still emits the
legacy `sequences` projection for compatibility, directly from the canonical
source, and accepts older combined representations only if both agree.
JSON decoding applies the same identity, sample-count, span and segment-index
checks as ordinary construction.

## Verification and sources

`spec/domain_spec.cr` covers format rejection, signed ADC extrema, sample
counts, context validation, alignment classifications, legacy unknown flags,
interval bounds, JSON compatibility, mutation isolation and real alignment
coordinate/CIGAR checks. Python tests exercise the official parent/child ID
layout and preserve native timing without generating inferred intervals.

The fixed-version client contract was checked by reading the Python source
and library descriptions in the SHA-256-verified official 7.13.6 wheel,
without installing or executing that wheel. Its `pyclient.py` documents that
each completion sub-list contains all splits, and `helper_functions.py`
exports `strand_id` as child ID and `read_id` as parent ID.

- [MinKNOW signal and data-type specification](https://github.com/nanoporetech/minknow_api/blob/master/proto/minknow_api/data.proto)
- [Official pinned ONT client distribution](https://pypi.org/project/ont-pybasecall-client-lib/7.13.6/)
- [Dorado signal, trimming and split-read tags](https://software-docs.nanoporetech.com/dorado/latest/basecaller/sam_spec/)
- [minimap2 native alignment structure](https://github.com/lh3/minimap2/blob/master/minimap.h)

The native timing fields are deliberately not assigned normalized split
coordinates based on CLI SAM tags: those tags and the Basecall Server client
interface are separate contracts.

Basecall frames use a typed `BasecallResponse` decoder, rather than routing
sample-valued metadata through `JSON::Any` (whose integers are limited to
`Int64`). The production frame decoder and JSON round trips preserve
`UInt64::MAX` without narrowing or converting it to a float. Frame parsing
also rejects a second JSON value after the response object.

Final review on 2026-11-18 passed 106 Crystal examples, 26 Python tests,
format/lint checks and all 11 Moleflow integration scenarios (including 512
channels). Two optional tests needing installed ONT/NumPy were skipped.
CLI, GUI, POD5 and custom-policy release builds succeeded. Six Molefarm
completed-read tests also passed with this working tree first on
`CRYSTAL_PATH`, without modifying Molefarm or its installed dependencies.
Integration uses real gRPC/minimap2 with a synthetic basecaller, not a live
Dorado/GPU. Output: [domain-integration.txt](domain-integration.txt).

The release allocation benchmark still reports zero additional allocation
for 1,000 rejected 40 KB submissions. The canonical `base_count` path also
allocated zero bytes over 10,000 calls. Combined and segment-only response
decoding remained about 60.2 MB and 40.1 MB per 100 iterations, respectively.
These are cumulative Crystal allocations, not peak process memory. Output:
[domain-memory.txt](domain-memory.txt).

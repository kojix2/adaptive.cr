# Basecall results

`Bridge#basecall(job)` returns `BasecallResult`, associating the original
`Job#read_id` with an ordered, read-only view of `BasecallSegment` values. Each segment
holds a sequence, optional per-base quality string and optional basecaller read
identifier. Split segments remain separate, and `Hit#segment` indexes that
array. The constructor snapshots the supplied segment array. Missing qualities
remain `nil`; no placeholder qualities are generated.
Sequence/quality lengths and quality characters are validated at the adapter
boundary. `Bridge#call` remains the sequence-only compatibility view.

The Python protocol returns both `sequences` and `segments` by default. The
Crystal bridge requests `segments_only: true` to avoid sending the sequence
twice; older adapters may ignore this optional request field. The Crystal
bridge accepts segment-only, combined and older sequence-only responses,
and checks consistency when both fields are present. Correlation uses a
per-call transport identifier; `BasecallResult#read_id` preserves the original
parent read identity rather than exposing that identifier as the parent read.
Basecall frames are decoded directly into `BasecallResponse`, preserving the
full `UInt64` domain of sample-valued metadata without a generic JSON integer
intermediate.
For pinned official client 7.13.6, segment IDs come from `strand_id`; its
`read_id` identifies the input parent. Legacy adapters may omit `strand_id`.
Each `get_completed_reads()` sub-list contains all splits of one original
read. Split segments are not automatically distinct physical molecules.

Actual bridge results retain `input_samples` and the job's `SignalContext`.
`signal_span`, when known, is a zero-based half-open interval in samples
relative to the submitted parent signal. Missing spans remain `nil`, including
for fixtures. The Python adapter preserves native `start_time`, `duration`,
`trimmed_samples` and `trimmed_duration` under `native_timing` when present;
it does not infer a parent-relative interval from these values. See the
[coordinate and provenance model](data-model.md).

`Config#bridge_max_signal_bytes` defaults to 500,000 bytes, preserving the
prefix-processing limit. `Job.new` accepts either contiguous `Bytes` or an
immutable `SignalPrefix`. Use `job.write_signal(io)` to stream either form
without joining chunks; `job.signal.to_slice` explicitly materializes
contiguous bytes for chunked jobs. Explicit full-read consumers may raise this to an
even value up to 64 MiB. The same bound is enforced before sending ADC and by
the Python adapter's `--max-signal-bytes` argument. The live coordinator's
sample, memory and decision limits are unchanged.

`bridge_max_response_bytes` similarly bounds both sides of the JSON response
protocol (default 2 MiB, maximum 64 MiB). Full-read consumers should size it for
sequences, qualities and any compatibility fields, rather than just sequence size.

`mapper.map(basecalls, channel: channel)` maps the canonical segments directly,
using their parent ID and known input sample count unless explicitly supplied.
`Evidence#basecalls` carries these results through worker mapping. Sequence
mapping also accepts optional `basecalls:` and checks that molecule identity
and sequence order match. `Mapping`, `Hit`, `Decision`, `Evidence`, and basecall
result types support JSON round trips, retaining CIGAR, strand, coordinates,
tags, split-segment association and quality for downstream output consumers.
Display-hit selection and the policy's decision hit remain independent.
`Evidence#sequences` and `BasecallResult#sequences` return independent arrays of
shared immutable strings. Internal policies use `each_sequence`/`base_count`
without those arrays. The compatibility JSON `sequences` field is generated
from the same canonical source; conflicting legacy duplicated fields are rejected.

# Basecall results

`Bridge#basecall(job)` returns `BasecallResult`, associating the original
`Job#read_id` with an ordered array of `BasecallSegment` values. Each segment
holds a sequence, optional per-base quality string and optional basecaller read
identifier. Split segments remain separate, and `Hit#segment` indexes that
array. Missing qualities remain `nil`; no placeholder qualities are generated.
Sequence/quality lengths and quality characters are validated at the adapter
boundary. `Bridge#call` remains the sequence-only compatibility view.

The Python protocol retains its `sequences` field and adds `segments`. The
Crystal bridge also accepts older sequence-only responses. Correlation uses a
per-call transport identifier; `BasecallResult#read_id` preserves the original
molecule identity rather than exposing that identifier as the parent molecule.

`Config#bridge_max_signal_bytes` defaults to 500,000 bytes, preserving the
prefix-processing limit. Explicit full-read consumers may raise this to an
even value up to 64 MiB. The same bound is enforced before sending ADC and by
the Python adapter's `--max-signal-bytes` argument. The live coordinator's
sample, memory and decision limits are unchanged.

`bridge_max_response_bytes` similarly bounds both sides of the JSON response
protocol (default 2 MiB, maximum 64 MiB). Full-read consumers should size it for
sequences, qualities and compatibility fields, rather than just sequence size.

`Evidence#basecalls` carries these results through worker mapping. Sequence
mapping also accepts optional `basecalls:` and checks that molecule identity
and sequence order match. `Mapping`, `Hit`, `Decision`, `Evidence`, and basecall
result types support JSON round trips, retaining CIGAR, strand, coordinates,
tags, split-segment association and quality for downstream output consumers.
Display-hit selection and the policy's decision hit remain independent.

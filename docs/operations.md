# Operations

This is a research implementation. GPU Dorado basecalling, physical MinKNOW
operation and biological selection accuracy require validation in your environment.
See [validation](validation-ci.md) for the checks performed so far.

## Prepare the environment

Install the build dependencies in the [README](../README.md), then run from the
project root:

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
scripts/build.sh
PATH="$PWD/.venv/bin:$PATH" scripts/test.sh
```

Choose a Python interpreter supported by the pinned packages in
`requirements.txt`; the latest Python used by mise or CI may differ. Offline
replay and fixture tests do not require the optional ONT client. Its two tests
report a skip when it is unavailable.

Install Dorado Basecall Server, GPU drivers and models separately. Match the
client version to the server and check the server's own `--version`, separately
from the Dorado basecaller CLI. Revalidate the combination after changing versions.
Choose a model suitable for the flow cell, kit and sample rate; Adaptive does not
automatically check that compatibility.

## Check configuration and reference

Adapt the README's `run.json`. Set `reference`, and `targets` for the contig policy.
Check the MinKNOW position port, channel range, TLS, Dorado address and model.
Set `python` to `.venv/bin/python` and begin with `observe: true`.
Relative paths resolve from the **current working directory**, not the config file.

For TLS, set `tls: true` and provide `ca_file` when needed. Authentication metadata
can be supplied through `MINKNOW_AUTH_TOKEN` and `PROTOCOL_TOKEN`. Adaptive disables
automatic local-token discovery; configure authentication explicitly if required.

```sh
bin/adaptive -c run.json --validate
bin/adaptive -c run.json --check-backend
```

Validation checks configuration, the reference index and target contigs.
The backend check connects through the Python adapter and reports client version
information; it does not independently verify the server version or basecall a read.
Keep `allow_test_bridge` and `fixture_sequence` out of production configurations.

## Check a real signal prefix

Use headerless, little-endian signed int16 ADC samples, rather than calibrated
floating-point pA values. The diagnostic accepts 100–250,000 samples. To extract
a prefix and its original calibration from POD5 into a new directory:

```sh
scripts/pod5.sh input.pod5 prefix --samples=20000
bin/adaptive -c run.json --check-signal=prefix/prefix.i16 \
  --signal-metadata=prefix/prefix.json > basecall-check.json
```

Use `--read-id=UUID` to select a POD5 read. Extraction decodes a full read and
rejects reads longer than 10 million samples before allocating the signal buffer.

For a prefix prepared elsewhere, supply matching calibration metadata:

```json
{"offset": -12.5, "scale": 0.14, "sample_rate": 5000.0, "start_sample": 1234}
```

Replace these example values with the signal's own metadata. `scale` is the
channel range divided by digitisation; `start_sample` is the sample index from
the start of the run. Successful output contains basecalled sequences, preserving
split results separately. Compare them with known sequences or a reference;
this diagnostic checks communication, not basecalling accuracy. Keep real signals
and sequences separate from distributed synthetic test fixtures.

## Start in observation mode

Start an appropriate MinKNOW run, then launch Adaptive with `observe: true`:

```sh
bin/adaptive -c run.json
```

Check backend, model, client version, sample rate and reference in `start`.
Inspect `worker_ms`, `policy_ms`, base and hit counts in `evaluation`, and
`elapsed_ms` and reasons in `decision`. Frequent `decision_deadline` or
`worker_error` events call for checking the backend and tuning workers, prefix
length or deadlines against the actual reference, GPU and channel count.
The 512-channel fixture test does not measure GPU capacity.

After checking decisions, choose a new log path and set `observe: false`.
Accept stops signal delivery while sequencing continues; Reject unblocks for
0.1 seconds. Quotas count accepted and reserved reads, not coverage or completed
full-length molecules.

## Stop and inspect failures

Ctrl-C or SIGTERM stops the run. Normal completion returns 0; fatal configuration,
connection or processing errors return 1. Individual basecaller job failures
preserve the molecule and allow the run to continue, so also inspect the audit log.

| Event or reason | Meaning and response |
| --- | --- |
| `decision_deadline` | Decision time expired; preserve the molecule. Check prefix length, load and deadline. |
| `signal_gap_or_overlap` | Discontinuous signal; preserve the molecule. Check the first chunk and stream. |
| `signal_budget`, `sample_limit` | Signal storage or evaluation limit reached; preserve the molecule. |
| `worker_error` | Basecalling or mapping failed. Check the preceding error, backend and queues. |
| `stale_result` | Result belongs to a superseded or terminal read; do not use it for an action. |
| `ack` status=0 | MinKNOW reported success; this does not prove full-length molecule acquisition. |
| `ack` status≠0 | Action failed; release its reservation without automatically retrying it. |
| `action_unsent` | RPC completion prevented enqueueing; release its reservation and count it as unsent. |
| `error` | Fatal run error; also inspect stderr. |
| `end` | Outcome is `stream_end`, `signal` or `error`; inspect reservations, `unacknowledged_actions` and `unsent_actions`. |

An ACK timeout stops the run while retaining the reservation: the action may
already have been applied. Do not treat it as successful or automatically resend
it. Unresolved actions are not carried into the next run. Logs require a new
path and refuse to overwrite existing files. Save stderr too, because disk errors
can prevent the final log entry.

Custom Crystal policies are trusted compiled code. A blocking policy delays the
coordinator; a late Reject becomes Accept when the policy returns. Running C
code and policies that never return cannot be forcibly interrupted by this check.

## Reproduce and package

Run `scripts/test.sh /absolute/path/moleflow/bin/moleflow` for integration against
a separately built Moleflow. It uses synthetic sequences and fixture basecalling
with real gRPC, TLS, minimap2, action responses and shutdown handling.

Development builds run `shards update` and follow dependency `main` branches.
`shard.lock` records the last resolution; the standard build does not preserve
those exact commits automatically.

`scripts/package.sh` creates a source/binary/documentation archive and a SHA-256
checksum. Python packages, Dorado, models, GPU runtimes and real data are not bundled.

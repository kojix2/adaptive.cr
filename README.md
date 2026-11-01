# adaptive.cr

Programmable adaptive sampling in Crystal using MinKNOW Read Until, Dorado
Basecall Server, and minimap2. Basecall cumulative signal prefixes, map the
sequences, and apply a Crystal policy to **Continue**, **Accept**, or **Reject**
each read. No BED file is required.

Crystal handles streaming, parallel processing, decisions, and JSONL audit logs.
Each worker connects to Dorado through a persistent official-client Python adapter.

**Version 0.3.0 is a research release.** Tests use Moleflow with real gRPC and
minimap2 but a fixture basecaller. GPU Dorado, physical MinKNOW devices, selection
accuracy, and sustained throughput remain untested.

## Build

Requires Crystal >= 1.22.0, Python >= 3.11 (tested with 3.12), C/C++20 build tools,
and the native libraries below. With mise on Debian/Ubuntu:

```sh
sudo apt-get install build-essential pkg-config libnghttp2-dev libssl-dev zlib1g-dev libyaml-dev curl tar unzip patch
mise install
mise exec -- shards install
mise exec -- python -m venv .venv
. .venv/bin/activate
python3 -m pip install -r requirements.txt
mise exec -- scripts/build.sh
```

Initial setup downloads dependencies and builds native minimap2 and POD5 libraries.
`shard.lock` records resolved commits. Install Dorado Basecall Server, models, and
GPU drivers separately. The server is distinct from the `dorado basecaller` CLI;
match its version to the Python client (`requirements.txt` pins 7.13.6).

## Try offline

Run from the project root; relative paths use the current working directory.

```sh
bin/adaptive --validate
bin/adaptive --replay=examples/replay.jsonl
```

The synthetic host/virus example produces **Reject / Accept / Reject**, with the
last read rejected because the virus acceptance quota is one. Replay uses
sequence JSONL, without Dorado or MinKNOW.

## Run live

Start Dorado with a model matching your flow cell, kit, and sample rate. Save this
as `run.json` and adapt it to your environment. Use the MinKNOW **position service
port** and a single-part minimap2 index.

```json
{
  "host": "127.0.0.1",
  "port": 10001,
  "tls": true,
  "ca_file": "/data/rpc-certs/minknow/ca.crt",
  "reference": "/absolute/path/reference.mmi",
  "dorado_address": "ipc:///tmp/.guppy/5555",
  "dorado_model": "dna_r10.4.1_e8.2_400bps_5khz_fast",
  "python": ".venv/bin/python",
  "policy": "contig",
  "targets": ["target_contig"],
  "quota": 0,
  "observe": true,
  "log": "run-001.jsonl"
}
```

```sh
bin/adaptive -c run.json --validate
bin/adaptive -c run.json --check-backend
bin/adaptive -c run.json
```

`--check-backend` checks connectivity, without basecalling. Start with
`observe: true` to log decisions without device actions; set it to `false` after
validation. Accept stops signal delivery while sequencing continues; Reject
unblocks; Continue waits for more signal. Quotas count acknowledged acceptance
actions, not coverage. Use a new log path per run; stop with Ctrl-C or SIGTERM.

See [operations](docs/operations.md) for authentication and failure handling, and
[Config](src/adaptive/config.cr) for all settings and defaults.

## Signal diagnostics and custom policies

Extract a calibrated ADC prefix from POD5 and basecall it without MinKNOW:

```sh
sh scripts/pod5.sh real.pod5 diagnostic --samples=20000
bin/adaptive -c run.json --check-signal=diagnostic/prefix.i16 --signal-metadata=diagnostic/prefix.json
```

The exporter decodes a full read and rejects reads over 10 million samples.
Sequence replay uses JSONL; for live signal replay, use Moleflow.

Built-in policies are `contig`, `motif`, and `all`. To customize decisions,
subclass `Adaptive::Policy` and implement `decide`; see
[custom.cr](examples/custom.cr) and [junction_policy.cr](examples/junction_policy.cr).
Policies receive split sequences and minimap2 hits. They run on the coordinator,
so keep them fast. The build creates `bin/adaptive-junction` for the custom example.

## Validation

```sh
mise exec -- scripts/test.sh
# Add integration tests with a separately built Moleflow:
mise exec -- scripts/test.sh /absolute/path/moleflow/bin/moleflow
```

The [validation record](docs/validation-v0.3.0.md) documents 23 Crystal specs,
13 Python tests, and 10 integration scenarios on Linux x86_64 / Crystal 1.22.0.
Signal gaps, worker errors, and decision deadlines preserve the molecule. Stale
results are discarded; action acknowledgment timeouts stop the run. Deadlines
are not hard real-time guarantees, and signal memory limits do not bound RSS.

License: [MPL-2.0](LICENSE). See [NOTICE.md](NOTICE.md) for third-party notices.

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

Requires Crystal >= 1.22.0, Python >= 3.11, C/C++20 build tools, and native libraries.
On Debian/Ubuntu:

```sh
sudo apt-get install build-essential pkg-config libnghttp2-dev libssl-dev zlib1g-dev libyaml-dev curl tar bzip2 unzip patch
```

On macOS (Apple Silicon, with Xcode Command Line Tools):

```sh
brew install pkg-config libnghttp2 openssl@3 libyaml
export PKG_CONFIG_PATH="$(brew --prefix libnghttp2)/lib/pkgconfig:$(brew --prefix openssl@3)/lib/pkgconfig:$(brew --prefix libyaml)/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export LIBRARY_PATH="$(brew --prefix libnghttp2)/lib:$(brew --prefix openssl@3)/lib:$(brew --prefix libyaml)/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"
```

Then build with mise (latest Crystal and Python):

```sh
mise install
mise exec -- scripts/build.sh
```

Initial setup downloads dependencies and builds native minimap2 and POD5 libraries.
Runtime dependencies track `main`. Development builds run `shards update` to use
their latest commits; `shard.lock` records the most recent resolution. Offline
replay and fixture tests need only Python's standard library. Native POD5 downloads
support Linux x86_64/ARM64 and macOS ARM64; Intel macOS requires building POD5
from source.

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

Install Dorado Basecall Server, models, and GPU drivers separately. The server is
distinct from the `dorado basecaller` CLI. Install `requirements.txt` in a virtual
environment using a Python supported by the official client, and match the client
to the server version. The pinned client 7.13.6 has wheels through Python 3.13,
so latest Python is suitable for fixture tests but may not run this live client.
See [operations](docs/operations.md) for setup.

Start Dorado with a model matching your flow cell, kit, and sample rate. Adapt
this `run.json` to your environment. Use the MinKNOW **position service port**
and a single-part minimap2 index.

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

See the [current validation record](docs/validation-ci.md) and the
[original v0.3.0 results](docs/validation-v0.3.0.md).
The CI workflow targets `ubuntu-latest` and `macos-latest`, with latest Crystal
and stable Python, covering builds, lint, specs, replay, Moleflow integration,
and packaging. Official-client checks are explicitly skipped unless
`requirements.txt` is installed; protocol, timeout, and fixture tests still run.
Signal gaps, worker errors, and decision deadlines preserve the molecule. Stale
results are discarded; action acknowledgment timeouts stop the run. Deadlines
are not hard real-time guarantees, and signal memory limits do not bound RSS.

License: [MPL-2.0](LICENSE). See [NOTICE.md](NOTICE.md) for third-party notices.

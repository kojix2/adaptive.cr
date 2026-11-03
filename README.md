# adaptive.cr

[![Test](https://github.com/kojix2/adaptive.cr/actions/workflows/test.yml/badge.svg)](https://github.com/kojix2/adaptive.cr/actions/workflows/test.yml)
[![Lines of Code](https://img.shields.io/endpoint?url=https%3A%2F%2Ftokei.kojix2.net%2Fbadge%2Fgithub%2Fkojix2%2Fadaptive.cr%2Flines)](https://tokei.kojix2.net/github/kojix2/adaptive.cr)

Programmable adaptive sampling using MinKNOW Read Until, Dorado Basecall Server
and minimap2. A Crystal policy chooses **Continue**, **Accept** or **Reject**.
Each worker uses a persistent official-client Python adapter for basecalling.

## Build

Requires Crystal >= 1.22, Shards and C/C++20 build tools. Run from the repository root:

```sh
# Ubuntu
sudo apt-get install libgtk-3-dev build-essential pkg-config libnghttp2-dev libssl-dev zlib1g-dev libyaml-dev curl tar bzip2 unzip patch
# macOS: install Xcode Command Line Tools, then:
brew install pkg-config libnghttp2 openssl@3 libyaml
export PKG_CONFIG_PATH="$(brew --prefix libnghttp2)/lib/pkgconfig:$(brew --prefix openssl@3)/lib/pkgconfig:$(brew --prefix libyaml)/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export LIBRARY_PATH="$(brew --prefix libnghttp2)/lib:$(brew --prefix openssl@3)/lib:$(brew --prefix libyaml)/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"
```

Run the commands for your OS, then `scripts/build.sh`. It updates runtime
dependencies from `main` and builds native minimap2/POD5 libraries and the binaries.
Native downloads support Linux x86_64/ARM64 and macOS 14+ ARM64. With mise, use
`mise install` followed by `mise exec -- scripts/build.sh`.

## Try offline

```sh
bin/adaptive --validate
bin/adaptive --replay=examples/replay.jsonl
```

Replay maps sequence JSONL without Dorado or MinKNOW. The example produces
Reject / Accept / Reject, with the final rejection caused by the acceptance quota.

## Sequence API

`require "adaptive/sequence"` provides mapping and policy evaluation without
loading live connections or starting Python/Dorado. See
[examples/sequence.cr](examples/sequence.cr) for an executable example.

```crystal
config = Adaptive::Config.from_json({reference: "reference.fa", targets: ["virus"]}.to_json)
mapper = Adaptive::SequenceMapper.new(config)
policy = Adaptive::BuiltinPolicy.new(config)
result = mapper.evaluate([sequence], policy, Adaptive::Experiment.new,
  {} of String => String, channel: 1, read_id: "preview")
result.decision.choice
result.display_hit.try(&.mapping.target_start)
```

`map` returns `Evidence`; `evaluate` also returns a `Decision` and `display_hit`.
`Mapping` and `Strand` are Adaptive value types, preserving reference/query
coordinates (zero-based, half-open), MAPQ, primary status, CIGAR and alignment
fields used by custom policies. Existing `Hit.new(segment, minimap2_mapping)`
construction remains supported; `hit.mapping` now returns `Adaptive::Mapping`.
The binding exposes primary status only: secondary and supplementary alignments
are both non-primary and cannot be distinguished through this API.

The default `mapping_mode: "any"` preserves live/replay behavior: any confident
target hit can justify acceptance. `mapping_mode: "primary"` selects the highest
MAPQ confident primary hit before checking targets, for sandbox compatibility.
`Decision#hit` identifies the alignment used for a contig decision;
`display_hit` is selected independently and may belong to another contig.
Motif, background, short-sequence and accept-all decisions have no decision hit.
Molefarm uses `min_bases: 1`, with its existing 220-base gate in the game;
live/replay retain their configured minimum, background sampling and quota.

A mapper builds its index once and can be shared by mapping workers; buffers
are local to each call. Keep policy/config changes and evaluation on their owning
coordinator. After changing targets or policy settings, call
`mapper.validate!(config)` without rebuilding; changing the reference requires
a new mapper. `validate_sequence!` checks reference/policy settings independently
of bridge files and live connection configuration.

Segments stay separate, including empty segment positions. Metadata is preserved,
and `Evidence#source` distinguishes `Sequence` from `Basecall`; only the live pool
marks actual bridge output as basecalls. Pass the existing read's memory and
experiment into repeated evaluations. Evaluation calls the supplied policy but
does not reserve or acknowledge quotas. Replay and the live coordinator retain
terminal-read, reservation and ACK accounting; custom policies retain responsibility
for any mutations they perform themselves.

## GUI

```sh
bin/adaptive-gui -c examples/live.json
```

Edit common settings in the form or all settings in the JSON tab. The native
toolbar uses [Radix icons](https://github.com/kojix2/icon-radix) for open/save,
settings, validation and start/stop; the log tab shows output. Relative paths use
the displayed working directory. The GUI launches the sibling `adaptive` CLI;
`--cli=PATH` selects another executable. Sequence replay works offline; live mode
defaults to observe only.
Ubuntu requires GTK 3; macOS uses native controls. GUI smoke tests:
`sh scripts/test-gui.sh` (Linux also needs `xvfb` and `xauth`).

## Run live

Install Dorado Basecall Server, models and GPU drivers separately; the server
is distinct from `dorado basecaller`. Install [requirements.txt](requirements.txt)
in a virtual environment using a Python compatible with the official client and
your server. See [operations](docs/operations.md) for authentication and setup.

Create `run.json`, adjusting the position service port, reference, model and paths:

```json
{
  "host": "127.0.0.1", "port": 10001, "tls": true,
  "ca_file": "/path/to/ca.crt", "reference": "/path/to/reference.fa",
  "targets": ["target_contig"], "observe": true,
  "python": ".venv/bin/python", "dorado_address": "ipc:///tmp/.guppy/5555",
  "dorado_model": "your_server_model", "log": "run-001.jsonl"
}
```

```sh
bin/adaptive -c run.json --validate
bin/adaptive -c run.json --check-backend
bin/adaptive -c run.json
```

Start with `observe: true` to log decisions without sending actions.
Accept stops signal delivery while sequencing continues; Reject unblocks;
Continue waits for more signal. Use a single-part reference index and a new log
path per run. Ctrl-C or SIGTERM stops the run.

For signal diagnostics, use `scripts/pod5.sh` to extract a POD5 prefix; see
[operations](docs/operations.md). Custom policies are demonstrated in
[custom.cr](examples/custom.cr) and [junction_policy.cr](examples/junction_policy.cr).
See [Config](src/adaptive/config.cr) for all settings.

## Test and scope

Python >= 3.11 is needed for portable tests; the official client is optional:

```sh
scripts/test.sh
# With a separately built Moleflow:
scripts/test.sh /absolute/path/moleflow/bin/moleflow
```

CI covers Ubuntu/macOS builds, specs, replay, integration and packaging.
Integration uses real gRPC/minimap2 with a fixture basecaller. GPU Dorado,
physical MinKNOW, selection accuracy and biological enrichment remain unvalidated.
See [validation](docs/validation-ci.md).

License: [MPL-2.0](LICENSE); third-party notices: [NOTICE.md](NOTICE.md).

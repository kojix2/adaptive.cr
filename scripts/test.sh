#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
for script in scripts/*.sh; do
  bash -n "$script"
done
crystal tool format --check src spec examples
bin/ameba --no-color
sh lib/pod5/scripts/with_native.sh crystal spec
python3 -m unittest discover -s tests -p 'test_*.py' -v
bin/adaptive --validate
bin/adaptive --replay=examples/replay.jsonl
if [[ $# -gt 0 ]]; then
  python3 tests/integration.py --moleflow "$1"
fi

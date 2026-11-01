#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
shards update
mkdir -p bin
crystal build src/main.cr --release -o bin/adaptive
crystal build src/gui_main.cr --release -o bin/adaptive-gui
crystal build examples/custom.cr --release -o bin/adaptive-junction
crystal build lib/ameba/src/cli.cr -o bin/ameba

prefix=${POD5_NATIVE_PREFIX:-"$PWD/lib/pod5/vendor/pod5"}
if [ ! -f "$prefix/lib/libpod5_cr_compat.so" ] && [ ! -f "$prefix/lib/libpod5_cr_compat.dylib" ]; then
  sh lib/pod5/scripts/install_native.sh
fi
sh lib/pod5/scripts/with_native.sh crystal build src/pod5_main.cr --release -o bin/adaptive-pod5
